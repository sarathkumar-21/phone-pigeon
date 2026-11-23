//! PhonePigeon for Windows and Linux. The Rust side owns every secret and socket; the web UI only ever
//! sees decrypted protocol bodies. Wire-compatible with the Mac and Android apps (see `crypto.rs`).

mod core;
mod crypto;
mod media;
mod store;
mod wire;

use crate::core::{Core, NearbyPhone, NearbyState, PhoneInfo};
use std::sync::{Arc, Mutex};
use tauri::http::{Response, StatusCode};
use tauri::{AppHandle, Manager, State};

struct App {
    core: Arc<Core>,
    screen: Mutex<std::collections::HashMap<String, tauri::async_runtime::JoinHandle<()>>>,
}

#[tauri::command]
fn phones(app: State<'_, App>) -> Vec<PhoneInfo> {
    app.core.phones()
}

#[tauri::command]
fn device_info(app: State<'_, App>) -> serde_json::Value {
    serde_json::json!({ "name": core::device_name(), "fingerprint": app.core.own_fingerprint(), "lan_port": app.core.lan_port() })
}

#[tauri::command]
fn send(app: State<'_, App>, phone_id: String, body: serde_json::Value) -> bool {
    app.core.transmit(&phone_id, body)
}

#[tauri::command]
fn nearby_phones(app: State<'_, App>) -> Vec<NearbyPhone> {
    app.core.nearby_phones()
}

#[tauri::command]
fn nearby_state(app: State<'_, App>) -> NearbyState {
    app.core.nearby_state()
}

#[tauri::command]
fn nearby_begin(app: State<'_, App>, id: String) {
    app.core.nearby_begin(id)
}

#[tauri::command]
fn nearby_confirm(app: State<'_, App>) {
    app.core.nearby_confirm()
}

#[tauri::command]
fn nearby_cancel(app: State<'_, App>) {
    app.core.nearby_cancel()
}

#[tauri::command]
fn nearby_dismiss(app: State<'_, App>) {
    app.core.nearby_dismiss()
}

#[tauri::command]
fn remove_phone(app: State<'_, App>, phone_id: String) {
    app.core.remove_phone(&phone_id)
}

#[tauri::command]
fn snapshot_load(app: State<'_, App>, phone_id: String) -> Option<String> {
    app.core.snapshot_load(&phone_id)
}

#[tauri::command]
fn snapshot_save(app: State<'_, App>, phone_id: String, json: String) {
    app.core.snapshot_save(&phone_id, json)
}

#[tauri::command]
fn settings_load(app: State<'_, App>) -> String {
    app.core.settings_load()
}

#[tauri::command]
fn settings_save(app: State<'_, App>, json: String) {
    app.core.settings_save(json)
}

fn downloads_dir() -> std::path::PathBuf {
    dirs::download_dir().or_else(dirs::home_dir).unwrap_or_else(|| std::path::PathBuf::from("."))
}

#[tauri::command]
async fn media_download(
    app: AppHandle, state: State<'_, App>, phone_id: String, id: String, path: String, media_id: Option<i64>, name: String, size: u64,
    to_temp: Option<bool>,
) -> Result<String, String> {
    let ep = state.core.media_endpoint(&phone_id).ok_or("The phone's media server isn't reachable. Both devices need to be on the same Wi-Fi.")?;
    let dir = if to_temp.unwrap_or(false) {
        let d = std::env::temp_dir().join("PhonePigeonPreview");
        let _ = std::fs::create_dir_all(&d);
        d
    } else {
        downloads_dir()
    };
    media::download(app, ep, id, path, media_id, name, size, dir).await.map(|p| p.to_string_lossy().to_string())
}

#[tauri::command]
async fn media_upload(app: AppHandle, state: State<'_, App>, phone_id: String, id: String, local: String, folder: String) -> Result<(), String> {
    let ep = state.core.media_endpoint(&phone_id).ok_or("The phone's media server isn't reachable.")?;
    media::upload(app, ep, id, std::path::PathBuf::from(local), folder).await
}

#[tauri::command]
fn screen_start(app: AppHandle, state: State<'_, App>, phone_id: String) -> Result<(), String> {
    let ep = state.core.media_endpoint(&phone_id).ok_or("The phone's media server isn't reachable.")?;
    let pid = phone_id.clone();
    let handle = tauri::async_runtime::spawn(async move {
        use tauri::Emitter;
        let r = media::screen_stream(app.clone(), ep, pid.clone()).await;
        let _ = app.emit("screen_end", serde_json::json!({ "phone_id": pid, "error": r.err() }));
    });
    if let Some(old) = state.screen.lock().unwrap().insert(phone_id, handle) {
        old.abort();
    }
    Ok(())
}

#[tauri::command]
fn screen_stop(state: State<'_, App>, phone_id: String) {
    if let Some(h) = state.screen.lock().unwrap().remove(&phone_id) {
        h.abort();
    }
}

#[tauri::command]
fn reveal_in_folder(path: String) {
    let p = std::path::PathBuf::from(&path);
    let dir = p.parent().map(|d| d.to_path_buf()).unwrap_or(p);
    let _ = open_path(&dir);
}

fn open_path(p: &std::path::Path) -> std::io::Result<()> {
    #[cfg(target_os = "windows")]
    let mut c = std::process::Command::new("explorer");
    #[cfg(target_os = "macos")]
    let mut c = std::process::Command::new("open");
    #[cfg(all(not(target_os = "windows"), not(target_os = "macos")))]
    let mut c = std::process::Command::new("xdg-open");
    c.arg(p).spawn().map(|_| ())
}

/// `pigeon://localhost/<phone id>/media/...`: forwards GET requests (with Range) to the phone's pinned-TLS server so
/// `<img>` and `<video>` can use phone files directly without the bytes ever leaving the app.
fn media_protocol(app: &AppHandle, request: tauri::http::Request<Vec<u8>>, responder: tauri::UriSchemeResponder) {
    let state = app.state::<App>();
    let core = state.core.clone();
    tauri::async_runtime::spawn(async move {
        let fail = |code: StatusCode| Response::builder().status(code).header("Access-Control-Allow-Origin", "*").body(Vec::new()).unwrap();
        let uri = request.uri();
        log::debug!("media request {}", uri.path());
        let mut segs = uri.path().trim_start_matches('/').splitn(2, '/');
        let phone_id = segs.next().unwrap_or("").to_string();
        let rest = format!("/{}", segs.next().unwrap_or(""));
        if !rest.starts_with("/media/") || rest.contains("..") {
            return responder.respond(fail(StatusCode::BAD_REQUEST));
        }
        let Some(ep) = core.media_endpoint(&phone_id) else {
            log::warn!("media request but no endpoint for phone {phone_id}");
            return responder.respond(fail(StatusCode::SERVICE_UNAVAILABLE));
        };
        let Some(client) = ep.client() else { return responder.respond(fail(StatusCode::INTERNAL_SERVER_ERROR)) };
        let mut req = ep.authorized(&client, &ep.url(&rest, uri.query().unwrap_or("")));
        if let Some(r) = request.headers().get("range").and_then(|v| v.to_str().ok()) {
            req = req.header("Range", r);
        }
        match req.send().await {
            Ok(r) => {
                let status = StatusCode::from_u16(r.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
                let mut b = Response::builder().status(status).header("Access-Control-Allow-Origin", "*");
                for h in ["content-type", "content-range", "accept-ranges", "content-length"] {
                    if let Some(v) = r.headers().get(h) {
                        b = b.header(h, v.as_bytes());
                    }
                }
                match r.bytes().await {
                    Ok(bytes) => responder.respond(b.body(bytes.to_vec()).unwrap()),
                    Err(_) => responder.respond(fail(StatusCode::BAD_GATEWAY)),
                }
            }
            Err(e) => {
                log::warn!("media request to the phone failed: {e}");
                responder.respond(fail(StatusCode::BAD_GATEWAY))
            }
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let _ = env_logger::try_init();
    let _ = rustls::crypto::ring::default_provider().install_default();
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.set_focus();
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .register_asynchronous_uri_scheme_protocol("pigeon", |ctx, req, responder| media_protocol(ctx.app_handle(), req, responder))
        .setup(|app| {
            let core = Core::new(app.handle().clone());
            core.start();
            app.manage(App { core, screen: Mutex::new(Default::default()) });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Destroyed = event {
                window.state::<App>().core.shutdown();
            }
        })
        .invoke_handler(tauri::generate_handler![
            phones, device_info, send, nearby_phones, nearby_state, nearby_begin, nearby_confirm, nearby_cancel, nearby_dismiss,
            remove_phone, snapshot_load, snapshot_save, settings_load, settings_save, media_download, media_upload, screen_start,
            screen_stop, reveal_in_folder,
        ])
        .run(tauri::generate_context!())
        .expect("error while running PhonePigeon");
}
