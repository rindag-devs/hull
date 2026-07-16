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

use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// The four directories supplied by the UOJ judger ABI.
pub struct Args {
  /// Per-run UOJ working directory.
  pub work: PathBuf,
  /// UOJ result directory.
  pub result: PathBuf,
  /// UOJ problem data directory.
  pub data: PathBuf,
}

impl Args {
  /// Parses exactly four path arguments after the program name.
  pub fn parse<I, T>(args: I) -> io::Result<Self>
  where
    I: IntoIterator<Item = T>,
    T: Into<OsString>,
  {
    let mut args = args.into_iter().map(Into::into);
    let _program = args.next();
    let _main = args.next().ok_or_else(|| invalid("missing main path"))?;
    let work = args.next().ok_or_else(|| invalid("missing work path"))?;
    let result = args.next().ok_or_else(|| invalid("missing result path"))?;
    let data = args.next().ok_or_else(|| invalid("missing data path"))?;
    if args.next().is_some() {
      return Err(invalid("too many arguments"));
    }
    Ok(Self {
      work: work.into(),
      result: result.into(),
      data: data.into(),
    })
  }
}

/// Values generated with a packaged supervisor bundle.
pub struct SupervisorConfig {
  /// Store-relative path to nix-user-chroot.
  pub nix_user_chroot_store_suffix: PathBuf,
  /// Runner path as seen inside the chroot.
  pub runner: PathBuf,
  /// Identifier for the archived runtime closure.
  pub runtime_id: String,
}

impl SupervisorConfig {
  /// Reads the three values consumed by the supervisor.
  pub fn read(path: &Path) -> io::Result<Self> {
    let content = fs::read_to_string(path)?;
    let mut suffix = None;
    let mut runner = None;
    let mut runtime_id = None;
    for line in content.lines() {
      let Some((key, value)) = line.split_once('=') else {
        continue;
      };
      match key.trim() {
        "nix_user_chroot_store_suffix" => suffix = Some(value.trim()),
        "runner" => runner = Some(value.trim()),
        "runtime_id" => runtime_id = Some(value.trim()),
        _ => {}
      }
    }
    Ok(Self {
      nix_user_chroot_store_suffix: suffix
        .ok_or_else(|| invalid("missing nix_user_chroot_store_suffix"))?
        .into(),
      runner: runner.ok_or_else(|| invalid("missing runner"))?.into(),
      runtime_id: runtime_id
        .ok_or_else(|| invalid("missing runtime_id"))?
        .to_string(),
    })
  }
}

/// Reads the first answer language record from UOJ submission metadata.
pub fn submission_language(path: &Path) -> io::Result<String> {
  let content = fs::read_to_string(path)?;
  for line in content.lines() {
    let mut fields = line.split_whitespace();
    if fields.next() != Some("answer_language") {
      continue;
    }
    let language = fields
      .next()
      .ok_or_else(|| invalid("answer_language has no value"))?;
    if fields.next().is_some() {
      return Err(invalid("answer_language has multiple values"));
    }
    return Ok(language.to_string());
  }
  Err(invalid("missing answer_language"))
}

fn invalid(message: &str) -> io::Error {
  io::Error::new(io::ErrorKind::InvalidData, message)
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::sync::atomic::{AtomicU64, Ordering};

  static NEXT: AtomicU64 = AtomicU64::new(0);

  fn temp() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
      "hull-uoj-config-{}-{}",
      std::process::id(),
      NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&path).unwrap();
    path
  }

  #[test]
  fn four_paths() {
    let args = Args::parse(["supervisor", "main", "work", "result", "data"]).unwrap();
    assert_eq!(args.data, Path::new("data"));
    assert!(Args::parse(["supervisor", "main", "work", "result"]).is_err());
  }

  #[test]
  fn language() {
    let dir = temp();
    let path = dir.join("submission.conf");
    fs::write(
      &path,
      "other x y\nanswer_language C++20\nanswer_language C\n",
    )
    .unwrap();
    assert_eq!(submission_language(&path).unwrap(), "C++20");
    fs::write(&path, "answer_language C extra\n").unwrap();
    assert!(submission_language(&path).is_err());
    fs::remove_dir_all(dir).unwrap();
  }

  #[test]
  fn generated() {
    let dir = temp();
    let path = dir.join("supervisor.conf");
    fs::write(
      &path,
      "ignored=value\nnix_user_chroot_store_suffix=/abc/bin/nix-user-chroot\nrunner=/nix/store/runner/bin/run\nruntime_id=closure-1\n",
    )
    .unwrap();
    let config = SupervisorConfig::read(&path).unwrap();
    assert_eq!(config.runner, Path::new("/nix/store/runner/bin/run"));
    assert_eq!(config.runtime_id, "closure-1");
    fs::remove_dir_all(dir).unwrap();
  }
}
