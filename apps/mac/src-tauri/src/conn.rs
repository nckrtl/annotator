//! Agent sessions in Conn (T3.swift, T3Sessions.swift): one thread per project, opened in the
//! Conn window, with a short follow-up when new annotations arrive and the thread is idle.
//! Conn's HTTP API is internal, so every request reports a clear error when its shape changes.

use crate::projects::Project;
use crate::settings::{expand_tilde, Settings};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

pub const LOCAL_ENDPOINT: &str = "http://127.0.0.1:3780";
pub const KEYCHAIN_SERVICE: &str = "com.nckrtl.annotator.t3";

#[derive(Debug, Clone, PartialEq)]
pub enum ConnError {
    NotRunning(String),
    Unauthorized,
    Rejected(String),
    Unexpected(String),
}

impl std::fmt::Display for ConnError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnError::NotRunning(message) | ConnError::Unexpected(message) => write!(f, "{message}"),
            ConnError::Unauthorized => write!(f, "Conn rejected the access token."),
            ConnError::Rejected(message) => write!(f, "Conn refused the request: {message}"),
        }
    }
}

/// A local Conn install, found from its data folder (`T3CODE_HOME`).
#[derive(Debug, Clone, PartialEq)]
pub struct Instance {
    pub home: PathBuf,
}

#[derive(Deserialize, Debug, Clone, PartialEq)]
pub struct Runtime {
    pub pid: i32,
    pub origin: String,
}

impl Instance {
    pub fn new(folder: &str) -> Instance {
        let home = expand_tilde(folder);
        let text = home.to_string_lossy();
        let trimmed = if text.len() > 1 { text.trim_end_matches('/') } else { &text };
        Instance { home: PathBuf::from(trimmed) }
    }

    pub fn state_directory(&self) -> PathBuf {
        self.home.join("userdata")
    }

    pub fn runtime(&self) -> Result<Runtime, ConnError> {
        let file = self.state_directory().join("server-runtime.json");
        let data = std::fs::read(&file)
            .map_err(|_| ConnError::NotRunning(format!("No {}. Start Conn first.", file.display())))?;
        serde_json::from_slice(&data).map_err(|_| ConnError::Unexpected(format!("Could not read {}.", file.display())))
    }

    pub fn environment_id(&self) -> Result<String, ConnError> {
        let file = self.state_directory().join("environment-id");
        std::fs::read_to_string(&file).ok().map(|id| id.trim().to_string()).filter(|id| !id.is_empty())
            .ok_or_else(|| ConnError::Unexpected(format!("Could not read {}.", file.display())))
    }

    /// The desktop app's control socket: `$TMPDIR/t3code-<uid>/<first 24 hex of sha256(stateDir)>.sock`.
    pub fn control_socket(&self, temporary_directory: &Path, uid: u32) -> PathBuf {
        let state = self.state_directory().to_string_lossy().trim_end_matches('/').to_string();
        let digest = Sha256::digest(state.as_bytes());
        let name: String = digest.iter().map(|b| format!("{b:02x}")).collect::<String>()[..24].to_string();
        temporary_directory.join(format!("t3code-{uid}/{name}.sock"))
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ModelSelection {
    pub instance_id: String,
    pub model: String,
}

impl ModelSelection {
    /// `codex/gpt-6.1-sol` → instance `codex`, model `gpt-6.1-sol`.
    pub fn parse(text: &str) -> Option<ModelSelection> {
        let (instance, model) = text.trim_matches(|c| c == ' ' || c == '\t').split_once('/')?;
        (!instance.is_empty() && !model.is_empty())
            .then(|| ModelSelection { instance_id: instance.into(), model: model.into() })
    }
}

/// The parts of Conn's read model this app uses.
#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub projects: Vec<SnapshotProject>,
    pub threads: Vec<Thread>,
}

/// Conn's model; some fields only document its shape.
#[allow(dead_code)]
#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotProject {
    pub id: String,
    pub title: Option<String>,
    pub workspace_root: String,
    pub deleted_at: Option<String>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Thread {
    pub id: String,
    pub project_id: Option<String>,
    pub model_selection: Option<ModelSelection>,
    pub updated_at: Option<String>,
    pub deleted_at: Option<String>,
    pub session: Option<ThreadSession>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSession {
    pub status: Option<String>,
    pub active_turn_id: Option<String>,
}

impl Thread {
    /// No turn is running, so a new message starts work at once.
    pub fn is_idle(&self) -> bool {
        self.session.as_ref().and_then(|s| s.active_turn_id.as_ref()).is_none()
    }
}

fn normalize(path: &str) -> String {
    let expanded = expand_tilde(path);
    let resolved = std::fs::canonicalize(&expanded).unwrap_or(expanded);
    let text = resolved.to_string_lossy().to_string();
    if text.len() > 1 { text.trim_end_matches('/').to_string() } else { text }
}

impl Snapshot {
    /// The active project whose folder is `root`, comparing resolved paths.
    pub fn project(&self, root: &str) -> Option<&SnapshotProject> {
        let wanted = normalize(root);
        self.projects.iter().find(|p| p.deleted_at.is_none() && normalize(&p.workspace_root) == wanted)
    }

    /// The model of the most recently updated thread: a default that needs no setup.
    pub fn latest_model(&self) -> Option<ModelSelection> {
        self.threads.iter()
            .filter(|t| t.deleted_at.is_none() && t.model_selection.is_some())
            .max_by(|a, b| a.updated_at.as_deref().unwrap_or("").cmp(b.updated_at.as_deref().unwrap_or("")))
            .and_then(|t| t.model_selection.clone())
    }
}

pub fn uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}

fn iso_now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// Orchestration commands for `POST /api/orchestration/dispatch`.
pub mod command {
    use super::*;

    pub fn create_project(id: &str, title: &str, root: &str) -> Value {
        json!({"type": "project.create", "commandId": uuid(), "projectId": id, "title": title,
            "workspaceRoot": root, "createWorkspaceRootIfMissing": false, "createdAt": iso_now()})
    }

    pub fn create_thread(id: &str, project_id: &str, title: &str, model: &ModelSelection, runtime_mode: &str,
        effort: Option<&str>) -> Value {
        let mut selection = json!({"instanceId": model.instance_id, "model": model.model});
        if let Some(effort) = effort.filter(|e| !e.is_empty()) {
            let key = if model.instance_id == "codex" { "reasoningEffort" } else { "effort" };
            selection["options"] = json!([{"id": key, "value": effort}]);
        }
        json!({"type": "thread.create", "commandId": uuid(), "threadId": id, "projectId": project_id, "title": title,
            "modelSelection": selection, "runtimeMode": runtime_mode, "interactionMode": "default",
            "branch": null, "worktreePath": null, "createdAt": iso_now()})
    }

    /// A user message. On a new thread it starts the agent; on an idle one it starts the next turn.
    pub fn send_message(thread_id: &str, text: &str, runtime_mode: &str, title_seed: Option<&str>) -> Value {
        let mut command = json!({"type": "thread.turn.start", "commandId": uuid(), "threadId": thread_id,
            "message": {"messageId": uuid(), "role": "user", "text": text, "attachments": []},
            "runtimeMode": runtime_mode, "interactionMode": "default", "createdAt": iso_now()});
        if let Some(seed) = title_seed {
            command["titleSeed"] = json!(seed);
        }
        command
    }

    /// The desktop control socket request that focuses the window and shows the thread.
    pub fn open_thread(environment_id: &str, thread_id: &str) -> Value {
        json!({"version": 1, "requestId": uuid(), "type": "open-thread", "environmentId": environment_id, "threadId": thread_id})
    }
}

/// The follow-up sent to an idle session when its project gets new annotations.
pub fn nudge_text(numbers: &[i64]) -> String {
    let mut numbers = numbers.to_vec();
    numbers.sort();
    let list: Vec<String> = numbers.iter().map(|n| format!("#{n}")).collect();
    format!("New annotations for this project: {}. Work through them the same way as before, then end your turn.", list.join(", "))
}

/// Conn's HTTP API at `origin`, with a bearer token.
pub struct Client {
    pub origin: url::Url,
    pub token: String,
    http: reqwest::Client,
}

impl Client {
    pub fn new(origin: url::Url, token: String) -> Client {
        Client { origin, token, http: crate::http::short() }
    }

    fn url(&self, path: &str) -> url::Url {
        let mut url = self.origin.clone();
        if let Ok(mut segments) = url.path_segments_mut() {
            segments.pop_if_empty().extend(path.split('/'));
        }
        url
    }

    async fn send(&self, request: reqwest::RequestBuilder) -> Result<Vec<u8>, ConnError> {
        let response = request.header("Authorization", format!("Bearer {}", self.token)).send().await.map_err(|e| {
            ConnError::NotRunning(format!("Conn does not answer at {}: {}", self.origin.as_str().trim_end_matches('/'),
                crate::annotations::describe(&e)))
        })?;
        let status = response.status().as_u16();
        let data = response.bytes().await.map(|b| b.to_vec()).unwrap_or_default();
        match status {
            200..=299 => Ok(data),
            401 | 403 => Err(ConnError::Unauthorized),
            _ => Err(ConnError::Rejected(format!("{status} {}", String::from_utf8_lossy(&data[..data.len().min(300)])))),
        }
    }

    pub async fn snapshot(&self) -> Result<Snapshot, ConnError> {
        let data = self.send(self.http.get(self.url("api/orchestration/snapshot"))).await?;
        serde_json::from_slice(&data).map_err(|_| {
            ConnError::Unexpected("Conn's snapshot has an unexpected shape. This Conn version may not be supported.".into())
        })
    }

    pub async fn thread(&self, id: &str) -> Result<Thread, ConnError> {
        #[derive(Deserialize)]
        struct Body {
            thread: Thread,
        }
        let data = self.send(self.http.get(self.url(&format!("api/orchestration/threads/{id}")))).await?;
        serde_json::from_slice::<Body>(&data).map(|b| b.thread).map_err(|_| {
            ConnError::Unexpected("Conn's thread has an unexpected shape. This Conn version may not be supported.".into())
        })
    }

    pub async fn dispatch(&self, command: &Value) -> Result<(), ConnError> {
        let request = self.http.post(self.url("api/orchestration/dispatch"))
            .header("Content-Type", "application/json").body(command.to_string());
        self.send(request).await.map(|_| ())
    }
}

/// The Conn token in the login Keychain, one item per Conn endpoint.
pub mod keychain {
    use super::*;
    use security_framework::passwords;

    const NOT_FOUND: i32 = -25300;

    pub fn read(account: &str) -> Result<Option<String>, ConnError> {
        match passwords::get_generic_password(KEYCHAIN_SERVICE, account) {
            Ok(data) => Ok(String::from_utf8(data).ok()),
            Err(error) if error.code() == NOT_FOUND => Ok(None),
            Err(error) => Err(ConnError::Unexpected(format!(
                "Could not read the Conn token from the Keychain ({}).", error.code()))),
        }
    }

    pub fn save(token: &str, account: &str) -> Result<(), ConnError> {
        delete(account);
        let mut options = passwords::PasswordOptions::new_generic_password(KEYCHAIN_SERVICE, account);
        options.set_label("Annotator: Conn token");
        passwords::set_generic_password_options(token.as_bytes(), options).map_err(|error| {
            ConnError::Unexpected(format!("Could not save the Conn token in the Keychain ({}).", error.code()))
        })
    }

    pub fn delete(account: &str) {
        let _ = passwords::delete_generic_password(KEYCHAIN_SERVICE, account);
    }
}

/// A process's arguments, read with `KERN_PROCARGS2`: argc, the executable path, then argv.
pub fn process_arguments(pid: i32) -> Vec<String> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut size: libc::size_t = 0;
    unsafe {
        if libc::sysctl(mib.as_mut_ptr(), 3, std::ptr::null_mut(), &mut size, std::ptr::null_mut(), 0) != 0 || size <= 4 {
            return vec![];
        }
        let mut buffer = vec![0u8; size];
        if libc::sysctl(mib.as_mut_ptr(), 3, buffer.as_mut_ptr().cast(), &mut size, std::ptr::null_mut(), 0) != 0 {
            return vec![];
        }
        parse_process_arguments(&buffer[..size])
    }
}

pub fn parse_process_arguments(buffer: &[u8]) -> Vec<String> {
    if buffer.len() < 4 {
        return vec![];
    }
    let argc = i32::from_ne_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]).max(0) as usize;
    let size = buffer.len();
    let mut index = 4;
    while index < size && buffer[index] != 0 { index += 1; } // The executable path.
    while index < size && buffer[index] == 0 { index += 1; } // Padding.
    let mut arguments = Vec::new();
    while arguments.len() < argc && index < size {
        let start = index;
        while index < size && buffer[index] != 0 { index += 1; }
        arguments.push(String::from_utf8_lossy(&buffer[start..index]).into_owned());
        index += 1;
    }
    arguments
}

/// One JSON line to a Unix socket, one JSON line back.
pub async fn send_socket(request: &Value, socket: &Path) -> Result<Value, ConnError> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let path = socket.display().to_string();
    let mut stream = tokio::net::UnixStream::connect(socket).await.map_err(|_| {
        ConnError::NotRunning(format!("The Conn window is not open (no control socket at {path}). Start it and try again."))
    })?;
    let mut line = request.to_string().into_bytes();
    line.push(b'\n');
    let _ = stream.write_all(&line).await;
    let mut reply = Vec::new();
    let read = async {
        let mut chunk = [0u8; 4096];
        while !reply.contains(&b'\n') {
            match stream.read(&mut chunk).await {
                Ok(0) | Err(_) => break,
                Ok(count) => reply.extend_from_slice(&chunk[..count]),
            }
        }
    };
    let _ = tokio::time::timeout(Duration::from_secs(20), read).await;
    let first = reply.split(|b| *b == b'\n').next().unwrap_or_default();
    serde_json::from_slice::<Value>(first).ok().filter(Value::is_object)
        .ok_or_else(|| ConnError::Unexpected("The Conn window gave no answer.".into()))
}

/// One session per project.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub thread_id: String,
    /// Seconds since 2001-01-01, as Swift's JSONEncoder wrote `Date`. Annotations made before this
    /// are covered by the first prompt.
    pub started: f64,
    /// The server endpoint. Sessions on another server are ignored after a settings change.
    pub server: Option<String>,
}

/// Seconds between 1970-01-01 and 2001-01-01.
const REFERENCE_DATE: f64 = 978_307_200.0;

impl Session {
    pub fn started_unix_ms(&self) -> i64 {
        ((self.started + REFERENCE_DATE) * 1000.0) as i64
    }
}

fn now_reference() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0) - REFERENCE_DATE
}

#[derive(Default)]
struct Inner {
    sessions: BTreeMap<String, Session>,
    /// Annotation ids already sent as nudges in this run, so each one is sent once.
    announced: HashSet<String>,
    last_error: Option<String>,
    /// The latest open items and projects, so the timer can retry a nudge for a thread that was busy.
    latest: Option<(Vec<Value>, Vec<Project>)>,
}

/// Starts agent sessions in Conn and keeps them fed.
pub struct Conn {
    file: PathBuf,
    inner: Mutex<Inner>,
    nudging: AtomicBool,
}

pub fn sessions_file() -> PathBuf {
    crate::settings::support_directory().join("sessions.json")
}

impl Conn {
    pub fn new(file: PathBuf) -> Conn {
        let sessions = std::fs::read(&file).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        Conn { file, inner: Mutex::new(Inner { sessions, ..Inner::default() }), nudging: AtomicBool::new(false) }
    }

    pub fn last_error(&self) -> Option<String> {
        self.inner.lock().unwrap().last_error.clone()
    }

    pub fn set_error(&self, message: Option<String>) {
        self.inner.lock().unwrap().last_error = message;
    }

    fn save(&self, sessions: &BTreeMap<String, Session>) {
        match serde_json::to_vec_pretty(sessions) {
            Ok(data) => {
                if let Err(error) = crate::settings::write_atomic(&self.file, &data) {
                    crate::log(&error);
                }
            }
            Err(error) => crate::log(&error.to_string()),
        }
    }

    /// The server that runs the sessions, on this Mac.
    pub fn instance(settings: &Settings) -> Instance {
        Instance::new(&settings.t3_home)
    }

    /// The desktop window that shows them.
    pub fn window(settings: &Settings) -> Instance {
        Instance::new(&settings.t3_window_home)
    }

    fn session_in(sessions: &BTreeMap<String, Session>, project: &Project, settings: &Settings) -> Option<Session> {
        let session = sessions.get(&project.id)?;
        let home = Conn::instance(settings).home.to_string_lossy().to_string();
        let server = session.server.as_deref();
        (server == Some(settings.t3_endpoint.as_str())
            || (server == Some(home.as_str()) && settings.t3_endpoint == LOCAL_ENDPOINT))
            .then(|| session.clone())
    }

    pub fn session(&self, project: &Project, settings: &Settings) -> Option<Session> {
        Conn::session_in(&self.inner.lock().unwrap().sessions, project, settings)
    }

    /// The ids of the projects that have a session on the configured server.
    pub fn session_projects(&self, projects: &[Project], settings: &Settings) -> Vec<String> {
        let inner = self.inner.lock().unwrap();
        projects.iter().filter(|p| Conn::session_in(&inner.sessions, p, settings).is_some()).map(|p| p.id.clone()).collect()
    }

    /// The client for the configured endpoint, with its token from the Keychain.
    pub fn authorized_client(settings: &Settings) -> Result<Client, ConnError> {
        let origin = crate::service_url::parse(&settings.t3_endpoint)
            .ok_or_else(|| ConnError::Unexpected("Enter your Conn server endpoint in Settings.".into()))?;
        if let Some(token) = keychain::read(&settings.t3_endpoint)? {
            return Ok(Client::new(origin, token));
        }
        // Keep an existing local connection without minting new credentials.
        if settings.t3_endpoint == LOCAL_ENDPOINT {
            let home = Conn::instance(settings).home.to_string_lossy().to_string();
            if let Some(token) = keychain::read(&home)? {
                keychain::save(&token, &settings.t3_endpoint)?;
                return Ok(Client::new(origin, token));
            }
        }
        Err(ConnError::Unexpected(
            "Add a Conn access token in Settings. Create it on your Conn server with auth session issue.".into()))
    }

    fn reauthorize(error: ConnError) -> ConnError {
        if error == ConnError::Unauthorized {
            ConnError::Unexpected("Conn rejected the access token. Create a new token on your server and save it in Settings.".into())
        } else {
            error
        }
    }

    /// Creates a thread in the project's folder and sends the prompt. Showing it is a separate action.
    pub async fn start(&self, settings: &Settings, project: &Project, prompt: &str) -> Result<String, String> {
        let result = async {
            if project.root.is_empty() {
                return Err(ConnError::Unexpected(format!("Set a folder for {} in Settings › Projects first.", project.name)));
            }
            let client = Conn::authorized_client(settings)?;
            let run = async {
                let snapshot = client.snapshot().await?;
                let project_id = match snapshot.project(&project.root) {
                    Some(existing) => existing.id.clone(),
                    None => {
                        let id = uuid();
                        client.dispatch(&command::create_project(&id, &project.name, &project.root)).await?;
                        id
                    }
                };
                // The project's model, then the default from Settings, then the server's most recent thread.
                let model = ModelSelection::parse(&project.t3_model)
                    .or_else(|| ModelSelection::parse(&settings.t3_default_model))
                    .or_else(|| snapshot.latest_model())
                    .ok_or_else(|| ConnError::Unexpected("Set a default model in Settings › General › Conn, such as codex/gpt-6.1-sol. This server has no threads to copy one from.".into()))?;
                let thread_id = uuid();
                let title = format!("Annotations · {}", project.name);
                client.dispatch(&command::create_thread(&thread_id, &project_id, &title, &model,
                    &project.t3_runtime_mode, Some(&settings.t3_effort))).await?;
                client.dispatch(&command::send_message(&thread_id, prompt, &project.t3_runtime_mode, Some(&title))).await?;
                Ok::<String, ConnError>(thread_id)
            };
            run.await.map_err(Conn::reauthorize)
        }.await;
        match result {
            Ok(thread_id) => {
                let mut inner = self.inner.lock().unwrap();
                inner.sessions.insert(project.id.clone(),
                    Session { thread_id: thread_id.clone(), started: now_reference(), server: Some(settings.t3_endpoint.clone()) });
                self.save(&inner.sessions);
                inner.last_error = None;
                crate::log(&format!("Conn session {thread_id} started for {}", project.name));
                Ok(thread_id)
            }
            Err(error) => Err(self.fail(format!("Could not start a Conn session for {}: {error}", project.name))),
        }
    }

    /// Focuses the Conn window and shows the project's session.
    pub async fn open(&self, settings: &Settings, project: &Project) -> Result<(), String> {
        let Some(session) = self.session(project, settings) else { return Ok(()) };
        Conn::open_thread(settings, &session.thread_id).await
            .map_err(|error| self.fail(format!("Could not open the Conn session for {}: {error}", project.name)))
    }

    async fn open_thread(settings: &Settings, thread_id: &str) -> Result<(), ConnError> {
        let instance = Conn::instance(settings);
        let window = Conn::window(settings);
        if instance.runtime()?.origin != settings.t3_endpoint {
            return Err(ConnError::Unexpected(format!(
                "Open this session in a Conn window connected to {}. The configured local window belongs to a different server.",
                settings.t3_endpoint)));
        }
        let socket = window.control_socket(&temporary_directory(), unsafe { libc::getuid() });
        let request = command::open_thread(&instance.environment_id()?, thread_id);
        // Right after creation the window may not know the thread yet: retry for about three seconds.
        for attempt in 0..8 {
            let reply = send_socket(&request, &socket).await?;
            if reply["ok"].as_bool() == Some(true) {
                return Ok(());
            }
            let code = reply["code"].as_str().or(reply["error"].as_str()).unwrap_or("unknown").to_string();
            if code == "thread-not-found" && attempt == 7 && window.home != instance.home {
                return Err(ConnError::Rejected("the Conn window does not know this server yet. Pair it once: menu › Conn Sessions › Copy Pairing URL, then paste the URL in Conn under Settings › Connections › Add environment.".into()));
            }
            if code != "thread-not-found" || attempt == 7 {
                return Err(ConnError::Rejected(format!("the Conn window did not open the thread ({code}).")));
            }
            tokio::time::sleep(Duration::from_millis(400)).await;
        }
        Ok(())
    }

    /// A fresh 15-minute pairing URL for the server, to add it in a Conn window under Settings › Connections.
    pub async fn pairing_url(&self, settings: &Settings) -> Result<String, String> {
        let result = async {
            let instance = Conn::instance(settings);
            let runtime = instance.runtime()?;
            if runtime.origin != settings.t3_endpoint {
                return Err(ConnError::Unexpected("Create a pairing link on your selected Conn server with t3 pair.".into()));
            }
            let home = instance.home.to_string_lossy().to_string();
            let output = run_cli(&runtime, &["pair", "--base-dir", &home, "--label", "Annotator sessions", "--ttl", "15m"]).await?;
            pairing_url_in(&output).ok_or_else(|| ConnError::Unexpected("Conn's CLI printed no pairing URL.".into()))
        }.await;
        result.map_err(|error| self.fail(format!("Could not create a pairing URL: {error}")))
    }

    fn fail(&self, message: String) -> String {
        crate::log(&message);
        self.inner.lock().unwrap().last_error = Some(message.clone());
        message
    }

    /// Remembers the latest queue for the 15-second retry timer.
    pub fn remember(&self, open: Vec<Value>, projects: Vec<Project>) {
        self.inner.lock().unwrap().latest = Some((open, projects));
    }

    pub fn latest(&self) -> Option<(Vec<Value>, Vec<Project>)> {
        self.inner.lock().unwrap().latest.clone()
    }

    /// Sends new annotations to their project's idle session. None when there was nothing to do.
    pub async fn nudge(&self, settings: &Settings, open: &[Value], projects: &[Project]) -> Option<Result<(), String>> {
        if !settings.t3_enabled || !settings.t3_nudge || self.nudging.load(Ordering::SeqCst) {
            return None;
        }
        let work: Vec<(Project, Session, Vec<Value>)> = {
            let inner = self.inner.lock().unwrap();
            if inner.sessions.is_empty() {
                return None;
            }
            projects.iter().filter_map(|project| {
                // A full-access thread runs tools without asking. Do not feed it new work on its own.
                if project.t3_runtime_mode == "full-access" {
                    return None;
                }
                let session = Conn::session_in(&inner.sessions, project, settings)?;
                let since = session.started_unix_ms();
                let fresh: Vec<Value> = open.iter().filter(|item| {
                    item["status"] == "todo" && item["question"] != true
                        && item["native"]["project"].as_str() == Some(project.name.as_str())
                        && item["createdAt"].as_i64().unwrap_or(0) > since
                        && !inner.announced.contains(item["id"].as_str().unwrap_or_default())
                }).cloned().collect();
                (!fresh.is_empty()).then(|| (project.clone(), session, fresh))
            }).collect()
        };
        if work.is_empty() || self.nudging.swap(true, Ordering::SeqCst) {
            return None;
        }
        let result = async {
            let client = Conn::authorized_client(settings)?;
            for (project, session, items) in work {
                let step = async {
                    let thread = match client.thread(&session.thread_id).await {
                        Ok(thread) => thread,
                        Err(ConnError::Rejected(message)) if message.starts_with("404") => {
                            // The thread was deleted in Conn: stop sending to it.
                            let mut inner = self.inner.lock().unwrap();
                            inner.sessions.remove(&project.id);
                            self.save(&inner.sessions);
                            return Ok(());
                        }
                        Err(error) => return Err(error),
                    };
                    if !thread.is_idle() {
                        return Ok(()); // The timer tries again.
                    }
                    let numbers: Vec<i64> = items.iter().filter_map(|i| i["number"].as_i64()).collect();
                    client.dispatch(&command::send_message(&session.thread_id, &nudge_text(&numbers),
                        &project.t3_runtime_mode, None)).await?;
                    let mut inner = self.inner.lock().unwrap();
                    inner.announced.extend(items.iter().filter_map(|i| i["id"].as_str().map(String::from)));
                    crate::log(&format!("Nudged Conn session for {}: {numbers:?}", project.name));
                    Ok(())
                };
                step.await.map_err(Conn::reauthorize)?;
            }
            Ok::<(), ConnError>(())
        }.await;
        self.nudging.store(false, Ordering::SeqCst);
        Some(match result {
            Ok(()) => {
                self.set_error(None);
                Ok(())
            }
            Err(error) => Err(self.fail(format!("Could not send new annotations to T3: {error}"))),
        })
    }
}

/// `NSTemporaryDirectory()`: `$TMPDIR`, else `/tmp/`.
pub fn temporary_directory() -> PathBuf {
    std::env::var_os("TMPDIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp/"))
}

/// The pairing URL in the CLI output: the last word with `/pair#token=` on the first line that has one.
pub fn pairing_url_in(output: &str) -> Option<String> {
    let line = output.split('\n').find(|line| line.contains("/pair#token="))?;
    line.split(' ').rfind(|word| word.contains("/pair#token=")).map(String::from)
}

/// Runs Conn's CLI with the same executable and script as the running server, so versions always match.
async fn run_cli(runtime: &Runtime, arguments: &[&str]) -> Result<String, ConnError> {
    let process_arguments = process_arguments(runtime.pid);
    let (Some(executable), Some(script)) =
        (process_arguments.first(), process_arguments.iter().find(|a| a.ends_with("bin.mjs")))
    else {
        return Err(ConnError::NotRunning(format!(
            "Could not find Conn's command-line tool from its running server (pid {}). Is the Conn server running?", runtime.pid)));
    };
    if !app_bundle_installed(executable, script) {
        return Err(ConnError::Unexpected("The Conn command-line tool must be inside an app in /Applications.".into()));
    }
    // The server's environment can hold tokens. Pass only what the CLI needs.
    let output = tokio::process::Command::new(executable).arg(script).args(arguments)
        .env_clear()
        .env("ELECTRON_RUN_AS_NODE", "1")
        .env("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        .env("HOME", crate::settings::home())
        .stdin(std::process::Stdio::null()).output().await
        .map_err(|e| ConnError::Rejected(format!("Conn's CLI failed: {e}")))?;
    if !output.status.success() {
        let errors = String::from_utf8_lossy(&output.stderr[..output.stderr.len().min(300)]).into_owned();
        return Err(ConnError::Rejected(format!("Conn's CLI failed: {errors}")));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Whether a Conn CLI binary and its script live in the same app under `/Applications`, after
/// symlinks are resolved (AppBundleTrust).
pub fn app_bundle_installed(executable: &str, script: &str) -> bool {
    let executable = resolved(executable);
    let script = resolved(script);
    let Some(app) = application_containing(&executable) else { return false };
    script.to_string_lossy().ends_with("bin.mjs") && app.starts_with("/Applications") && script.starts_with(&app)
}

/// The path with symlinks resolved; a missing path is only cleaned up (`.` and `..` removed).
fn resolved(path: &str) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| standardized(Path::new(path)))
}

fn standardized(path: &Path) -> PathBuf {
    let mut clean = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                clean.pop();
            }
            other => clean.push(other),
        }
    }
    clean
}

/// The innermost `.app` folder that holds `path`.
pub fn application_containing(path: &Path) -> Option<PathBuf> {
    path.ancestors().find(|p| p.extension().is_some_and(|e| e == "app")).map(Path::to_path_buf)
}

/// Validates an endpoint like SettingsView: an http(s) origin without a path. Returns it without
/// a trailing slash, or the message to show.
pub fn endpoint(text: &str) -> Result<String, String> {
    let url = crate::service_url::parse(text)
        .ok_or("Use https, or http on 127.0.0.1 or localhost. No user name, query, or fragment.")?;
    if !(url.path().is_empty() || url.path() == "/") {
        return Err("Enter a server origin without a path.".into());
    }
    Ok(url.as_str().trim_end_matches('/').to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{closed_url, serve, Reply};

    #[test]
    fn control_socket_matches_the_desktop_app() {
        // Measured on this Mac: the dev desktop app listens on 386eeb9714d92a2fe2c051a9.sock.
        let instance = Instance { home: PathBuf::from("/Users/nckrtl/.t3/desktop-dev") };
        assert_eq!(instance.control_socket(Path::new("/tmp/x"), 501),
            Path::new("/tmp/x/t3code-501/386eeb9714d92a2fe2c051a9.sock"));
        let production = Instance::new("/Users/nckrtl/.t3/");
        assert_eq!(production.control_socket(Path::new("/tmp/x"), 501).file_name().unwrap(), "d9cfc0e3f7eae2d02b72a685.sock");
    }

    #[test]
    fn model_text() {
        assert_eq!(ModelSelection::parse("codex/gpt-6.1-sol"),
            Some(ModelSelection { instance_id: "codex".into(), model: "gpt-6.1-sol".into() }));
        assert_eq!(ModelSelection::parse("codex"), None);
        assert_eq!(ModelSelection::parse(" /x"), None);
    }

    #[test]
    fn snapshot_helpers() {
        let json = r#"{"snapshotSequence":1,"projects":[
          {"id":"old","title":"t3","workspaceRoot":"/tmp","deletedAt":"2026-01-01T00:00:00Z"},
          {"id":"p1","title":"t3","workspaceRoot":"/tmp/","deletedAt":null}],
         "threads":[
          {"id":"a","projectId":"p1","modelSelection":{"instanceId":"codex","model":"gpt-6-astra"},"updatedAt":"2026-10-07T13:00:00Z","deletedAt":null,
           "session":{"status":"ready","activeTurnId":null}},
          {"id":"b","projectId":"p1","modelSelection":{"instanceId":"codex","model":"gpt-6.1-sol"},"updatedAt":"2026-10-07T20:00:00Z","deletedAt":null,
           "session":{"status":"running","activeTurnId":"t1"}}]}"#;
        let snapshot: Snapshot = serde_json::from_str(json).unwrap();
        assert_eq!(snapshot.project("/tmp").unwrap().id, "p1");
        assert!(snapshot.project("/nowhere").is_none());
        assert_eq!(snapshot.latest_model().unwrap().model, "gpt-6.1-sol");
        assert!(snapshot.threads[0].is_idle());
        assert!(!snapshot.threads[1].is_idle());
    }

    #[test]
    fn commands() {
        let model = ModelSelection { instance_id: "codex".into(), model: "m".into() };
        let create = command::create_thread("t", "p", "Annotations", &model, "full-access", None);
        assert_eq!(create["type"], "thread.create");
        assert_eq!(create["modelSelection"], json!({"instanceId": "codex", "model": "m"}));
        assert!(create["worktreePath"].is_null() && create.get("worktreePath").is_some());
        let message = command::send_message("t", "Go", "full-access", Some("Go"));
        assert_eq!(message["type"], "thread.turn.start");
        assert_eq!(message["message"]["text"], "Go");
        assert_eq!(message["titleSeed"], "Go");
        assert_eq!(command::open_thread("e", "t")["type"], "open-thread");
        assert!(nudge_text(&[15, 14]).starts_with("New annotations for this project: #14, #15."));
        let created = command::create_project("p", "Shop", "/a")["createdAt"].as_str().unwrap().to_string();
        assert!(created.ends_with('Z') && created.contains('.'), "{created}");
    }

    #[test]
    fn opus_medium_command() {
        let command = command::create_thread("t", "p", "Annotations",
            &ModelSelection::parse("claudeAgent/claude-opus-5-5").unwrap(), "full-access", Some("medium"));
        assert_eq!(command["modelSelection"]["model"], "claude-opus-5-5");
        assert_eq!(command["modelSelection"]["options"], json!([{"id": "effort", "value": "medium"}]));
        let codex = command::create_thread("t", "p", "A", &ModelSelection::parse("codex/x").unwrap(), "auto", Some("high"));
        assert_eq!(codex["modelSelection"]["options"], json!([{"id": "reasoningEffort", "value": "high"}]));
    }

    #[tokio::test]
    async fn client_errors() {
        let server = serve(vec![Reply::new(401, "")]);
        let client = Client::new(server.url(""), "x".into());
        assert_eq!(client.snapshot().await.unwrap_err(), ConnError::Unauthorized);
        let down = Client::new(closed_url(""), "x".into());
        assert!(matches!(down.dispatch(&json!({"type": "x"})).await, Err(ConnError::NotRunning(_))));

        let server = serve(vec![Reply::new(200, "")]);
        Client::new(server.url(""), "secret".into()).dispatch(&json!({"type": "x"})).await.unwrap();
        let request = server.request(0);
        assert_eq!(request.header("authorization"), Some("Bearer secret"));
        assert_eq!(request.path, "/api/orchestration/dispatch");
        assert_eq!(serde_json::from_slice::<Value>(&request.body).unwrap(), json!({"type": "x"}));

        let server = serve(vec![Reply::new(404, "gone")]);
        assert_eq!(Client::new(server.url(""), "x".into()).thread("t").await.unwrap_err(), ConnError::Rejected("404 gone".into()));
        assert_eq!(server.request(0).path, "/api/orchestration/threads/t");
    }

    #[test]
    fn process_arguments_layout() {
        let mut buffer = 3i32.to_ne_bytes().to_vec();
        buffer.extend_from_slice(b"/usr/bin/node\0\0\0node\0/x/bin.mjs\0serve\0PATH=/bin\0");
        assert_eq!(parse_process_arguments(&buffer), ["node", "/x/bin.mjs", "serve"]);
        let own = process_arguments(std::process::id() as i32);
        assert!(!own.is_empty());
    }

    #[test]
    fn pairing_url_from_output() {
        let output = "Created pairing link\nOpen http://127.0.0.1:3780/pair#token=abc in Conn\n";
        assert_eq!(pairing_url_in(output).as_deref(), Some("http://127.0.0.1:3780/pair#token=abc"));
        assert_eq!(pairing_url_in("nothing"), None);
    }

    #[test]
    fn endpoints() {
        let invalid = Err("Use https, or http on 127.0.0.1 or localhost. No user name, query, or fragment.".to_string());
        assert_eq!(endpoint("http://127.0.0.1:3780/"), Ok("http://127.0.0.1:3780".into()));
        assert_eq!(endpoint("https://conn.example.com"), Ok("https://conn.example.com".into()));
        assert_eq!(endpoint("http://127.0.0.1:3780/api"), Err("Enter a server origin without a path.".into()));
        assert_eq!(endpoint("http://a@127.0.0.1:3780"), invalid);
        assert_eq!(endpoint("http://conn.example.com"), invalid);
        assert_eq!(endpoint("http://127.0.0.1:3780?x"), invalid);
        assert_eq!(endpoint("127.0.0.1:3780"), invalid);
    }

    #[test]
    fn pairing_binary_must_live_in_applications() {
        let script = "/Applications/AnnotatorTrustTest.app/Contents/Resources/app.asar/apps/server/dist/bin.mjs";
        assert!(app_bundle_installed("/Applications/AnnotatorTrustTest.app/Contents/MacOS/Conn", script));
        assert!(!app_bundle_installed("/Applications/AnnotatorTrustTest.app/Contents/MacOS/Conn", "/tmp/bin.mjs"));
        assert!(!app_bundle_installed("/Users/me/Conn.app/Contents/MacOS/Conn", "/Users/me/Conn.app/Contents/Resources/bin.mjs"));
        assert!(!app_bundle_installed("/Applications/AnnotatorTrustTest.app/Contents/MacOS/Conn",
            "/Applications/AnnotatorTrustTest.app/../../tmp/bin.mjs"));
        assert!(!app_bundle_installed("/Applications/AnnotatorTrustTest.app/../../Users/me/X.app/Contents/MacOS/Conn",
            "/Users/me/X.app/bin.mjs"));
        assert_eq!(application_containing(Path::new("/Applications/AnnotatorTrustTest.app/Contents/MacOS/Conn")).as_deref(),
            Some(Path::new("/Applications/AnnotatorTrustTest.app")));
        // Symlinks are resolved: a link in /Applications to an app elsewhere is not trusted.
        let folder = crate::testutil::temp_dir("conn-trust");
        std::fs::create_dir_all(folder.join("Fake.app/Contents/MacOS")).unwrap();
        std::fs::write(folder.join("Fake.app/Contents/MacOS/Conn"), "").unwrap();
        std::fs::write(folder.join("Fake.app/bin.mjs"), "").unwrap();
        assert!(!app_bundle_installed(&folder.join("Fake.app/Contents/MacOS/Conn").to_string_lossy(),
            &folder.join("Fake.app/bin.mjs").to_string_lossy()));
        let _ = std::fs::remove_dir_all(&folder);
    }

    #[tokio::test]
    async fn nudge_skips_full_access_projects() {
        let file = crate::testutil::temp_dir("conn").join("sessions.json");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, r#"{"p":{"threadId":"t","started":1,"server":"http://127.0.0.1:1"}}"#).unwrap();
        let conn = Conn::new(file);
        let settings = Settings { t3_endpoint: "http://127.0.0.1:1".into(), t3_nudge: true, ..Settings::default() };
        let project = Project { id: "p".into(), t3_runtime_mode: "full-access".into(), ..Project::new("P") };
        let open = [json!({"id": "a", "status": "todo", "number": 1, "createdAt": i64::MAX,
            "native": {"project": "P"}})];
        assert!(conn.nudge(&settings, &open, &[project]).await.is_none());
    }

    #[test]
    fn sessions_follow_the_endpoint() {
        let file = crate::testutil::temp_dir("conn").join("sessions.json");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        // Written by the Swift app: `started` is seconds since 2001.
        std::fs::write(&file, r#"{"p":{"threadId":"t","started":781900000.5,"server":"http://127.0.0.1:3780"},
            "q":{"threadId":"u","started":1,"server":"/Users/me/.t3/headless"}}"#).unwrap();
        let conn = Conn::new(file);
        let mut settings = Settings { t3_home: "/Users/me/.t3/headless".into(), ..Settings::default() };
        let p = Project { id: "p".into(), ..Project::new("P") };
        let q = Project { id: "q".into(), ..Project::new("Q") };
        assert_eq!(conn.session_projects(&[p.clone(), q.clone()], &settings), ["p", "q"]);
        assert_eq!(conn.session(&p, &settings).unwrap().started_unix_ms(), 1_760_207_200_500);
        settings.t3_endpoint = "http://other:3780".into();
        assert!(conn.session_projects(&[p, q], &settings).is_empty());
    }

    #[tokio::test]
    async fn nudge_without_sessions_does_nothing() {
        let file = crate::testutil::temp_dir("conn").join("sessions.json");
        let conn = Conn::new(file);
        let settings = Settings { t3_endpoint: "http://127.0.0.1:1".into(), ..Settings::default() };
        assert!(conn.nudge(&settings, &[], &[]).await.is_none(), "no sessions, nothing to do");
    }
}
