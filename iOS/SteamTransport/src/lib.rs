// SPDX-License-Identifier: GPL-3.0-only
//! Native Steam CM/SteamPipe Workshop transport. No anonymous login or injected keys.
use serde::{Deserialize, Serialize};
use sha1::{Digest, Sha1};
use std::{collections::{HashMap, HashSet}, ffi::{CStr, CString}, os::raw::c_char,
    path::{Component, PathBuf}, ptr, sync::{Arc, Mutex, OnceLock},
    sync::atomic::{AtomicU64, Ordering}, time::Duration};
use steam_vent::{Connection, ConnectionTrait, ServerList};
use steam_vent::auth::{AuthConfirmationHandler, ConfirmationAction, ConfirmationMethod,
    ConfirmationMethodClass, NullGuardDataStore, UserProvidedAuthConfirmationHandler};
use steam_vent::proto::{
    steammessages_player_steamclient::CPlayer_GetOwnedGames_Request,
    steammessages_publishedfile_steamclient::CPublishedFile_GetDetails_Request,
    steammessages_clientserver_appinfo::{CMsgClientPICSAccessTokenRequest,
        CMsgClientPICSAccessTokenResponse, CMsgClientPICSProductInfoRequest,
        CMsgClientPICSProductInfoResponse, cmsg_client_picsproduct_info_request::AppInfo}};
use tokio::{io::{AsyncWrite, AsyncWriteExt, AsyncReadExt}, runtime::Runtime, sync::{Notify, oneshot}, task::AbortHandle};
use std::{pin::Pin, task::{Context, Poll}};
use keyvalues_parser::Vdf;

const APP_ID: u32 = 431960;
const MAX_FILES: usize = 100_000;
const MAX_BYTES: u64 = 20 * 1024 * 1024 * 1024;
static NEXT: AtomicU64 = AtomicU64::new(1);
static ENGINE: OnceLock<Mutex<Engine>> = OnceLock::new();
static SESSION: OnceLock<Mutex<Option<Arc<Connection>>>> = OnceLock::new();
fn session() -> &'static Mutex<Option<Arc<Connection>>> { SESSION.get_or_init(|| Mutex::new(None)) }
fn engine() -> &'static Mutex<Engine> { ENGINE.get_or_init(|| Mutex::new(Engine::default())) }
#[derive(Default)] struct Engine { runtime: Option<Runtime>, tasks: HashMap<u64, Arc<Job>>, active: Option<u64> }
#[derive(Deserialize)] struct Request {
    operation: String, #[serde(default)] account: String, #[serde(default)] password: String,
    #[serde(default)] item_id: String, #[serde(default)] destination: String,
}
#[derive(Clone, Serialize)] struct Status {
    phase: String, received: u64, total: u64, message: String, guard_type: String,
}
struct Job { status: Mutex<Status>, stop: Notify, guard: Mutex<Option<oneshot::Sender<String>>>, abort: Mutex<Option<AbortHandle>> }
impl Job {
    fn new() -> Arc<Self> { Arc::new(Self { status: Mutex::new(Status { phase: "queued".into(), received: 0, total: 0, message: String::new(), guard_type: String::new() }), stop: Notify::new(), guard: Mutex::new(None), abort: Mutex::new(None) }) }
    fn phase(&self, phase: &str) { self.status.lock().unwrap().phase = phase.into(); }
    fn fail(&self, reason: &str) { let mut s = self.status.lock().unwrap(); s.phase = "error".into(); s.message = reason.into(); s.guard_type.clear(); }
    fn done(&self) { let mut s = self.status.lock().unwrap(); s.phase = "done".into(); s.guard_type.clear(); }
    fn terminal(&self) -> bool { matches!(self.status.lock().unwrap().phase.as_str(), "done" | "error" | "cancelled") }
}
fn ffi<T: Copy>(f: impl FnOnce() -> T, fallback: T) -> T { std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(fallback) }

/// Request JSON is trusted app input. It is never logged or returned by polling.
#[no_mangle] pub unsafe extern "C" fn wm_steam_start(json: *const c_char) -> u64 { ffi(|| {
    if json.is_null() { return 0; }
    let raw = CStr::from_ptr(json).to_bytes();
    if raw.len() > 16_384 { return 0; }
    let Ok(mut request) = serde_json::from_slice::<Request>(raw) else { return 0; };
    let mut e = engine().lock().unwrap();
    if let Some(id) = e.active { if e.tasks.get(&id).is_some_and(|j| !j.terminal()) { return 0; } }
    if request.operation == "logout" {
        *session().lock().unwrap() = None;
        // Dropping the dedicated runtime also stops the upstream CM heartbeat tasks.
        if let Some(runtime) = e.runtime.take() { runtime.shutdown_background(); }
        e.tasks.clear(); e.active = None;
        let id = NEXT.fetch_add(1, Ordering::Relaxed); let job = Job::new(); job.done(); e.tasks.insert(id, job); return id;
    }
    if e.runtime.is_none() { e.runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().ok(); }
    if e.runtime.is_none() { return 0; }
    e.tasks.retain(|_, j| !j.terminal());
    let id = NEXT.fetch_add(1, Ordering::Relaxed); let job = Job::new(); let worker = job.clone();
    let handle = e.runtime.as_ref().unwrap().spawn(async move {
        let result = tokio::select! { _ = worker.stop.notified() => Err("cancelled"), result = run(&worker, &mut request) => result };
        // Credentials exist only for this request and are erased before it leaves scope.
        use zeroize::Zeroize; request.password.zeroize(); request.account.zeroize();
        match result { Ok(()) => worker.done(), Err("cancelled") => worker.phase("cancelled"), Err(reason) => worker.fail(reason) }
    });
    *job.abort.lock().unwrap() = Some(handle.abort_handle());
    e.active = Some(id); e.tasks.insert(id, job); id
}, 0) }
#[no_mangle] pub extern "C" fn wm_steam_poll(id: u64) -> *mut c_char { ffi(|| {
    let job = engine().lock().unwrap().tasks.get(&id).cloned();
    let value = job.map(|j| serde_json::to_string(&*j.status.lock().unwrap()).unwrap_or_default())
        .unwrap_or_else(|| "{\"phase\":\"unknown\",\"received\":0,\"total\":0,\"message\":\"unknown_task\",\"guard_type\":\"\"}".into());
    CString::new(value).map(CString::into_raw).unwrap_or(ptr::null_mut())
}, ptr::null_mut()) }
#[no_mangle] pub unsafe extern "C" fn wm_steam_guard(id: u64, code: *const c_char) -> i32 { ffi(|| {
    if code.is_null() { return 0; } let Ok(value) = CStr::from_ptr(code).to_str() else { return 0; };
    if value.is_empty() || value.len() > 16 || !value.bytes().all(|b| b.is_ascii_alphanumeric()) { return 0; }
    let job = engine().lock().unwrap().tasks.get(&id).cloned();
    job.and_then(|j| j.guard.lock().unwrap().take()).map(|sender| sender.send(value.to_owned()).is_ok() as i32).unwrap_or(0)
}, 0) }
#[no_mangle] pub extern "C" fn wm_steam_cancel(id: u64) { ffi(|| {
    if let Some(job) = engine().lock().unwrap().tasks.get(&id).cloned() { job.stop.notify_one(); }
}, ()) }
#[no_mangle] pub unsafe extern "C" fn wm_steam_free(value: *mut c_char) { if !value.is_null() { drop(CString::from_raw(value)); } }

struct UIConfirmation(Arc<Job>);
impl AuthConfirmationHandler for UIConfirmation {
    async fn handle_confirmation(self, methods: &[ConfirmationMethod]) -> Option<ConfirmationAction> {
        if let Some(method) = methods.iter().find(|m| m.token_type().is_some()) {
            let (tx, rx) = oneshot::channel(); *self.0.guard.lock().unwrap() = Some(tx);
            { let mut status = self.0.status.lock().unwrap(); status.phase = "guard".into(); status.guard_type = method.confirmation_type().into(); }
            let code = tokio::time::timeout(Duration::from_secs(180), rx).await.ok()?.ok()?;
            self.0.phase("authenticating");
            let (reader, mut writer) = tokio::io::duplex(256);
            writer.write_all(format!("{code}\n").as_bytes()).await.ok()?;
            drop(writer);
            return UserProvidedAuthConfirmationHandler::new(reader, tokio::io::sink())
                .handle_confirmation(methods).await;
        }
        if methods.iter().any(|m| matches!(m.class(), ConfirmationMethodClass::Confirmation)) {
            { let mut status = self.0.status.lock().unwrap(); status.phase = "guard".into(); status.guard_type = "device confirmation".into(); }
            // Steam's normal auth poll concurrently waits for approval; no synthetic approval.
            std::future::pending::<()>().await;
        }
        Some(ConfirmationAction::None)
    }
}
async fn owns_app(connection: &Connection) -> Result<(), &'static str> {
    let response = connection.service_method(CPlayer_GetOwnedGames_Request {
        steamid: Some(connection.steam_id().into()), include_played_free_games: Some(true),
        ..Default::default()
    }).await.map_err(|_| "ownership_check_failed")?;
    if !response.games.iter().any(|game| game.appid() == APP_ID as i32) { return Err("ownership_required"); }
    Ok(())
}
async fn run(job: &Arc<Job>, req: &mut Request) -> Result<(), &'static str> {
    match req.operation.as_str() {
        "login" => {
            if req.account.trim().is_empty() || req.account.len() > 128 || req.password.is_empty() || req.password.len() > 1024 { return Err("invalid_credentials"); }
            if session().lock().unwrap().is_some() { return Err("already_signed_in"); }
            job.phase("connecting");
            let servers = ServerList::discover().await.map_err(|_| "connection_failed")?;
            job.phase("authenticating");
            let connection = tokio::time::timeout(Duration::from_secs(240), Connection::login(&servers, &req.account, &req.password, NullGuardDataStore, UIConfirmation(job.clone())))
                .await.map_err(|_| "login_timeout")?.map_err(|_| "login_rejected")?;
            job.phase("checking_ownership"); owns_app(&connection).await?;
            *session().lock().unwrap() = Some(Arc::new(connection)); Ok(())
        }
        "download" => download(job, req).await,
        _ => Err("invalid_operation"),
    }
}

fn item_id(value: &str) -> Option<u64> {
    if value.is_empty() || value.len() > 20 || value.starts_with('0') || !value.bytes().all(|b| b.is_ascii_digit()) { return None; }
    value.parse::<u64>().ok().filter(|n| *n > 0)
}
fn safe_path(raw: &str) -> Result<PathBuf, &'static str> {
    // Treat both platform separators identically before validating every component.
    let normalized = raw.replace('\\', "/");
    if normalized.is_empty() || normalized.starts_with('/') || normalized.contains(':') || normalized.chars().any(|c| c.is_control())
        || normalized.split('/').any(|p| p.is_empty() || p == "." || p == "..") { return Err("unsafe_manifest_path"); }
    let path = PathBuf::from(normalized);
    if path.components().any(|c| !matches!(c, Component::Normal(_))) { return Err("unsafe_manifest_path"); }
    Ok(path)
}
async fn workshop_depot(connection: &Connection) -> Result<u32, &'static str> {
    let tokens: CMsgClientPICSAccessTokenResponse = connection.job(CMsgClientPICSAccessTokenRequest { appids: vec![APP_ID], ..Default::default() })
        .await.map_err(|_| "app_access_denied")?;
    let response: CMsgClientPICSProductInfoResponse = connection.job(CMsgClientPICSProductInfoRequest {
        apps: vec![AppInfo { appid: Some(APP_ID), access_token: tokens.app_access_tokens.iter().find(|t| t.appid() == APP_ID).map(|t| t.access_token()), ..Default::default() }],
        meta_data_only: Some(false), ..Default::default()
    }).await.map_err(|_| "app_info_failed")?;
    let app = response.apps.iter().find(|a| a.appid() == APP_ID).ok_or("app_info_failed")?;
    let text = std::str::from_utf8(app.buffer()).map_err(|_| "app_info_failed")?.trim_end_matches('\0');
    let vdf = Vdf::parse(text).map_err(|_| "app_info_failed")?;
    let appinfo = vdf.value.get_obj().ok_or("app_info_failed")?;
    let depots = appinfo.get("depots").and_then(|v| v.first()).and_then(|v| v.get_obj()).ok_or("workshop_depot_missing")?;
    let depot = depots.get("workshopdepot").and_then(|v| v.first()).ok_or("workshop_depot_missing")?.to_string().trim_matches('"').parse::<u32>().map_err(|_| "workshop_depot_missing")?;
    if depot == 0 { return Err("workshop_depot_missing"); } Ok(depot)
}
async fn download(job: &Arc<Job>, req: &Request) -> Result<(), &'static str> {
    let id = item_id(&req.item_id).ok_or("invalid_item_id")?;
    let root = PathBuf::from(&req.destination);
    if !root.is_absolute() || !root.is_dir() || root.symlink_metadata().map_err(|_| "invalid_destination")?.file_type().is_symlink()
        || std::fs::read_dir(&root).map_err(|_| "invalid_destination")?.next().is_some() { return Err("invalid_destination"); }
    let connection = session().lock().unwrap().clone().ok_or("content_signin_required")?;
    job.phase("checking_ownership"); owns_app(&connection).await?;
    job.phase("resolving_item");
    let details = connection.service_method(CPublishedFile_GetDetails_Request { publishedfileids: vec![id], appid: Some(APP_ID), includetags: Some(true), ..Default::default() })
        .await.map_err(|_| "item_access_denied")?;
    let item = details.publishedfiledetails.iter().find(|d| d.publishedfileid() == id).ok_or("item_unavailable")?;
    if item.result() != 1 || item.consumer_appid() != APP_ID { return Err("item_access_denied"); }
    if item.file_type() == 2 || item.tags.iter().any(|t| t.tag() == "Application") { return Err("item_type_unsupported"); }
    let manifest_id = item.hcontent_file(); if manifest_id == 0 { return Err("manifest_missing"); }
    let depot = workshop_depot(&connection).await?;
    let cdn = steam_cdn::CDNClient::discover(connection).await.map_err(|_| "content_connection_failed")?;
    let key = cdn.get_depot_decryption_key(APP_ID, depot).await.map_err(|_| "depot_access_denied")?.ok_or("depot_access_denied")?;
    let code = cdn.get_manifest_request_code(APP_ID, depot, manifest_id).await.map_err(|_| "manifest_access_denied")?;
    if code == 0 { return Err("manifest_access_denied"); }
    job.phase("fetching_manifest");
    let manifest = cdn.get_manifest(depot, manifest_id, Some(code), Some(key)).await.map_err(|_| "manifest_failed")?;
    if manifest.depot_id() != depot || manifest.manifest_gid() != manifest_id || manifest.filenames_encrypted() { return Err("manifest_mismatch"); }
    if manifest.files().len() > MAX_FILES || manifest.original_size() > MAX_BYTES { return Err("content_too_large"); }
    let mut paths = HashSet::new(); let mut total = 0u64;
    for file in manifest.files() {
        let path = safe_path(&file.full_path())?;
        if !file.linktarget().is_empty() { return Err("manifest_symlink_refused"); }
        if !paths.insert(path.to_string_lossy().to_lowercase()) { return Err("duplicate_manifest_path"); }
        total = total.checked_add(file.size()).filter(|n| *n <= MAX_BYTES).ok_or("content_too_large")?;
        if file.flags() & 64 == 0 && file.sha_content().len() != 20 { return Err("manifest_hash_missing"); }
    }
    { let mut status = job.status.lock().unwrap(); status.total = total; status.phase = "downloading".into(); }
    for file in manifest.files() {
        let path = root.join(safe_path(&file.full_path())?);
        if file.flags() & 64 != 0 { tokio::fs::create_dir_all(&path).await.map_err(|_| "write_failed")?; continue; }
        if let Some(parent) = path.parent() { tokio::fs::create_dir_all(parent).await.map_err(|_| "write_failed")?; }
        let output = tokio::fs::OpenOptions::new().write(true).create_new(true).open(&path).await.map_err(|_| "write_failed")?;
        let mut writer = ProgressWriter { file: output, job: job.clone(), limit: file.size(), written: 0 };
        file.download(key, &mut writer, Some(2)).await.map_err(|_| "chunk_download_failed")?;
        writer.flush().await.map_err(|_| "write_failed")?;
        if writer.written != file.size() { return Err("file_size_mismatch"); } drop(writer);
        let mut input = tokio::fs::File::open(&path).await.map_err(|_| "verify_failed")?;
        let mut sha = Sha1::new(); let mut buffer = vec![0u8; 65536];
        loop { let count = input.read(&mut buffer).await.map_err(|_| "verify_failed")?; if count == 0 { break; } sha.update(&buffer[..count]); }
        if sha.finalize().as_slice() != file.sha_content() { return Err("file_hash_mismatch"); }
    }
    if !root.join("project.json").is_file() { return Err("wallpaper_project_missing"); }
    Ok(())
}
struct ProgressWriter { file: tokio::fs::File, job: Arc<Job>, limit: u64, written: u64 }
impl AsyncWrite for ProgressWriter {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, data: &[u8]) -> Poll<std::io::Result<usize>> {
        if data.len() as u64 > self.limit.saturating_sub(self.written) { return Poll::Ready(Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "file limit"))); }
        match Pin::new(&mut self.file).poll_write(cx, data) {
            Poll::Ready(Ok(count)) => { self.written += count as u64; self.job.status.lock().unwrap().received += count as u64; Poll::Ready(Ok(count)) }, other => other,
        }
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> { Pin::new(&mut self.file).poll_flush(cx) }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> { Pin::new(&mut self.file).poll_shutdown(cx) }
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn ids_are_positive_canonical_uint64() { assert_eq!(item_id("42"), Some(42)); for s in ["", "0", "01", "4x", "18446744073709551616"] { assert!(item_id(s).is_none()); } }
    #[test] fn manifest_paths_stay_relative() { assert_eq!(safe_path("materials/test.png").unwrap(), PathBuf::from("materials/test.png")); for p in ["../x", "/x", "C:/x", "a/../b", "a//b", ".", "a/./b", "a\0b", "a\\..\\x"] { assert!(safe_path(p).is_err(), "{p}"); } }
    #[test] fn polling_never_serializes_credentials() { let job = Job::new(); job.fail("login_rejected"); let s = serde_json::to_string(&*job.status.lock().unwrap()).unwrap(); assert!(!s.contains("password")); assert!(!s.contains("account")); assert!(job.terminal()); }
}
