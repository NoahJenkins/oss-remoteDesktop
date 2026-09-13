uniffi::setup_scaffolding!();

use std::io::Write;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, Once};
use std::thread;
use std::time::Duration;

use ironrdp::cliprdr::backend::CliprdrBackend;
use ironrdp::cliprdr::pdu::{
    ClipboardFormat, ClipboardFormatId, ClipboardGeneralCapabilityFlags, FileContentsRequest, FileContentsResponse,
    FormatDataRequest, FormatDataResponse, LockDataId,
};
use ironrdp::cliprdr::CliprdrClient;
use ironrdp::connector::sspi::network_client::NetworkClient;
use ironrdp::connector::{
    ClientConnector, ConnectorError, ConnectorErrorKind, Credentials, DesktopSize, ServerName,
};
use ironrdp::core::{AsAny, IntoOwned};
use ironrdp::graphics::image_processing::PixelFormat;
use ironrdp::input::{Database, MouseButton, MousePosition, Operation, Scancode};
use ironrdp::pdu::gcc::KeyboardType;
use ironrdp::pdu::rdp::capability_sets::MajorPlatformType;
use ironrdp::pdu::rdp::client_info::{PerformanceFlags, TimezoneInfo};
use ironrdp::session::image::DecodedImage;
use ironrdp::session::{ActiveStage, ActiveStageOutput};
use ironrdp_blocking::Framed;

#[derive(uniffi::Error, Debug, thiserror::Error)]
#[uniffi(flat_error)]
pub enum RdpError {
    #[error("connection refused")]
    ConnectionRefused,
    #[error("timeout")]
    Timeout,
    #[error("handshake failed")]
    HandshakeFailed,
    #[error("authentication failed")]
    AuthenticationFailed,
    #[error("dropped")]
    Dropped,
}

#[derive(uniffi::Record, Clone)]
pub struct RdpFrame {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

fn map_io(kind: std::io::ErrorKind) -> RdpError {
    match kind {
        std::io::ErrorKind::ConnectionRefused => RdpError::ConnectionRefused,
        std::io::ErrorKind::TimedOut => RdpError::Timeout,
        _ => RdpError::HandshakeFailed,
    }
}

fn map_connector(err: &ConnectorError) -> RdpError {
    match err.kind() {
        ConnectorErrorKind::AccessDenied | ConnectorErrorKind::Credssp(_) => RdpError::AuthenticationFailed,
        _ => RdpError::HandshakeFailed,
    }
}

enum Command {
    Disconnect,
    Pointer {
        x: u16,
        y: u16,
        left: bool,
        right: bool,
        middle: bool,
    },
    Scancode {
        scancode: u16,
        down: bool,
    },
    InitiateCopy,
    InitiatePaste,
    SubmitFormatData(FormatDataResponse<'static>),
}

struct Shared {
    frame: Mutex<Option<RdpFrame>>,
    clipboard: Mutex<Option<String>>,
    outgoing: Mutex<Option<String>>,
    dropped: AtomicBool,
}

fn mark_worker_exit(shared: &Shared, disconnect_requested: bool) {
    if !disconnect_requested {
        shared.dropped.store(true, Ordering::SeqCst);
    }
}

#[derive(uniffi::Object)]
pub struct RdpSession {
    commands: Mutex<Option<Sender<Command>>>,
    shared: Arc<Shared>,
}

#[uniffi::export]
pub fn rdp_connect(
    host: String,
    port: u16,
    username: String,
    password: String,
) -> Result<Arc<RdpSession>, RdpError> {
    install_crypto();
    let (tx, rx) = mpsc::channel();
    let shared = Arc::new(Shared {
        frame: Mutex::new(None),
        clipboard: Mutex::new(None),
        outgoing: Mutex::new(None),
        dropped: AtomicBool::new(false),
    });
    let backend = SessionClipBackend {
        commands: Some(tx.clone()),
        shared: Arc::clone(&shared),
    };
    let (connection_result, framed) = connect(host, port, username, password, backend)?;
    let thread_shared = Arc::clone(&shared);
    thread::Builder::new()
        .name("tailview-rdp".into())
        .spawn(move || run_active_stage(connection_result, framed, rx, thread_shared))
        .map_err(|_| RdpError::Dropped)?;
    Ok(Arc::new(RdpSession {
        commands: Mutex::new(Some(tx)),
        shared,
    }))
}

#[uniffi::export]
impl RdpSession {
    pub fn disconnect(&self) {
        if let Some(tx) = self.commands.lock().unwrap().take() {
            let _ = tx.send(Command::Disconnect);
        }
    }

    pub fn send_pointer(&self, x: u16, y: u16, left: bool, right: bool, middle: bool) {
        self.send(Command::Pointer {
            x,
            y,
            left,
            right,
            middle,
        });
    }

    pub fn send_scancode(&self, scancode: u16, down: bool) {
        self.send(Command::Scancode { scancode, down });
    }

    pub fn send_clipboard_text(&self, text: String) {
        if let Ok(mut outgoing) = self.shared.outgoing.lock() {
            *outgoing = Some(text);
        }
        self.send(Command::InitiateCopy);
    }

    pub fn poll_frame(&self) -> Option<RdpFrame> {
        self.shared.frame.lock().ok()?.take()
    }

    pub fn poll_clipboard(&self) -> Option<String> {
        self.shared.clipboard.lock().ok()?.take()
    }

    pub fn is_dropped(&self) -> bool {
        self.shared.dropped.load(Ordering::SeqCst)
    }
}

impl RdpSession {
    fn send(&self, command: Command) {
        if let Some(tx) = self.commands.lock().ok().and_then(|guard| guard.as_ref().cloned()) {
            let _ = tx.send(command);
        }
    }

    #[cfg(test)]
    fn for_test() -> Self {
        Self {
            commands: Mutex::new(None),
            shared: Arc::new(Shared {
                frame: Mutex::new(None),
                clipboard: Mutex::new(None),
                outgoing: Mutex::new(None),
                dropped: AtomicBool::new(false),
            }),
        }
    }
}

enum LoopControl {
    Continue,
    Disconnect,
    Drop,
}

type UpgradedFramed = Framed<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>;

fn connect(
    host: String,
    port: u16,
    username: String,
    password: String,
    backend: SessionClipBackend,
) -> Result<(ironrdp::connector::ConnectionResult, UpgradedFramed), RdpError> {
    let server_addr = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| map_io(e.kind()))?
        .next()
        .ok_or(RdpError::HandshakeFailed)?;
    let tcp_stream = TcpStream::connect_timeout(&server_addr, Duration::from_secs(10)).map_err(|e| map_io(e.kind()))?;
    tcp_stream.set_nodelay(true).map_err(|e| map_io(e.kind()))?;
    let client_addr = tcp_stream.local_addr().map_err(|e| map_io(e.kind()))?;
    let mut framed = Framed::new(tcp_stream);
    let config = connector_config(username, password);
    let mut connector =
        ClientConnector::new(config, client_addr).with_static_channel(CliprdrClient::new(Box::new(backend)));
    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector).map_err(|e| map_connector(&e))?;
    let initial_stream = framed.into_inner_no_leftover();
    let (upgraded_stream, server_public_key) = tls_upgrade(initial_stream, host.clone())?;
    upgraded_stream
        .sock
        .set_read_timeout(Some(Duration::from_millis(50)))
        .map_err(|e| map_io(e.kind()))?;
    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);
    let mut upgraded_framed = Framed::new(upgraded_stream);
    let mut network_client = StubNetworkClient;
    let connection_result = ironrdp_blocking::connect_finalize(
        upgraded,
        connector,
        &mut upgraded_framed,
        &mut network_client,
        ServerName::from(host),
        server_public_key,
        None,
    )
    .map_err(|e| map_connector(&e))?;
    Ok((connection_result, upgraded_framed))
}

fn connector_config(username: String, password: String) -> ironrdp::connector::Config {
    ironrdp::connector::Config {
        credentials: Credentials::UsernamePassword { username, password },
        domain: None,
        enable_tls: true,
        enable_credssp: true,
        keyboard_type: KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_layout: 0,
        keyboard_functional_keys_count: 12,
        ime_file_name: String::new(),
        dig_product_id: String::new(),
        desktop_size: DesktopSize {
            width: 1280,
            height: 1024,
        },
        bitmap: None,
        client_build: 0,
        client_name: "Tailview".to_owned(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
        platform: MajorPlatformType::MACINTOSH,
        enable_server_pointer: false,
        request_data: None,
        autologon: false,
        enable_audio_playback: false,
        compression_type: None,
        pointer_software_rendering: true,
        multitransport_flags: None,
        performance_flags: PerformanceFlags::default(),
        desktop_scale_factor: 0,
        hardware_id: None,
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        alternate_shell: String::new(),
        work_dir: String::new(),
    }
}

fn run_active_stage(
    connection_result: ironrdp::connector::ConnectionResult,
    mut framed: UpgradedFramed,
    commands: Receiver<Command>,
    shared: Arc<Shared>,
) {
    let mut image = DecodedImage::new(
        PixelFormat::RgbA32,
        connection_result.desktop_size.width,
        connection_result.desktop_size.height,
    );
    let mut active_stage = ActiveStage::new(connection_result);
    let mut input = Database::new();
    let mut disconnect_requested = false;
    loop {
        while let Ok(command) = commands.try_recv() {
            match handle_command(
                command,
                &mut active_stage,
                &mut framed,
                &mut image,
                &mut input,
                &shared,
            ) {
                LoopControl::Continue => {}
                LoopControl::Disconnect => {
                    disconnect_requested = true;
                    break;
                }
                LoopControl::Drop => {
                    mark_worker_exit(&shared, false);
                    return;
                }
            }
        }
        if disconnect_requested {
            break;
        }
        let (action, payload) = match framed.read_pdu() {
            Ok(frame) => frame,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {
                continue;
            }
            Err(_) => {
                mark_worker_exit(&shared, false);
                return;
            }
        };
        let outputs = match active_stage.process(&mut image, action, &payload) {
            Ok(outputs) => outputs,
            Err(_) => {
                mark_worker_exit(&shared, false);
                return;
            }
        };
        if !apply_outputs(&mut framed, &mut image, &shared, outputs) {
            mark_worker_exit(&shared, false);
            return;
        }
    }
    mark_worker_exit(&shared, disconnect_requested);
}

fn handle_command(
    command: Command,
    active_stage: &mut ActiveStage,
    framed: &mut UpgradedFramed,
    image: &mut DecodedImage,
    input: &mut Database,
    shared: &Shared,
) -> LoopControl {
    match command {
        Command::Disconnect => {
            if let Ok(outputs) = active_stage.graceful_shutdown() {
                let _ = apply_outputs(framed, image, shared, outputs);
            }
            LoopControl::Disconnect
        }
        Command::Pointer {
            x,
            y,
            left,
            right,
            middle,
        } => {
            let mut ops = vec![Operation::MouseMove(MousePosition { x, y })];
            push_button(&mut ops, input, MouseButton::Left, left);
            push_button(&mut ops, input, MouseButton::Right, right);
            push_button(&mut ops, input, MouseButton::Middle, middle);
            if send_input(active_stage, framed, image, shared, input.apply(ops)) {
                LoopControl::Continue
            } else {
                LoopControl::Drop
            }
        }
        Command::Scancode { scancode, down } => {
            let code = Scancode::from_u16(scancode);
            let op = if down {
                Operation::KeyPressed(code)
            } else {
                Operation::KeyReleased(code)
            };
            if send_input(active_stage, framed, image, shared, input.apply([op])) {
                LoopControl::Continue
            } else {
                LoopControl::Drop
            }
        }
        Command::InitiateCopy => {
            if send_cliprdr(active_stage, framed, |clip| {
                clip.initiate_copy(&[ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)])
            }) {
                LoopControl::Continue
            } else {
                LoopControl::Drop
            }
        }
        Command::InitiatePaste => {
            if send_cliprdr(active_stage, framed, |clip| {
                clip.initiate_paste(ClipboardFormatId::CF_UNICODETEXT)
            }) {
                LoopControl::Continue
            } else {
                LoopControl::Drop
            }
        }
        Command::SubmitFormatData(response) => {
            if send_cliprdr(active_stage, framed, |clip| clip.submit_format_data(response)) {
                LoopControl::Continue
            } else {
                LoopControl::Drop
            }
        }
    }
}

fn push_button(ops: &mut Vec<Operation>, input: &Database, button: MouseButton, down: bool) {
    let pressed = input.is_mouse_button_pressed(button);
    if down && !pressed {
        ops.push(Operation::MouseButtonPressed(button));
    } else if !down && pressed {
        ops.push(Operation::MouseButtonReleased(button));
    }
}

fn send_input(
    active_stage: &mut ActiveStage,
    framed: &mut UpgradedFramed,
    image: &mut DecodedImage,
    shared: &Shared,
    events: impl AsRef<[ironrdp::pdu::input::fast_path::FastPathInputEvent]>,
) -> bool {
    let events = events.as_ref();
    if events.is_empty() {
        return true;
    }
    match active_stage.process_fastpath_input(image, events) {
        Ok(outputs) => apply_outputs(framed, image, shared, outputs),
        Err(_) => false,
    }
}

fn send_cliprdr<F, E>(active_stage: &mut ActiveStage, framed: &mut UpgradedFramed, f: F) -> bool
where
    F: FnOnce(&mut CliprdrClient) -> Result<ironrdp::cliprdr::CliprdrSvcMessages<ironrdp::cliprdr::Client>, E>,
{
    let messages = {
        let Some(clip) = active_stage.get_svc_processor_mut::<CliprdrClient>() else {
            return true;
        };
        match f(clip) {
            Ok(messages) => messages,
            Err(_) => return true,
        }
    };
    match active_stage.process_svc_processor_messages(messages) {
        Ok(frame) => framed.write_all(&frame).is_ok(),
        Err(_) => false,
    }
}

fn apply_outputs(
    framed: &mut UpgradedFramed,
    image: &DecodedImage,
    shared: &Shared,
    outputs: Vec<ActiveStageOutput>,
) -> bool {
    for output in outputs {
        match output {
            ActiveStageOutput::ResponseFrame(frame) => {
                if !frame.is_empty() && framed.write_all(&frame).is_err() {
                    return false;
                }
            }
            ActiveStageOutput::GraphicsUpdate(_) => {
                if let Ok(mut slot) = shared.frame.lock() {
                    *slot = Some(RdpFrame {
                        width: u32::from(image.width()),
                        height: u32::from(image.height()),
                        rgba: image.data().to_vec(),
                    });
                }
            }
            ActiveStageOutput::Terminate(_) => return false,
            _ => {}
        }
    }
    true
}

struct SessionClipBackend {
    commands: Option<Sender<Command>>,
    shared: Arc<Shared>,
}

impl std::fmt::Debug for SessionClipBackend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionClipBackend").finish()
    }
}

impl AsAny for SessionClipBackend {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

impl CliprdrBackend for SessionClipBackend {
    fn temporary_directory(&self) -> &str {
        "/tmp"
    }

    fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
        ClipboardGeneralCapabilityFlags::USE_LONG_FORMAT_NAMES
    }

    fn on_ready(&mut self) {}

    fn on_request_format_list(&mut self) {}

    fn on_process_negotiated_capabilities(&mut self, _capabilities: ClipboardGeneralCapabilityFlags) {}

    fn on_remote_copy(&mut self, available_formats: &[ClipboardFormat]) {
        if available_formats
            .iter()
            .any(|format| format.id() == ClipboardFormatId::CF_UNICODETEXT)
        {
            if let Some(tx) = &self.commands {
                let _ = tx.send(Command::InitiatePaste);
            }
        }
    }

    fn on_format_data_request(&mut self, request: FormatDataRequest) {
        if request.format != ClipboardFormatId::CF_UNICODETEXT {
            if let Some(tx) = &self.commands {
                let _ = tx.send(Command::SubmitFormatData(FormatDataResponse::new_error().into_owned()));
            }
            return;
        }
        let text = self.shared.outgoing.lock().ok().and_then(|guard| guard.clone()).unwrap_or_default();
        if let Some(tx) = &self.commands {
            let _ = tx.send(Command::SubmitFormatData(
                FormatDataResponse::new_unicode_string(&text).into_owned(),
            ));
        }
    }

    fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
        if response.is_error() {
            return;
        }
        if let Ok(text) = response.to_unicode_string() {
            if let Ok(mut slot) = self.shared.clipboard.lock() {
                *slot = Some(text);
            }
        }
    }

    fn on_file_contents_request(&mut self, _request: FileContentsRequest) {}

    fn on_file_contents_response(&mut self, _response: FileContentsResponse<'_>) {}

    fn on_lock(&mut self, _data_id: LockDataId) {}

    fn on_unlock(&mut self, _data_id: LockDataId) {}
}

struct StubNetworkClient;

impl NetworkClient for StubNetworkClient {
    fn send(&self, _request: &ironrdp::connector::sspi::generator::NetworkRequest) -> ironrdp::connector::sspi::Result<Vec<u8>> {
        Err(ironrdp::connector::sspi::Error::new(
            ironrdp::connector::sspi::ErrorKind::UnsupportedFunction,
            "network client is not available",
        ))
    }
}

fn install_crypto() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

fn tls_upgrade(
    stream: TcpStream,
    server_name: String,
) -> Result<(rustls::StreamOwned<rustls::ClientConnection, TcpStream>, Vec<u8>), RdpError> {
    let mut config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertificateVerification))
        .with_no_client_auth();
    config.resumption = rustls::client::Resumption::disabled();
    let config = Arc::new(config);
    let name = rustls::pki_types::ServerName::try_from(server_name).map_err(|_| RdpError::HandshakeFailed)?;
    let client = rustls::ClientConnection::new(config, name).map_err(|_| RdpError::HandshakeFailed)?;
    let mut tls_stream = rustls::StreamOwned::new(client, stream);
    tls_stream.flush().map_err(|e| map_io(e.kind()))?;
    let cert = tls_stream
        .conn
        .peer_certificates()
        .and_then(|certificates| certificates.first())
        .ok_or(RdpError::HandshakeFailed)?
        .as_ref()
        .to_vec();
    Ok((tls_stream, extract_tls_server_public_key(&cert)?))
}

fn extract_tls_server_public_key(cert: &[u8]) -> Result<Vec<u8>, RdpError> {
    use x509_cert::der::Decode as _;
    let cert = x509_cert::Certificate::from_der(cert).map_err(|_| RdpError::HandshakeFailed)?;
    cert.tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        .map(|bytes| bytes.to_owned())
        .ok_or(RdpError::HandshakeFailed)
}

#[derive(Debug)]
struct NoCertificateVerification;

impl rustls::client::danger::ServerCertVerifier for NoCertificateVerification {
    fn verify_server_cert(
        &self,
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &[rustls::pki_types::CertificateDer<'_>],
        _: &rustls::pki_types::ServerName<'_>,
        _: &[u8],
        _: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _: &[u8],
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA1,
            rustls::SignatureScheme::ECDSA_SHA1_Legacy,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
            rustls::SignatureScheme::ECDSA_NISTP521_SHA512,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::ED448,
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn io_kind_maps_to_rdp_error() {
        assert!(matches!(map_io(std::io::ErrorKind::ConnectionRefused), RdpError::ConnectionRefused));
        assert!(matches!(map_io(std::io::ErrorKind::TimedOut), RdpError::Timeout));
    }

    #[test]
    fn unexpected_worker_exit_marks_session_dropped() {
        let session = RdpSession::for_test();
        assert!(!session.is_dropped());
        mark_worker_exit(&session.shared, false);
        assert!(session.is_dropped());
    }

    #[test]
    fn disconnect_worker_exit_does_not_mark_dropped() {
        let session = RdpSession::for_test();
        mark_worker_exit(&session.shared, true);
        assert!(!session.is_dropped());
    }
}
