use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static TEMP_ID: AtomicU64 = AtomicU64::new(0);

/// Atomically writes bytes to a fixed destination and syncs its directory.
pub fn atomic_write(path: &Path, content: &[u8]) -> io::Result<()> {
  let temp = temp_path(path)?;
  let result = (|| {
    let mut file = OpenOptions::new()
      .write(true)
      .create_new(true)
      .open(&temp)?;
    file.write_all(content)?;
    file.sync_all()?;
    fs::rename(&temp, path)?;
    sync_parent(path)
  })();
  if result.is_err() {
    let _ = fs::remove_file(&temp);
  }
  result
}

/// Atomically copies an open file to a fixed destination.
pub fn atomic_copy(source: &mut File, path: &Path) -> io::Result<()> {
  let temp = temp_path(path)?;
  let result = (|| {
    let mut output = OpenOptions::new()
      .write(true)
      .create_new(true)
      .open(&temp)?;
    io::copy(source, &mut output)?;
    output.sync_all()?;
    fs::rename(&temp, path)?;
    sync_parent(path)
  })();
  if result.is_err() {
    let _ = fs::remove_file(&temp);
  }
  result
}

/// Removes a fixed file if it exists and syncs its directory.
pub fn remove_if_exists(path: &Path) -> io::Result<()> {
  match fs::remove_file(path) {
    Ok(()) => sync_parent(path),
    Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
    Err(error) => Err(error),
  }
}

fn temp_path(path: &Path) -> io::Result<PathBuf> {
  let parent = path
    .parent()
    .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "destination has no parent"))?;
  let name = path
    .file_name()
    .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "destination has no file name"))?;
  Ok(parent.join(format!(
    ".{}.tmp-{}-{}",
    name.to_string_lossy(),
    std::process::id(),
    TEMP_ID.fetch_add(1, Ordering::Relaxed)
  )))
}

fn sync_parent(path: &Path) -> io::Result<()> {
  File::open(path.parent().unwrap_or_else(|| Path::new(".")))?.sync_all()
}

#[cfg(test)]
mod tests {
  use super::*;

  fn temp() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
      "hull-uoj-files-{}-{}",
      std::process::id(),
      TEMP_ID.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&path).unwrap();
    path
  }

  #[test]
  fn write() {
    let dir = temp();
    let path = dir.join("value");
    atomic_write(&path, b"first").unwrap();
    atomic_write(&path, b"second").unwrap();
    assert_eq!(fs::read(path).unwrap(), b"second");
    fs::remove_dir_all(dir).unwrap();
  }

  #[test]
  fn copy() {
    let dir = temp();
    let source = dir.join("source");
    let target = dir.join("target");
    fs::write(&source, "copied").unwrap();
    let mut source = File::open(source).unwrap();
    atomic_copy(&mut source, &target).unwrap();
    assert_eq!(fs::read(target).unwrap(), b"copied");
    fs::remove_dir_all(dir).unwrap();
  }
}
