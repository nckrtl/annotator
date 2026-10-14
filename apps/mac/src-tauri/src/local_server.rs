//! Starts and stops a local annotation server (LocalServer.swift). Controls only servers
//! registered in Annotator's own state folder `~/.annotator`.

use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub struct LocalServer {
    pub port: u16,
    pub home: PathBuf,
}

#[derive(Deserialize, Debug, Clone, PartialEq)]
pub struct Outcome {
    pub running: bool,
    pub error: Option<String>,
}

impl LocalServer {
    /// Only `http://127.0.0.1:<port>/annotations` or `http://localhost:<port>/annotations`.
    pub fn new(url: &url::Url, home: &Path) -> Option<LocalServer> {
        let path = url.path();
        let path = if path.len() > 1 { path.trim_end_matches('/') } else { path };
        let local = url.scheme() == "http"
            && matches!(url.host_str(), Some("127.0.0.1" | "localhost"))
            && path == "/annotations"
            && url.query().is_none()
            && url.fragment().is_none()
            && url.username().is_empty()
            && url.password().is_none();
        local.then(|| LocalServer { port: url.port().unwrap_or(80), home: home.to_path_buf() })
    }

    pub fn state(&self) -> PathBuf {
        self.home.join(format!(".annotator/server-{}.json", self.port))
    }

    pub fn log(&self) -> PathBuf {
        self.home.join(format!(".annotator/server-{}.log", self.port))
    }

    pub fn store(&self) -> PathBuf {
        let existing = self.home.join(".t3/dev/annotations");
        if existing.exists() { existing } else { self.home.join(".annotator/annotations") }
    }

    /// The first trusted Node.js. Fixed locations first, so a planted file under the home folder
    /// does not outrank them.
    pub fn node(&self) -> Option<PathBuf> {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].iter().map(PathBuf::from)
            .chain([".local/share/mise/shims/node", ".vite-plus/bin/node"].iter().map(|p| self.home.join(p)))
            .find(|path| is_trusted_executable(path))
    }

    /// Runs `serve.mjs <command>` (`status`, `start`, `stop`) and reads its JSON answer.
    pub async fn run(&self, command: &str) -> Result<Outcome, String> {
        let node = self.node()
            .ok_or("Node.js was not found. Install Node.js 22 or newer to start the annotation server.")?;
        let script = self.home.join("apps/annotator/packages/annotator/bin/serve.mjs");
        if !script.exists() {
            return Err(format!("The annotation server was not found at {}.", script.display()));
        }
        let output = std::env::temp_dir().join(format!("annotator-command-{}", uuid::Uuid::new_v4()));
        let result = self.run_with(&node, &script, command, &output).await;
        let _ = std::fs::remove_file(&output);
        result
    }

    async fn run_with(&self, node: &Path, script: &Path, command: &str, output: &Path) -> Result<Outcome, String> {
        let file = std::fs::File::create(output).map_err(|e| e.to_string())?;
        let errors = file.try_clone().map_err(|e| e.to_string())?;
        let mut process = tokio::process::Command::new(node);
        process.arg(script).arg(command).arg("--state").arg(self.state());
        if command == "start" {
            process.arg("--port").arg(self.port.to_string()).arg("--store").arg(self.store());
        }
        let mut child = process.stdout(file).stderr(errors).stdin(std::process::Stdio::null())
            .kill_on_drop(true).spawn().map_err(|e| e.to_string())?;
        // Bound a hung runtime.
        let status = match tokio::time::timeout(Duration::from_secs(15), child.wait()).await {
            Ok(status) => status.map_err(|e| e.to_string())?,
            Err(_) => {
                let _ = child.kill().await;
                return Err(format!("The server command timed out. See {}.", self.log().display()));
            }
        };
        let data = std::fs::read(output).unwrap_or_default();
        let Some(outcome) = result_in(&data) else {
            let text = String::from_utf8_lossy(&data).trim().to_string();
            return Err(if text.is_empty() { "The server returned an unreadable response.".into() } else { text });
        };
        if let Some(error) = outcome.error {
            return Err(error);
        }
        if !status.success() {
            return Err(format!("The server command failed. See {}.", self.log().display()));
        }
        Ok(outcome)
    }
}

/// The script prints one JSON object. Lines before it, such as a runtime warning, are ignored.
fn result_in(data: &[u8]) -> Option<Outcome> {
    String::from_utf8_lossy(data).lines().rev()
        .map(str::trim)
        .filter(|line| line.starts_with('{'))
        .find_map(|line| serde_json::from_str(line).ok())
}

/// Executable, and not writable by everyone: a world-writable Node would run as the user.
/// Follows symlinks, like FileManager.
fn is_trusted_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| {
        let mode = m.permissions().mode();
        m.is_file() && mode & 0o111 != 0 && mode & 0o002 == 0
    })
}

/// Whether anything answers at `url` within 2 s: an existing server can serve the queue without
/// becoming ours.
pub async fn answers(url: &url::Url) -> bool {
    let mut health = url.clone();
    health.set_path(&format!("{}/health", url.path().trim_end_matches('/').trim_end_matches("/annotations")));
    crate::http::short().get(health).timeout(Duration::from_secs(2)).send().await.is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::temp_dir;

    fn server(text: &str) -> Option<LocalServer> {
        LocalServer::new(&url::Url::parse(text).unwrap(), Path::new("/Users/me"))
    }

    #[test]
    fn only_local_annotation_endpoints() {
        for value in ["https://127.0.0.1:29703/annotations", "http://example.com/annotations",
            "http://127.0.0.1/other", "http://localhost/annotations?x=1", "http://u:p@localhost/annotations"] {
            assert!(server(value).is_none(), "{value}");
        }
        assert_eq!(server("http://localhost:29703/annotations").unwrap().port, 29703);
        assert_eq!(server("http://127.0.0.1/annotations").unwrap().port, 80);
        let local = server("http://127.0.0.1:29703/annotations").unwrap();
        assert_eq!(local.state(), Path::new("/Users/me/.annotator/server-29703.json"));
        assert_eq!(local.log(), Path::new("/Users/me/.annotator/server-29703.log"));
    }

    #[tokio::test]
    async fn missing_node_or_script_says_so() {
        let home = temp_dir("annotator-home");
        std::fs::create_dir_all(&home).unwrap();
        let local = LocalServer::new(&url::Url::parse("http://127.0.0.1:39744/annotations").unwrap(), &home).unwrap();
        let error = local.run("status").await.unwrap_err();
        // Homebrew's node may exist on this Mac; then the script is missing.
        assert!(error.starts_with("Node.js was not found") || error.starts_with("The annotation server was not found"), "{error}");
    }

    #[test]
    fn node_output_is_the_last_json_line() {
        let data = b"(node:1) ExperimentalWarning: something\n{\"running\":true,\"error\":null}\n";
        assert_eq!(result_in(data), Some(Outcome { running: true, error: None }));
        assert_eq!(result_in(b"{\"running\":false}"), Some(Outcome { running: false, error: None }));
        assert_eq!(result_in(b"warning only\n"), None);
    }

    #[test]
    fn world_writable_node_is_skipped() {
        use std::os::unix::fs::PermissionsExt;
        let folder = temp_dir("annotator-node");
        std::fs::create_dir_all(&folder).unwrap();
        let file = folder.join("node");
        std::fs::write(&file, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(is_trusted_executable(&file));
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(!is_trusted_executable(&file));
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(!is_trusted_executable(&file));
        let _ = std::fs::remove_dir_all(&folder);
    }

    #[tokio::test]
    async fn answers_reports_an_existing_server() {
        let server = crate::testutil::serve(vec![crate::testutil::Reply::new(404, "")]);
        assert!(answers(&server.url("/annotations")).await);
        assert_eq!(server.paths(), ["/health"]);
        assert!(!answers(&crate::testutil::closed_url("/annotations")).await);
    }

    /// Needs Node.js and the monorepo at ~/apps/annotator, like the Swift test.
    #[tokio::test]
    #[ignore]
    async fn server_lifecycle() {
        let real = crate::settings::home();
        let home = temp_dir("annotator-lifecycle");
        std::fs::create_dir_all(home.join("apps")).unwrap();
        std::fs::create_dir_all(home.join(".vite-plus/bin")).unwrap();
        std::os::unix::fs::symlink(real.join("apps/annotator"), home.join("apps/annotator")).unwrap();
        std::os::unix::fs::symlink(real.join(".vite-plus/bin/node"), home.join(".vite-plus/bin/node")).unwrap();
        let server = LocalServer::new(&url::Url::parse("http://127.0.0.1:39743/annotations").unwrap(), &home).unwrap();
        let run = async {
            assert!(!server.run("status").await?.running);
            assert!(server.run("start").await?.running);
            assert!(server.run("status").await?.running);
            // Repeated start keeps the same server and store.
            let first = std::fs::read(server.state()).unwrap();
            assert!(server.run("start").await?.running);
            assert_eq!(std::fs::read(server.state()).unwrap(), first);
            assert!(!server.run("stop").await?.running);
            assert!(!server.run("status").await?.running);
            assert!(server.run("start").await?.running);
            assert!(!server.run("stop").await?.running);
            Ok::<(), String>(())
        };
        let result = run.await;
        let _ = server.run("stop").await;
        let _ = std::fs::remove_dir_all(&home);
        result.unwrap();
    }
}
