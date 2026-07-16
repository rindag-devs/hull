/*
  This file is part of Hull.

  Hull is free software: you can redistribute it and/or modify it under the terms of the GNU
  Lesser General Public License as published by the Free Software Foundation, either version 3 of
  the License, or (at your option) any later version.

  Hull is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
  General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License along with Hull. If
  not, see <https://www.gnu.org/licenses/>.
*/

use std::fs::{self, File};
use std::io::{self, Seek};
use std::path::Path;

use crate::files::{atomic_copy, atomic_write, remove_if_exists};

const MARKER: &str = ".hull-uoj-complete";
const MARKER_BYTES: &[u8] = b"hull-uoj-result\n";

/// Open files belonging to one complete inner result publication.
#[derive(Debug)]
pub struct Snapshot {
  result: File,
  status: File,
  stdout: Option<File>,
}

impl Snapshot {
  /// Publishes stdout, result, and finally the durable terminal status.
  pub fn publish(mut self, outer: &Path, work: &Path) -> io::Result<()> {
    if let Some(mut stdout) = self.stdout {
      atomic_copy(&mut stdout, &outer.join("std_output.txt"))?;
      stdout.rewind()?;
      atomic_copy(&mut stdout, &work.join("std_output.txt"))?;
    } else {
      remove_if_exists(&outer.join("std_output.txt"))?;
      remove_if_exists(&work.join("std_output.txt"))?;
    }
    atomic_copy(&mut self.result, &outer.join("result.txt"))?;
    atomic_copy(&mut self.status, &outer.join("cur_status.txt"))
  }
}

/// Opens a complete fixed result set after validating its commit marker.
pub fn snapshot(inner: &Path) -> io::Result<Option<Snapshot>> {
  let marker = match fs::read(inner.join(MARKER)) {
    Ok(marker) => marker,
    Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
    Err(error) => return Err(error),
  };
  if marker != MARKER_BYTES {
    return Err(io::Error::new(
      io::ErrorKind::InvalidData,
      "invalid inner result marker",
    ));
  }
  let result = File::open(inner.join("result.txt"))?;
  let status = File::open(inner.join("cur_status.txt"))?;
  let stdout = match File::open(inner.join("std_output.txt")) {
    Ok(file) => Some(file),
    Err(error) if error.kind() == io::ErrorKind::NotFound => None,
    Err(error) => return Err(error),
  };
  Ok(Some(Snapshot {
    result,
    status,
    stdout,
  }))
}

/// Mirrors an available nonterminal status to the outer result directory.
pub fn mirror_progress(inner: &Path, outer: &Path) -> io::Result<()> {
  let mut status = match File::open(inner.join("cur_status.txt")) {
    Ok(file) => file,
    Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
    Err(error) => return Err(error),
  };
  atomic_copy(&mut status, &outer.join("cur_status.txt"))
}

/// Removes fixed partial output files from outer, work, and inner locations.
pub fn cleanup(inner: &Path, outer: &Path, work: &Path) -> io::Result<()> {
  for path in [
    outer.join("result.txt"),
    outer.join("cur_status.txt"),
    outer.join("std_output.txt"),
    work.join("std_output.txt"),
    inner.join("result.txt"),
    inner.join("cur_status.txt"),
    inner.join("std_output.txt"),
    inner.join(MARKER),
  ] {
    remove_if_exists(&path)?;
  }
  Ok(())
}

/// Publishes a UOJ Judgment Failed result with status written last.
pub fn judgment_failed(outer: &Path, message: &str) -> io::Result<()> {
  let escaped = message
    .replace('&', "&amp;")
    .replace('<', "&lt;")
    .replace('>', "&gt;")
    .replace('"', "&quot;")
    .replace('\'', "&apos;");
  atomic_write(
    &outer.join("result.txt"),
    format!("error Judgment Failed\ndetails\n<error>{escaped}</error>\n").as_bytes(),
  )?;
  atomic_write(&outer.join("cur_status.txt"), b"Judgment Failed\n")
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::path::PathBuf;
  use std::sync::atomic::{AtomicU64, Ordering};

  static NEXT: AtomicU64 = AtomicU64::new(0);

  fn temp() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
      "hull-uoj-result-{}-{}",
      std::process::id(),
      NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&path).unwrap();
    path
  }

  fn complete(inner: &Path, stdout: bool) {
    fs::write(inner.join("result.txt"), "result-one").unwrap();
    fs::write(inner.join("cur_status.txt"), "Accepted").unwrap();
    if stdout {
      fs::write(inner.join("std_output.txt"), "stdout-one").unwrap();
    }
    fs::write(inner.join(MARKER), MARKER_BYTES).unwrap();
  }

  #[test]
  fn marker() {
    let dir = temp();
    assert!(snapshot(&dir).unwrap().is_none());
    fs::write(dir.join(MARKER), b"wrong\n").unwrap();
    assert_eq!(
      snapshot(&dir).unwrap_err().kind(),
      io::ErrorKind::InvalidData
    );
    fs::remove_dir_all(dir).unwrap();
  }

  #[test]
  fn held_inode() {
    let root = temp();
    let inner = root.join("inner");
    let outer = root.join("outer");
    let work = root.join("work");
    for path in [&inner, &outer, &work] {
      fs::create_dir(path).unwrap();
    }
    complete(&inner, true);
    let snapshot = snapshot(&inner).unwrap().unwrap();
    fs::rename(inner.join("result.txt"), inner.join("old-result")).unwrap();
    fs::write(inner.join("result.txt"), "result-two").unwrap();
    snapshot.publish(&outer, &work).unwrap();
    assert_eq!(
      fs::read_to_string(outer.join("result.txt")).unwrap(),
      "result-one"
    );
    assert_eq!(
      fs::read_to_string(outer.join("cur_status.txt")).unwrap(),
      "Accepted"
    );
    fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn stale_stdout() {
    let root = temp();
    let inner = root.join("inner");
    let outer = root.join("outer");
    let work = root.join("work");
    for path in [&inner, &outer, &work] {
      fs::create_dir(path).unwrap();
    }
    fs::write(outer.join("std_output.txt"), "stale").unwrap();
    fs::write(work.join("std_output.txt"), "stale").unwrap();
    complete(&inner, false);
    snapshot(&inner)
      .unwrap()
      .unwrap()
      .publish(&outer, &work)
      .unwrap();
    assert!(!outer.join("std_output.txt").exists());
    assert!(!work.join("std_output.txt").exists());
    fs::remove_dir_all(root).unwrap();
  }

  #[test]
  fn failed() {
    let dir = temp();
    judgment_failed(&dir, "bad <state>").unwrap();
    assert!(
      fs::read_to_string(dir.join("result.txt"))
        .unwrap()
        .contains("bad &lt;state&gt;")
    );
    assert_eq!(
      fs::read_to_string(dir.join("cur_status.txt")).unwrap(),
      "Judgment Failed\n"
    );
    fs::remove_dir_all(dir).unwrap();
  }
}
