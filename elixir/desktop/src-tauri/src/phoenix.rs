use std::net::TcpStream;
use std::process::{Child, Command};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

pub struct PhoenixProcess(pub Mutex<Option<Child>>);

const PHOENIX_PORT: u16 = 4000;
const READY_TIMEOUT: Duration = Duration::from_secs(30);
const POLL_INTERVAL: Duration = Duration::from_millis(300);

/// Start the Phoenix server and wait until it's ready.
pub fn start_phoenix(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let child = spawn_phoenix()?;
    app.manage(PhoenixProcess(Mutex::new(Some(child))));
    wait_for_ready()?;
    Ok(())
}

/// Get the current status of the Phoenix process.
pub fn get_status(app: &AppHandle) -> String {
    let state = app.state::<PhoenixProcess>();
    let mut guard = state.0.lock().unwrap();

    match guard.as_mut() {
        Some(child) => match child.try_wait() {
            Ok(Some(status)) => format!("exited: {}", status),
            Ok(None) => "running".to_string(),
            Err(e) => format!("error: {}", e),
        },
        None => "not started".to_string(),
    }
}

/// Restart the Phoenix server.
pub fn restart(app: &AppHandle) -> Result<(), String> {
    let state = app.state::<PhoenixProcess>();
    let mut guard = state.0.lock().unwrap();

    // Kill existing process
    if let Some(ref mut child) = *guard {
        let _ = child.kill();
        let _ = child.wait();
    }

    // Spawn new process
    match spawn_phoenix() {
        Ok(child) => {
            *guard = Some(child);
            wait_for_ready().map_err(|e| format!("Phoenix started but not ready: {}", e))
        }
        Err(e) => Err(format!("Failed to restart Phoenix: {}", e)),
    }
}

fn spawn_phoenix() -> Result<Child, std::io::Error> {
    let project_dir = resolve_project_dir();

    Command::new("elixir")
        .arg("-e")
        .arg("Application.put_env(:symphony_elixir, :server_port_override, 4000)")
        .arg("-S")
        .arg("mix")
        .arg("run")
        .arg("--no-halt")
        .current_dir(&project_dir)
        .env("CLAUDECODE", "")
        .spawn()
}

/// Poll TCP port until Phoenix is accepting connections.
fn wait_for_ready() -> Result<(), Box<dyn std::error::Error>> {
    let start = Instant::now();
    loop {
        if TcpStream::connect(("127.0.0.1", PHOENIX_PORT)).is_ok() {
            return Ok(());
        }
        if start.elapsed() > READY_TIMEOUT {
            return Err("Phoenix server did not start within timeout".into());
        }
        std::thread::sleep(POLL_INTERVAL);
    }
}

fn resolve_project_dir() -> String {
    if let Ok(dir) = std::env::var("SYMPHONY_PROJECT_DIR") {
        return dir;
    }

    #[cfg(target_os = "macos")]
    {
        if let Ok(exe) = std::env::current_exe() {
            if let Some(macos_dir) = exe.parent() {
                let bundle_resource = macos_dir.join("../Resources/elixir");
                if bundle_resource.exists() {
                    return bundle_resource.to_string_lossy().to_string();
                }
            }
        }
    }

    std::env::current_dir()
        .map(|p| {
            let parent = p.parent().unwrap_or(&p);
            parent.to_string_lossy().to_string()
        })
        .unwrap_or_else(|_| ".".to_string())
}

impl Drop for PhoenixProcess {
    fn drop(&mut self) {
        if let Some(ref mut child) = *self.0.lock().unwrap() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
