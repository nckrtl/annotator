//! Small, forward-compatible views of Conn's V1 and V2 read models.
use super::{ConnError, ModelSelection, normalize};
use serde::{Deserialize, Deserializer};
use serde_json::Value;

/// Optional hints must not prevent a session from starting when Conn changes them.
fn hint<'de, D: Deserializer<'de>, T: serde::de::DeserializeOwned>(d: D) -> Result<Option<T>, D::Error> {
    Ok(serde_json::from_value(Value::deserialize(d)?).ok())
}

fn present<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Value>, D::Error> {
    Value::deserialize(d).map(Some)
}

fn nonempty<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    let text = String::deserialize(d)?;
    if text.trim().is_empty() { return Err(serde::de::Error::custom("must be a non-empty string")); }
    Ok(text)
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub projects: Vec<SnapshotProject>,
    #[serde(default, deserialize_with = "hint")]
    threads: Option<Vec<ModelHint>>,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotProject {
    #[serde(deserialize_with = "nonempty")]
    pub id: String,
    #[serde(deserialize_with = "nonempty")]
    workspace_root: String,
    #[serde(default)]
    deleted_at: Value,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct ModelHint {
    #[serde(default, deserialize_with = "hint")]
    model_selection: Option<ModelSelection>,
    #[serde(default)]
    updated_at: Value,
    #[serde(default)]
    deleted_at: Value,
}

impl Snapshot {
    pub fn project(&self, root: &str) -> Option<&SnapshotProject> {
        let wanted = normalize(root);
        self.projects.iter().find(|p| p.deleted_at.is_null() && normalize(&p.workspace_root) == wanted)
    }

    pub fn latest_model(&self) -> Option<ModelSelection> {
        self.threads.as_ref()?.iter()
            .filter(|t| t.deleted_at.is_null() && t.model_selection.as_ref()
                .is_some_and(|m| !m.instance_id.trim().is_empty() && !m.model.trim().is_empty()))
            .max_by_key(|t| timestamp(&t.updated_at))
            .and_then(|t| t.model_selection.clone())
    }
}

fn timestamp(value: &Value) -> i64 {
    value.as_i64().or_else(|| value.as_str().and_then(|s|
        chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp_millis())))
        .unwrap_or(i64::MIN)
}

#[derive(Deserialize, Debug, Default, PartialEq)]
#[serde(rename_all = "snake_case")]
enum Status {
    Idle, Ready, Stopped, Error,
    Completed, Interrupted, Failed, Cancelled, RolledBack,
    #[default]
    #[serde(other)]
    Unknown,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct Session {
    #[serde(default, deserialize_with = "hint")]
    status: Option<Status>,
    // Keep presence distinct from null: absent activity information is not proof of idle.
    #[serde(default, deserialize_with = "present")]
    active_turn_id: Option<Value>,
}

#[derive(Deserialize, Debug)]
pub struct Thread {
    #[serde(deserialize_with = "nonempty")]
    pub id: String,
    #[serde(default, deserialize_with = "hint")]
    session: Option<Session>,
    #[serde(default, rename = "deletedAt")]
    deleted_at: Value,
    #[serde(skip)]
    runs_idle: Option<bool>,
}

impl Thread {
    pub fn is_idle(&self) -> bool {
        if !self.deleted_at.is_null() { return false; }
        if let Some(idle) = self.runs_idle { return idle; }
        self.session.as_ref().is_some_and(|s|
            matches!(s.status, Some(Status::Ready | Status::Idle | Status::Stopped | Status::Error))
                && s.active_turn_id.as_ref() == Some(&Value::Null))
    }
}

#[derive(Deserialize)]
struct Run {
    #[serde(default, deserialize_with = "hint")]
    status: Option<Status>,
}

#[derive(Deserialize)]
struct Projection {
    thread: Thread,
    #[serde(default, deserialize_with = "hint")]
    runs: Option<Vec<Run>>,
}

#[derive(Deserialize)]
struct CurrentThread { projection: Projection }
#[derive(Deserialize)]
struct OldThread { thread: Thread }

pub fn thread(data: &[u8], v2: bool, version: Option<&str>) -> Result<Thread, ConnError> {
    if !v2 { return decode::<OldThread>(data, "thread", version).map(|b| b.thread); }
    let mut projection = decode::<CurrentThread>(data, "thread", version)?.projection;
    projection.thread.runs_idle = Some(projection.runs.is_some_and(|runs| runs.iter().all(|r|
        matches!(r.status, Some(Status::Completed | Status::Interrupted | Status::Failed | Status::Cancelled | Status::RolledBack)))));
    Ok(projection.thread)
}

pub fn decode<T: serde::de::DeserializeOwned>(data: &[u8], name: &str, version: Option<&str>) -> Result<T, ConnError> {
    if data.iter().copied().find(|b| !b.is_ascii_whitespace()) == Some(b'<') {
        return Err(problem(name, "response is HTML instead of JSON; check the Conn endpoint and API version", version));
    }
    let mut decoder = serde_json::Deserializer::from_slice(data);
    let result = serde_path_to_error::deserialize(&mut decoder).map_err(|e| {
        problem(name, &format!("{}: {}", e.path(), e.inner()), version)
    })?;
    decoder.end().map_err(|_| problem(name, "response: trailing data after JSON", version))?;
    Ok(result)
}

pub fn problem(name: &str, detail: &str, version: Option<&str>) -> ConnError {
    let version = version.map(|v| format!(" (version {v})")).unwrap_or_default();
    ConnError::Unexpected(format!("Could not read Conn's {name}{version}: {detail}."))
}
