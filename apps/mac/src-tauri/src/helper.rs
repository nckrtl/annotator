//! The Swift helper (native/): Accessibility, the overlay and screen capture. JSON lines both
//! ways: commands on its stdin ({"action": …}), events on its stdout ({"type": …}); app.rs
//! handles the events. A helper that stops on its own restarts after 0.5, 2 and 5 s (as Operator's
//! supervisor.rs); a fourth stop within a minute gives up until the next command starts it.

use serde_json::Value;
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};


pub const WINDOW: Duration = Duration::from_secs(60);
pub const BACKOFF: [Duration; 3] = [Duration::from_millis(500), Duration::from_secs(2), Duration::from_secs(5)];

#[derive(Debug, PartialEq)]
pub enum Decision {
    Restart(Duration),
    GiveUp,
}

/// Counts unexpected stops within a minute.
#[derive(Default)]
pub struct Supervisor {
    exits: VecDeque<Instant>,
}

impl Supervisor {
    pub fn exited(&mut self, now: Instant) -> Decision {
        while self.exits.front().is_some_and(|at| now.duration_since(*at) > WINDOW) {
            self.exits.pop_front();
        }
        self.exits.push_back(now);
        if self.exits.len() > BACKOFF.len() {
            self.exits.clear();
            Decision::GiveUp
        } else {
            Decision::Restart(BACKOFF[self.exits.len() - 1])
        }
    }
}

pub fn failure_message() -> String {
    format!("The native helper stopped {} times within a minute. Start annotating to try again.", BACKOFF.len() + 1)
}

struct Running {
    child: Child,
    stdin: ChildStdin,
    generation: u64,
}

#[derive(Default)]
struct Inner {
    running: Option<Running>,
    generation: u64,
    supervisor: Supervisor,
    /// Set while Annotator quits, so the stop is not a crash.
    stopping: bool,
}

#[derive(Default)]
pub struct Helper(Mutex<Inner>);

fn binary(_app: &crate::runtime::AppHandle) -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("ANNOTATOR_HELPER") { return Ok(PathBuf::from(path)); }
    Ok(std::env::current_exe().map_err(|e| e.to_string())?.with_file_name("annotator-native"))
}

fn launch(app: &crate::runtime::AppHandle, generation: u64) -> Result<Running, String> {
    let path = binary(app)?;
    let mut child = Command::new(&path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Could not start the native helper at {}: {e}", path.display()))?;
    let stdin = child.stdin.take().expect("helper stdin");
    let stdout = child.stdout.take().expect("helper stdout");
    let stderr = child.stderr.take().expect("helper stderr");
    let events = app.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            match serde_json::from_str::<Value>(&line) {
                Ok(event) => {
                    if event["type"] != "selected" {
                        crate::log(&format!("helper: {line}"));
                    } else {
                        crate::log("helper: selected");
                    }
                    crate::app::helper_event(&events, event);
                }
                Err(_) => crate::log(&format!("helper printed a line that is not JSON: {line}")),
            }
        }
        exited(&events, generation);
    });
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            crate::log(&format!("helper stderr: {line}"));
        }
    });
    Ok(Running { child, stdin, generation })
}

/// The helper's output ended: restart it with backoff, unless Annotator stops it.
fn exited(app: &crate::runtime::AppHandle, generation: u64) {
    let decision = {
        let state = app.state::<Helper>();
        let mut inner = state.0.lock().unwrap();
        if inner.running.as_ref().is_none_or(|r| r.generation != generation) || inner.stopping {
            return;
        }
        if let Some(mut running) = inner.running.take() {
            let _ = running.child.wait();
        }
        inner.supervisor.exited(Instant::now())
    };
    crate::log(&format!("helper exited: {decision:?}"));
    match decision {
        Decision::Restart(delay) => {
            crate::app::helper_stopped(app, Some("The native helper stopped. Restarting it…".into()));
            let handle = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(delay);
                if let Err(error) = start(&handle) {
                    crate::app::helper_stopped(&handle, Some(error));
                }
            });
        }
        Decision::GiveUp => crate::app::helper_stopped(app, Some(failure_message())),
    }
}

/// Starts the helper when it is not running.
pub fn start(app: &crate::runtime::AppHandle) -> Result<(), String> {
    let state = app.state::<Helper>();
    let mut inner = state.0.lock().unwrap();
    if inner.running.is_none() && !inner.stopping {
        inner.generation += 1;
        let generation = inner.generation;
        inner.running = Some(launch(app, generation)?);
        // Ask at once; the answer also tells the app the helper is back.
        let _ = write(&mut inner, &serde_json::json!({"action": "ping"}));
    }
    Ok(())
}

fn write(inner: &mut Inner, command: &Value) -> Result<(), String> {
    let Some(running) = inner.running.as_mut() else { return Err("The native helper is not running.".into()) };
    let line = format!("{command}\n");
    running.stdin.write_all(line.as_bytes()).and_then(|_| running.stdin.flush())
        .map_err(|error| format!("The native helper did not take the command: {error}"))
}

/// Sends one command, starting the helper first when it is not running.
pub fn send(app: &crate::runtime::AppHandle, command: &Value) -> Result<(), String> {
    start(app)?;
    let state = app.state::<Helper>();
    let mut inner = state.0.lock().unwrap();
    write(&mut inner, command)
}

pub fn stop(app: &crate::runtime::AppHandle) {
    let state = app.state::<Helper>();
    let mut inner = state.0.lock().unwrap();
    inner.stopping = true;
    if let Some(mut running) = inner.running.take() {
        let _ = running.child.kill();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn three_restarts_with_backoff_then_give_up() {
        let start = Instant::now();
        let mut supervisor = Supervisor::default();
        assert_eq!(supervisor.exited(start), Decision::Restart(Duration::from_millis(500)));
        assert_eq!(supervisor.exited(start + Duration::from_secs(1)), Decision::Restart(Duration::from_secs(2)));
        assert_eq!(supervisor.exited(start + Duration::from_secs(4)), Decision::Restart(Duration::from_secs(5)));
        assert_eq!(supervisor.exited(start + Duration::from_secs(10)), Decision::GiveUp);
        // After giving up, the next start counts from zero.
        assert_eq!(supervisor.exited(start + Duration::from_secs(11)), Decision::Restart(Duration::from_millis(500)));
    }

    #[test]
    fn old_stops_expire() {
        let start = Instant::now();
        let mut supervisor = Supervisor::default();
        supervisor.exited(start);
        supervisor.exited(start + Duration::from_secs(1));
        assert_eq!(supervisor.exited(start + Duration::from_secs(70)), Decision::Restart(Duration::from_millis(500)));
    }
}
