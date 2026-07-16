use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::process::Command;

use crate::archive::{self, ArchiveError};
use crate::config::{Args, SupervisorConfig, submission_language};
use crate::process::{ProcessGroup, RunOutcome, SignalMonitor, enable_subreaper};
use crate::result::{self, Snapshot};

/// A supervisor failure with its required process exit behavior.
pub enum SupervisorError {
  /// An external signal ended supervision.
  Signal(i32),
  /// An ordinary runtime failure.
  Failure(io::Error),
}

impl fmt::Display for SupervisorError {
  fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
    match self {
      Self::Signal(signal) => write!(formatter, "signal {signal}"),
      Self::Failure(error) => error.fmt(formatter),
    }
  }
}

impl SupervisorError {
  /// Returns the process exit code required for this failure.
  pub fn exit_code(&self) -> i32 {
    match self {
      Self::Signal(signal) => 128 + signal,
      Self::Failure(_) => 1,
    }
  }
}

impl From<io::Error> for SupervisorError {
  fn from(error: io::Error) -> Self {
    Self::Failure(error)
  }
}

/// Orchestrates one UOJ judging request.
pub struct Supervisor {
  args: Args,
  signals: SignalMonitor,
}

impl Supervisor {
  /// Creates a supervisor for parsed UOJ paths.
  pub fn new(args: Args, signals: SignalMonitor) -> Self {
    Self { args, signals }
  }

  /// Runs extraction, judging, progress mirroring, and result publication.
  pub fn run(self) -> Result<(), SupervisorError> {
    self.run_monitored()
  }

  fn run_monitored(&self) -> Result<(), SupervisorError> {
    self.check_signal()?;
    enable_subreaper()?;
    fs::create_dir_all(&self.args.work)?;
    let _lock = lock(&self.args.work)?;
    let mut result = self.run_request();
    if matches!(result, Err(SupervisorError::Failure(_)))
      && let Some(signal) = self.signals.pending()?
    {
      let inner = self.args.work.join("hull-uoj-result");
      let _ = result::cleanup(&inner, &self.args.result, &self.args.work);
      result = Err(SupervisorError::Signal(signal));
    }
    match result {
      Err(SupervisorError::Failure(error)) => {
        let inner = self.args.work.join("hull-uoj-result");
        let publication = (|| {
          fs::create_dir_all(&self.args.result)?;
          let message = match result::cleanup(&inner, &self.args.result, &self.args.work) {
            Ok(()) => error.to_string(),
            Err(cleanup) => format!("{error}; cleanup failed: {cleanup}"),
          };
          result::judgment_failed(&self.args.result, &message)
        })();
        finish_failure(
          &self.signals,
          &inner,
          &self.args.result,
          &self.args.work,
          error,
          publication,
        )
      }
      result => result,
    }
  }

  fn run_request(&self) -> Result<(), SupervisorError> {
    fs::create_dir_all(&self.args.result)?;
    let bundle = self.args.data.join("hull-bundle");
    let inner = self.args.work.join("hull-uoj-result");
    fs::create_dir_all(&inner)?;
    result::cleanup(&inner, &self.args.result, &self.args.work)?;
    self.check_signal()?;
    let config = SupervisorConfig::read(&bundle.join("supervisor.conf"))?;
    let chroot = match archive::prepare(&self.args.data, &self.args.work, &config, &self.signals) {
      Ok(path) => path,
      Err(ArchiveError::Signal(signal)) => {
        let _ = result::cleanup(&inner, &self.args.result, &self.args.work);
        return Err(SupervisorError::Signal(signal));
      }
      Err(ArchiveError::Failure(error)) => return Err(error.into()),
    };
    self.check_signal()?;
    let language = submission_language(&self.args.work.join("submission.conf"))?;
    let cache = self.args.work.join("hull-cache");
    fs::create_dir_all(&cache)?;
    let mut command = Command::new(chroot);
    command
      .arg("-m")
      .arg(format!("{}:work", self.args.work.display()))
      .arg("-m")
      .arg(format!("{}:data", self.args.data.display()))
      .arg("-p")
      .arg("XDG_CACHE_HOME")
      .arg("-p")
      .arg("HOME")
      .arg("-n")
      .arg(self.args.work.join("hull-nix"))
      .arg("--")
      .arg(&config.runner)
      .arg("/data/hull-bundle")
      .arg("/work/answer.code")
      .arg(language)
      .arg("/work")
      .arg("/work/hull-uoj-result")
      .arg("/data")
      .env("XDG_CACHE_HOME", &cache)
      .env("HOME", &self.args.work);
    let mut group = ProcessGroup::spawn(&mut command)?;
    let mut completed: Option<Snapshot> = None;
    let outcome = group.poll(&self.signals, || {
      if let Some(snapshot) = result::snapshot(&inner)? {
        completed = Some(snapshot);
        return Ok(true);
      }
      result::mirror_progress(&inner, &self.args.result)?;
      Ok(false)
    });

    match outcome {
      Ok(RunOutcome::Complete) => {
        group.terminate()?;
        completed
          .ok_or_else(|| io::Error::other("completion marker disappeared"))?
          .publish(&self.args.result, &self.args.work)?;
        Ok(())
      }
      Ok(RunOutcome::Signal(signal)) => {
        let _ = group.terminate();
        let _ = result::cleanup(&inner, &self.args.result, &self.args.work);
        Err(SupervisorError::Signal(signal))
      }
      Ok(RunOutcome::Exited(status)) => {
        group.terminate()?;
        let error = io::Error::other(format!("judge exited before committing result: {status}"));
        Err(error.into())
      }
      Err(error) => {
        let cleanup_error = group.terminate().err();
        let message = cleanup_error
          .map(|cleanup| format!("{error}; cleanup failed: {cleanup}"))
          .unwrap_or_else(|| error.to_string());
        Err(io::Error::other(message).into())
      }
    }
  }

  fn check_signal(&self) -> Result<(), SupervisorError> {
    match self.signals.pending()? {
      Some(signal) => Err(SupervisorError::Signal(signal)),
      None => Ok(()),
    }
  }
}

fn finish_failure(
  signals: &SignalMonitor,
  inner: &std::path::Path,
  outer: &std::path::Path,
  work: &std::path::Path,
  error: io::Error,
  publication: io::Result<()>,
) -> Result<(), SupervisorError> {
  if let Some(signal) = signals.pending()? {
    let _ = result::cleanup(inner, outer, work);
    return Err(SupervisorError::Signal(signal));
  }
  publication?;
  Err(SupervisorError::Failure(error))
}

fn lock(work: &std::path::Path) -> io::Result<File> {
  let file = OpenOptions::new()
    .read(true)
    .write(true)
    .create(true)
    .truncate(false)
    .open(work.join(".hull-uoj-supervisor.lock"))?;
  if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == -1 {
    return Err(io::Error::last_os_error());
  }
  Ok(file)
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::os::unix::fs::PermissionsExt;
  use std::path::PathBuf;
  use std::sync::atomic::{AtomicU64, Ordering};
  use std::sync::mpsc;
  use std::time::{Duration, Instant};

  static NEXT: AtomicU64 = AtomicU64::new(0);

  fn temp() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
      "hull-uoj-supervisor-{}-{}",
      std::process::id(),
      NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&path).unwrap();
    path
  }

  fn script(path: &std::path::Path, body: &str) {
    fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
  }

  fn args(root: &std::path::Path) -> Args {
    Args {
      work: root.join("work"),
      result: root.join("result"),
      data: root.join("data"),
    }
  }

  fn signal_when(
    path: PathBuf,
    thread: libc::pthread_t,
  ) -> std::thread::JoinHandle<Result<(), String>> {
    std::thread::spawn(move || {
      let deadline = Instant::now() + Duration::from_secs(2);
      while !path.exists() {
        if Instant::now() >= deadline {
          return Err(format!(
            "readiness file {} did not appear before deadline",
            path.display()
          ));
        }
        std::thread::sleep(Duration::from_millis(10));
      }
      let result = unsafe { libc::pthread_kill(thread, libc::SIGTERM) };
      if result != 0 {
        return Err(format!("pthread_kill(SIGTERM) failed with error {result}"));
      }
      Ok(())
    })
  }

  #[test]
  fn lock_conflict() {
    let dir = temp();
    let first = lock(&dir).unwrap();
    assert!(lock(&dir).is_err());
    assert_eq!(unsafe { libc::flock(first.as_raw_fd(), libc::LOCK_UN) }, 0);
    drop(first);
    assert!(lock(&dir).is_ok());
    fs::remove_dir_all(dir).unwrap();
  }

  #[test]
  fn conflict_preserves_results() {
    let root = temp();
    let args = args(&root);
    let inner = args.work.join("hull-uoj-result");
    for path in [&args.work, &args.result, &inner] {
      fs::create_dir_all(path).unwrap();
    }
    let files = [
      (
        inner.join(".hull-uoj-complete"),
        b"active-marker".as_slice(),
      ),
      (inner.join("result.txt"), b"active-inner-result".as_slice()),
      (
        inner.join("cur_status.txt"),
        b"active-inner-status".as_slice(),
      ),
      (
        args.result.join("result.txt"),
        b"active-outer-result".as_slice(),
      ),
      (
        args.result.join("cur_status.txt"),
        b"active-outer-progress".as_slice(),
      ),
      (
        args.result.join("std_output.txt"),
        b"active-outer-stdout".as_slice(),
      ),
      (
        args.work.join("std_output.txt"),
        b"active-work-stdout".as_slice(),
      ),
    ];
    for (path, bytes) in &files {
      fs::write(path, bytes).unwrap();
    }
    let held = lock(&args.work).unwrap();
    let (sender, receiver) = mpsc::channel();
    let worker = std::thread::spawn(move || {
      let signals = SignalMonitor::new().unwrap();
      sender
        .send(Supervisor::new(args, signals).run_monitored())
        .unwrap();
    });
    let result = match receiver.recv_timeout(Duration::from_secs(1)) {
      Ok(result) => result,
      Err(error) => {
        drop(held);
        worker.join().unwrap();
        panic!("lock conflict did not return before deadline: {error}");
      }
    };
    worker.join().unwrap();
    assert!(matches!(result, Err(SupervisorError::Failure(_))));
    for (path, bytes) in &files {
      assert_eq!(
        fs::read(path).unwrap(),
        *bytes,
        "{} changed",
        path.display()
      );
    }
    drop(held);
    fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn cleanup() {
    let root = temp();
    let inner = root.join("inner");
    let outer = root.join("outer");
    let work = root.join("work");
    for path in [&inner, &outer, &work] {
      fs::create_dir(path).unwrap();
    }
    fs::write(outer.join("result.txt"), "old").unwrap();
    fs::write(outer.join("cur_status.txt"), "old").unwrap();
    fs::write(work.join("std_output.txt"), "old").unwrap();
    result::cleanup(&inner, &outer, &work).unwrap();
    assert!(!outer.join("result.txt").exists());
    assert!(!outer.join("cur_status.txt").exists());
    assert!(!work.join("std_output.txt").exists());
    fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn failure_signal() {
    let root = temp();
    let inner = root.join("inner");
    let outer = root.join("outer");
    let work = root.join("work");
    for path in [&inner, &outer, &work] {
      fs::create_dir(path).unwrap();
    }
    result::judgment_failed(&outer, "failed").unwrap();
    let signals = SignalMonitor::new().unwrap();
    assert_eq!(
      unsafe { libc::pthread_kill(libc::pthread_self(), libc::SIGTERM) },
      0
    );
    let outcome = finish_failure(
      &signals,
      &inner,
      &outer,
      &work,
      io::Error::other("failed"),
      Err(io::Error::other("publication failed")),
    );
    let pending = signals.pending().unwrap();
    assert!(matches!(
      outcome,
      Err(SupervisorError::Signal(libc::SIGTERM))
    ));
    assert!(pending.is_none());
    assert!(!outer.join("result.txt").exists());
    assert!(!outer.join("cur_status.txt").exists());
    fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn archive_signal_survives_cleanup_failure() {
    let root = temp();
    let args = args(&root);
    let bundle = args.data.join("hull-bundle");
    for path in [&args.work, &args.result, &args.data, &bundle] {
      fs::create_dir_all(path).unwrap();
    }
    fs::write(
      bundle.join("supervisor.conf"),
      "nix_user_chroot_store_suffix=/abc/bin/nix-user-chroot\nrunner=/runner\nruntime_id=one\n",
    )
    .unwrap();
    fs::write(bundle.join("nix-store.tar.zst"), "payload").unwrap();
    script(
      &args.data.join("zstd"),
      &format!("mkdir '{}'/result.txt; sleep 1", args.result.display()),
    );
    script(&args.data.join("busybox"), "cat >/dev/null");

    let signals = SignalMonitor::new().unwrap();
    let sender = signal_when(args.result.join("result.txt"), unsafe {
      libc::pthread_self()
    });
    let supervisor = Supervisor::new(args, signals);
    let result = supervisor.run_monitored();
    sender
      .join()
      .expect("signal sender panicked")
      .expect("signal sender failed");
    let pending = supervisor.signals.pending().unwrap();
    let error = result.unwrap_err();
    assert!(matches!(error, SupervisorError::Signal(libc::SIGTERM)));
    assert!(pending.is_none());
    assert!(!root.join("result/cur_status.txt").exists());
    fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn judge_signal_survives_cleanup_failure() {
    let root = temp();
    let args = args(&root);
    let bundle = args.data.join("hull-bundle");
    let chroot = args.work.join("hull-nix/store/abc/bin/nix-user-chroot");
    for path in [
      &args.work,
      &args.result,
      &args.data,
      &bundle,
      chroot.parent().unwrap(),
    ] {
      fs::create_dir_all(path).unwrap();
    }
    fs::write(
      bundle.join("supervisor.conf"),
      "nix_user_chroot_store_suffix=/abc/bin/nix-user-chroot\nrunner=/runner\nruntime_id=one\n",
    )
    .unwrap();
    fs::write(args.work.join("hull-nix/.hull-uoj-ready"), "one").unwrap();
    fs::write(args.work.join("submission.conf"), "answer_language C++20\n").unwrap();
    script(
      &chroot,
      &format!("mkdir '{}'/result.txt; sleep 1", args.result.display()),
    );

    let signals = SignalMonitor::new().unwrap();
    let sender = signal_when(args.result.join("result.txt"), unsafe {
      libc::pthread_self()
    });
    let supervisor = Supervisor::new(args, signals);
    let result = supervisor.run_monitored();
    sender
      .join()
      .expect("signal sender panicked")
      .expect("signal sender failed");
    let pending = supervisor.signals.pending().unwrap();
    let error = result.unwrap_err();
    assert!(matches!(error, SupervisorError::Signal(libc::SIGTERM)));
    assert!(pending.is_none());
    assert!(!root.join("result/cur_status.txt").exists());
    fs::remove_dir_all(root).unwrap();
  }
}
