//! Small, persistent log runner for developer-facing Just recipes.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use camino::Utf8PathBuf;
use clap::Args;
use serde::Serialize;

const FAILURE_EXCERPT_BYTES: u64 = 8 * 1024;
const FAILURE_EXCERPT_LINES: usize = 80;
const DEFAULT_LOG_ROOT: &str = "target/run";

#[derive(Debug, Args)]
pub(crate) struct RunLoggedArgs {
    /// Root for persistent per-run logs.
    #[arg(long, env = "BOOTC_log_root", default_value = DEFAULT_LOG_ROOT)]
    log_root: Utf8PathBuf,
    /// GNU timeout duration for the command.
    #[arg(long, default_value = "2h")]
    timeout: String,
    /// Grace period supplied to GNU timeout before it sends SIGKILL.
    #[arg(long, default_value = "30s")]
    kill_after: String,
    /// Command and arguments to run. Use `--` before the command.
    #[arg(required = true, trailing_var_arg = true)]
    command: Vec<String>,
}

#[derive(Serialize)]
struct RunResult<'a> {
    argv: Vec<String>,
    workdir: String,
    exit_code: i32,
    signal: Option<i32>,
    timed_out: bool,
    timeout: &'a str,
    kill_after: &'a str,
    duration_ms: u128,
    log_path: &'a str,
    timeout_log_path: &'a str,
    tmt_log_dir: &'a str,
}

pub(crate) fn run_logged(args: &RunLoggedArgs) -> Result<()> {
    let outcome = run_logged_inner(args)?;
    if outcome.exit_code != 0 {
        std::process::exit(outcome.exit_code);
    }
    Ok(())
}

struct Outcome {
    exit_code: i32,
}

fn run_logged_inner(args: &RunLoggedArgs) -> Result<Outcome> {
    let run_dir = create_run_dir(&args.log_root)?;
    let log_path = run_dir.join("output.log");
    let timeout_log_path = run_dir.join("timeout.log");
    let tmt_log_dir = run_dir.join("tmt");
    create_private_dir(&tmt_log_dir)?;
    let log_path_string = log_path.to_string();
    let timeout_log_path_string = timeout_log_path.to_string();
    let tmt_log_dir_string = tmt_log_dir.to_string();
    let started = std::time::Instant::now();
    println!("START: log={log_path_string}");

    let log = private_file(&log_path)?;
    let timeout_log = private_file(&timeout_log_path)?;
    // GNU timeout owns timeout and signal delivery.  The shell redirects only
    // child stderr to stdout, leaving timeout's own diagnostics private.
    let status = Command::new("timeout")
        .args(["--verbose", &format!("--kill-after={}", args.kill_after)])
        .arg(&args.timeout)
        .args(["/bin/sh", "-c", "exec \"$@\" 2>&1", "bootc-runner"])
        .args(&args.command)
        .env("TMT_LOG_DIR", &tmt_log_dir)
        .env("BOOTC_RUN_LOG_DIR", &run_dir)
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(timeout_log))
        .status()
        .with_context(|| format!("Starting GNU timeout for {}", args.command[0]))?;
    let timeout_reported = fs::metadata(&timeout_log_path)
        .context("Reading timeout diagnostic metadata")?
        .len()
        != 0;
    let (exit_code, signal) = status_details(&status);
    let timed_out = timeout_reported && matches!(exit_code, 124 | 137);
    let duration = started.elapsed();
    let record = RunResult {
        argv: sanitized_argv(&args.command),
        workdir: std::env::current_dir()
            .context("Reading working directory")?
            .display()
            .to_string(),
        exit_code,
        signal,
        timed_out,
        timeout: &args.timeout,
        kill_after: &args.kill_after,
        duration_ms: duration.as_millis(),
        log_path: &log_path_string,
        timeout_log_path: &timeout_log_path_string,
        tmt_log_dir: &tmt_log_dir_string,
    };
    write_private(
        &run_dir.join("result.json"),
        serde_json::to_vec_pretty(&record)?,
    )?;

    if exit_code == 0 {
        println!(
            "PASS: exit=0 time={} log={log_path_string}",
            display_duration(duration)
        );
    } else {
        let kind = if timed_out { "TIMEOUT" } else { "FAIL" };
        eprintln!(
            "{kind}: exit={exit_code} time={} log={log_path_string}",
            display_duration(duration)
        );
        let excerpt = tail_window(&log_path, FAILURE_EXCERPT_BYTES, FAILURE_EXCERPT_LINES)?;
        if !excerpt.is_empty() {
            eprintln!("--- final log excerpt ---\n{excerpt}");
        }
    }
    Ok(Outcome { exit_code })
}

fn private_file(path: &camino::Utf8Path) -> Result<File> {
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(path)
        .with_context(|| format!("Creating private log {path}"))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(file)
}

fn write_private(path: &camino::Utf8Path, data: Vec<u8>) -> Result<()> {
    let mut file = private_file(path)?;
    file.write_all(&data)
        .with_context(|| format!("Writing private result {path}"))
}

fn create_run_dir(root: &Utf8PathBuf) -> Result<Utf8PathBuf> {
    fs::create_dir_all(root).with_context(|| format!("Creating log root {root}"))?;
    let millis = SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis();
    for sequence in 0..1000 {
        let candidate = root.join(format!("run-{millis}-{}-{sequence}", std::process::id()));
        let mut builder = fs::DirBuilder::new();
        builder.mode(0o700);
        match builder.create(&candidate) {
            Ok(()) => return Ok(candidate),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e).context("Creating unique run directory"),
        }
    }
    anyhow::bail!("Could not allocate a unique run directory under {root}")
}

fn create_private_dir(path: &camino::Utf8Path) -> Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.mode(0o700);
    builder
        .create(path)
        .with_context(|| format!("Creating private directory {path}"))
}

fn tail_window(path: &camino::Utf8Path, limit: u64, lines: usize) -> Result<String> {
    let mut file = File::open(path).with_context(|| format!("Opening run log {path}"))?;
    let len = file.metadata()?.len();
    file.seek(SeekFrom::Start(len.saturating_sub(limit)))?;
    let mut bytes = Vec::with_capacity(limit.min(len) as usize);
    file.take(limit).read_to_end(&mut bytes)?;
    let text = String::from_utf8_lossy(&bytes);
    let mut tail: Vec<_> = text.lines().rev().take(lines).collect();
    tail.reverse();
    let rendered = tail.join("\n");
    // Lossy conversion can expand an invalid byte into the three-byte U+FFFD.
    // Clamp the rendered text too, retaining its diagnostic tail on a UTF-8
    // character boundary.
    if rendered.len() <= limit as usize {
        return Ok(rendered);
    }
    let mut start = rendered.len() - limit as usize;
    while !rendered.is_char_boundary(start) {
        start += 1;
    }
    Ok(rendered[start..].to_owned())
}

fn sanitized_argv(argv: &[String]) -> Vec<String> {
    let mut result = Vec::with_capacity(argv.len());
    let mut redact_next = false;
    for arg in argv {
        if redact_next {
            result.push("<redacted>".to_owned());
            redact_next = false;
            continue;
        }
        let upper = arg.to_ascii_uppercase();
        let secret = ["TOKEN=", "PASSWORD=", "SECRET=", "PRIVATE_KEY="]
            .iter()
            .any(|marker| upper.contains(marker));
        let secret_flag = upper == "--TOKEN"
            || upper == "--PASSWORD"
            || upper == "--SECRET"
            || upper == "--PRIVATE-KEY";
        result.push(if secret {
            "<redacted>".to_owned()
        } else {
            arg.clone()
        });
        redact_next = secret_flag;
    }
    result
}

fn status_details(status: &ExitStatus) -> (i32, Option<i32>) {
    use std::os::unix::process::ExitStatusExt;

    match (status.code(), status.signal()) {
        (Some(code), _) => (code, None),
        (None, Some(signal)) => (128 + signal, Some(signal)),
        (None, None) => (1, None),
    }
}

fn display_duration(duration: Duration) -> String {
    format!("{}.{:03}s", duration.as_secs(), duration.subsec_millis())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(root: Utf8PathBuf, timeout: &str, command: &[&str]) -> RunLoggedArgs {
        RunLoggedArgs {
            log_root: root,
            timeout: timeout.into(),
            kill_after: "1s".into(),
            command: command.iter().map(|s| (*s).into()).collect(),
        }
    }

    #[test]
    fn records_status_timeout_and_private_unique_logs() {
        let temp = tempfile::tempdir().unwrap();
        let root = Utf8PathBuf::from_path_buf(temp.path().join("logs with spaces")).unwrap();
        assert_eq!(
            run_logged_inner(&args(
                root.clone(),
                "1s",
                &["sh", "-c", "test -d \"$BOOTC_RUN_LOG_DIR\"; exit 124"],
            ))
            .unwrap()
            .exit_code,
            124
        );
        assert_eq!(
            run_logged_inner(&args(root.clone(), "1s", &["sh", "-c", "exit 143"]))
                .unwrap()
                .exit_code,
            143
        );
        assert_eq!(
            run_logged_inner(&args(root.clone(), "1s", &["sh", "-c", "kill -TERM $$"]))
                .unwrap()
                .exit_code,
            143
        );
        assert_eq!(
            run_logged_inner(&args(root.clone(), "1s", &["sh", "-c", "sleep 2"]))
                .unwrap()
                .exit_code,
            124
        );
        let runs: Vec<_> = fs::read_dir(&root)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect();
        assert_eq!(runs.len(), 4);
        let results: Vec<serde_json::Value> = runs
            .iter()
            .map(|run| serde_json::from_slice(&fs::read(run.join("result.json")).unwrap()).unwrap())
            .collect();
        assert!(results.iter().any(|result| result["exit_code"] == 124 && !result["timed_out"].as_bool().unwrap()));
        assert!(
            results
                .iter()
                .any(|result| result["timed_out"].as_bool().unwrap())
        );
        assert!(
            results
                .iter()
                .any(|result| result["exit_code"] == 143 && result["signal"].is_null())
        );
        assert!(
            results
                .iter()
                .any(|result| result["exit_code"] == 143 && result["signal"] == 15)
        );
        for run in runs {
            assert_eq!(
                fs::metadata(&run).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(run.join("output.log"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
            assert_eq!(
                fs::metadata(run.join("result.json"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
            assert_eq!(
                fs::metadata(run.join("tmt")).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
    }

    #[test]
    fn bounds_failure_excerpt_and_redacts_flag_values() {
        let temp = tempfile::tempdir().unwrap();
        let path = Utf8PathBuf::from_path_buf(temp.path().join("large.log")).unwrap();
        fs::write(&path, "x\n".repeat(10_000)).unwrap();
        let excerpt = tail_window(&path, FAILURE_EXCERPT_BYTES, FAILURE_EXCERPT_LINES).unwrap();
        assert!(excerpt.len() <= FAILURE_EXCERPT_BYTES as usize);
        assert!(excerpt.lines().count() <= FAILURE_EXCERPT_LINES);
        assert_eq!(
            sanitized_argv(&["--password".into(), "value".into(), "safe".into()]),
            ["--password", "<redacted>", "safe"]
        );
    }

    #[test]
    fn bounds_lossy_and_multibyte_failure_excerpts() {
        let temp = tempfile::tempdir().unwrap();
        let path = Utf8PathBuf::from_path_buf(temp.path().join("invalid.log")).unwrap();
        let mut bytes = vec![0xff; FAILURE_EXCERPT_BYTES as usize];
        bytes.push(b'\n');
        bytes.extend(
            std::iter::repeat_n(b"x\n".as_slice(), FAILURE_EXCERPT_LINES - 3)
                .flatten()
                .copied(),
        );
        bytes.extend_from_slice("🦀\nLAST-DIAGNOSTIC".as_bytes());
        fs::write(&path, bytes).unwrap();
        let excerpt = tail_window(&path, FAILURE_EXCERPT_BYTES, FAILURE_EXCERPT_LINES).unwrap();
        assert!(excerpt.len() <= FAILURE_EXCERPT_BYTES as usize);
        assert!(excerpt.lines().count() <= FAILURE_EXCERPT_LINES);
        assert!(excerpt.ends_with("LAST-DIAGNOSTIC"));

        let boundary_path = Utf8PathBuf::from_path_buf(temp.path().join("boundary.log")).unwrap();
        let mut boundary = vec![b'x'; 3];
        boundary.extend(
            std::iter::repeat_n("🦀".as_bytes(), FAILURE_EXCERPT_BYTES as usize / 4 + 2)
                .flatten()
                .copied(),
        );
        boundary.extend_from_slice(b"\nLAST-DIAGNOSTIC");
        fs::write(&boundary_path, boundary).unwrap();
        let excerpt =
            tail_window(&boundary_path, FAILURE_EXCERPT_BYTES, FAILURE_EXCERPT_LINES).unwrap();
        assert!(excerpt.len() <= FAILURE_EXCERPT_BYTES as usize);
        assert!(excerpt.ends_with("LAST-DIAGNOSTIC"));
    }

    #[test]
    fn refuses_invalid_complete_named_secure_boot_keys_without_replacing_them() {
        let temp = tempfile::tempdir().unwrap();
        let keys = temp.path().join("keys");
        std::fs::create_dir(&keys).unwrap();
        for name in [
            "GUID.txt", "PK.key", "PK.crt", "PK.cer", "KEK.key", "KEK.crt", "KEK.cer", "db.key",
            "db.crt", "db.cer", ".done",
        ] {
            std::fs::write(keys.join(name), "invalid key fixture").unwrap();
        }
        let original = std::fs::read(keys.join("db.key")).unwrap();
        let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../hack/generate-secureboot-keys");
        let status = Command::new(script)
            .env("BOOTC_SECUREBOOT_DIR", &keys)
            .status()
            .unwrap();
        assert!(!status.success());
        assert_eq!(std::fs::read(keys.join("db.key")).unwrap(), original);
    }
}
