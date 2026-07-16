use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::config::SupervisorConfig;
use crate::process::{ProcessGroup, SignalMonitor};

const READY: &str = ".hull-uoj-ready";
const EXTRACT_DEADLINE: Duration = Duration::from_secs(600);

/// Archive preparation failure.
#[derive(Debug)]
pub enum ArchiveError {
  /// An external termination signal interrupted extraction.
  Signal(i32),
  /// Extraction or filesystem work failed.
  Failure(io::Error),
}

impl From<io::Error> for ArchiveError {
  fn from(error: io::Error) -> Self {
    Self::Failure(error)
  }
}

/// Reuses or extracts the runtime cache and returns nix-user-chroot's host path.
pub fn prepare(
  package: &Path,
  work: &Path,
  config: &SupervisorConfig,
  signals: &SignalMonitor,
) -> Result<PathBuf, ArchiveError> {
  let cache = work.join("hull-nix");
  let chroot = cache.join("store").join(
    config
      .nix_user_chroot_store_suffix
      .strip_prefix("/")
      .unwrap_or(&config.nix_user_chroot_store_suffix),
  );
  if fs::read_to_string(cache.join(READY)).ok().as_deref() == Some(config.runtime_id.as_str()) {
    return Ok(chroot);
  }
  let staging = work.join(format!("hull-nix.staging-{}", std::process::id()));
  if staging.exists() {
    fs::remove_dir_all(&staging)?;
  }
  fs::create_dir(&staging)?;

  let prepared = (|| {
    extract(package, &staging, signals)?;
    let mut ready = File::create(staging.join(READY))?;
    ready.write_all(config.runtime_id.as_bytes())?;
    ready.sync_all()?;
    File::open(&staging)?.sync_all()?;
    if cache.exists() {
      fs::remove_dir_all(&cache)?;
    }
    fs::rename(&staging, &cache)?;
    File::open(work)?.sync_all()?;
    Ok::<(), ArchiveError>(())
  })();
  if let Err(error) = prepared {
    let _ = fs::remove_dir_all(&staging);
    return Err(error);
  }
  Ok(chroot)
}

fn extract(package: &Path, staging: &Path, signals: &SignalMonitor) -> Result<(), ArchiveError> {
  let mut decoder = Command::new(package.join("zstd"));
  decoder
    .arg("-dc")
    .arg(package.join("hull-bundle/nix-store.tar.zst"))
    .stdout(Stdio::piped());
  let mut group = ProcessGroup::spawn(&mut decoder)?;
  let output = group
    .take_stdout(0)
    .ok_or_else(|| io::Error::other("zstd stdout was not piped"))?;
  let mut unpack = Command::new(package.join("busybox"));
  unpack
    .arg("tar")
    .arg("-C")
    .arg(staging)
    .arg("-xf")
    .arg("-")
    .stdin(Stdio::from(output));
  let unpack_index = match group.spawn_member(&mut unpack) {
    Ok(index) => index,
    Err(error) => {
      let _ = group.terminate();
      return Err(error.into());
    }
  };

  let deadline = Instant::now() + EXTRACT_DEADLINE;
  let outcome = loop {
    match signals.pending() {
      Ok(Some(signal)) => break Err(ArchiveError::Signal(signal)),
      Ok(None) => {}
      Err(error) => break Err(error.into()),
    }
    let decoder_status = match group.status(0) {
      Ok(status) => status,
      Err(error) => break Err(error.into()),
    };
    let unpack_status = match group.status(unpack_index) {
      Ok(status) => status,
      Err(error) => break Err(error.into()),
    };
    if let (Some(decoder_status), Some(unpack_status)) = (decoder_status, unpack_status) {
      if decoder_status.success() && unpack_status.success() {
        break Ok(());
      }
      break Err(
        io::Error::other(format!(
          "extractor failed: zstd={decoder_status}, tar={unpack_status}"
        ))
        .into(),
      );
    }
    if Instant::now() >= deadline {
      break Err(io::Error::new(io::ErrorKind::TimedOut, "extractor did not exit").into());
    }
    thread::sleep(Duration::from_millis(50));
  };
  let cleanup = group.terminate();

  match outcome {
    Err(ArchiveError::Signal(signal)) => Err(ArchiveError::Signal(signal)),
    Err(error) => {
      cleanup?;
      Err(error)
    }
    Ok(()) => {
      cleanup?;
      Ok(())
    }
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::os::unix::fs::PermissionsExt;
  use std::sync::atomic::{AtomicU64, Ordering};

  static NEXT: AtomicU64 = AtomicU64::new(0);

  fn temp() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
      "hull-uoj-archive-{}-{}",
      std::process::id(),
      NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&path).unwrap();
    path
  }

  fn script(path: &Path, body: &str) {
    fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
  }

  #[test]
  fn stream() {
    let root = temp();
    let package = root.join("package");
    let staging = root.join("staging");
    fs::create_dir(&package).unwrap();
    fs::create_dir(package.join("hull-bundle")).unwrap();
    fs::create_dir(&staging).unwrap();
    fs::write(package.join("hull-bundle/nix-store.tar.zst"), "payload").unwrap();
    script(&package.join("zstd"), "cat \"$2\"");
    script(&package.join("busybox"), "cat > \"$3/extracted\"");
    let signals = SignalMonitor::new().unwrap();
    extract(&package, &staging, &signals).unwrap();
    assert_eq!(fs::read(staging.join("extracted")).unwrap(), b"payload");
    fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn zstd_failure() {
    let root = temp();
    let package = root.join("package");
    let staging = root.join("staging");
    fs::create_dir(&package).unwrap();
    fs::create_dir(package.join("hull-bundle")).unwrap();
    fs::create_dir(&staging).unwrap();
    fs::write(package.join("hull-bundle/nix-store.tar.zst"), "payload").unwrap();
    script(&package.join("zstd"), "exit 7");
    script(&package.join("busybox"), "cat >/dev/null");
    let signals = SignalMonitor::new().unwrap();
    assert!(extract(&package, &staging, &signals).is_err());
    fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn tar_failure() {
    let root = temp();
    let package = root.join("package");
    let staging = root.join("staging");
    fs::create_dir(&package).unwrap();
    fs::create_dir(package.join("hull-bundle")).unwrap();
    fs::create_dir(&staging).unwrap();
    fs::write(package.join("hull-bundle/nix-store.tar.zst"), "payload").unwrap();
    script(&package.join("zstd"), "cat \"$2\"");
    script(&package.join("busybox"), "cat >/dev/null; exit 9");
    let signals = SignalMonitor::new().unwrap();
    assert!(extract(&package, &staging, &signals).is_err());
    fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn cache_hit() {
    let root = temp();
    let package = root.join("package");
    let work = root.join("work");
    let cache = work.join("hull-nix");
    fs::create_dir(&package).unwrap();
    fs::create_dir(&work).unwrap();
    fs::create_dir(&cache).unwrap();
    fs::write(cache.join(READY), "closure-1").unwrap();
    let config = SupervisorConfig {
      nix_user_chroot_store_suffix: "/abc/bin/nix-user-chroot".into(),
      runner: "/nix/store/runner/bin/run".into(),
      runtime_id: "closure-1".to_string(),
    };
    let signals = SignalMonitor::new().unwrap();
    assert_eq!(
      prepare(&package, &work, &config, &signals).unwrap(),
      cache.join("store/abc/bin/nix-user-chroot")
    );
    fs::remove_dir_all(root).unwrap();
  }
}
