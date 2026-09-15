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

//! Shell fixtures with a fixed executable and a separate body file.
//!
//! A fork can inherit a write descriptor and block execution of that file with `ETXTBSY`.
//! Tests write only the body file. The shell reads that file through a fixed launcher that tests never write.

use std::fs;
use std::os::unix::fs::symlink;
use std::path::Path;

/// Creates a shell fixture whose body remains readable while a process holds a write descriptor.
pub fn script(path: &Path, body: &str) {
  fs::write(path.with_added_extension("body"), body).unwrap();
  symlink(concat!(env!("CARGO_MANIFEST_DIR"), "/src/fixture.sh"), path).unwrap();
}

mod tests {
  use super::*;
  use std::fs::File;
  use std::os::unix::process::CommandExt;
  use std::process::{Command, Stdio};

  #[test]
  fn open_body() {
    let root = std::env::temp_dir().join(format!("hull uoj fixtures {}", std::process::id()));
    fs::create_dir(&root).unwrap();
    let path = root.join("judge");
    script(
      &path,
      "printf '%s\\n' \"$0\" \"$1\" \"$FIXTURE_VALUE\"; cat; printf diagnostic >&2; exit 7",
    );
    let input = root.join("input");
    fs::write(&input, "payload\n").unwrap();

    // Keep the write descriptor open across fork and exec. The body must remain readable.
    let writer = File::options()
      .append(true)
      .open(path.with_added_extension("body"))
      .unwrap();
    let mut command = Command::new(&path);
    command
      .arg("one argument")
      .env("FIXTURE_VALUE", "from environment")
      .stdin(Stdio::from(File::open(input).unwrap()));
    // A pre-exec hook forces the fork path, as in ProcessGroup.
    unsafe { command.pre_exec(|| Ok(())) };
    let output = command.output().unwrap();
    drop(writer);
    fs::remove_dir_all(root).unwrap();

    assert_eq!(output.status.code(), Some(7));
    assert_eq!(
      output.stdout,
      format!(
        "{}\none argument\nfrom environment\npayload\n",
        path.display()
      )
      .as_bytes()
    );
    assert_eq!(output.stderr, b"diagnostic");
  }
}
