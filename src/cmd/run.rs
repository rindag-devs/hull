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

use std::{
  fs,
  path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use cap_std::{ambient_authority, fs::Dir};
use clap::Parser;
use tracing::info;
use wasi_common::{
  WasiDir, WasiFile,
  pipe::{ReadPipe, WritePipe},
  sync::dir::Dir as WasiSyncDir,
};

use crate::{
  cmd::compile::{SourceCompileOpts, compile_source},
  runner,
  runtime::artifact::cache_native_module,
};

/// Options for compiling and running one source file.
#[derive(Parser)]
pub struct RunOpts {
  /// Source and problem options used for compilation.
  #[command(flatten)]
  pub source: SourceCompileOpts,

  /// Override the runtime tick limit for the executed program.
  #[arg(long, short)]
  pub tick_limit: Option<u64>,

  /// Override the runtime memory limit in bytes.
  #[arg(long, short)]
  pub memory_limit: Option<u64>,

  /// Print execution status details such as tick and memory to stderr.
  #[arg(long)]
  pub show_status: bool,

  /// Host directory exposed as the program's file system root.
  #[arg(long)]
  pub cwd: Option<PathBuf>,

  /// Arguments to pass to the executed program.
  #[arg(trailing_var_arg = true)]
  pub args: Vec<String>,
}

/// Compiles and runs one source file in Hull's WASM runtime.
pub fn run(opts: &RunOpts) -> Result<()> {
  let wasm_path = compile_source(&opts.source)?;

  info!("Precompiling program");
  let cwasm_path = cache_native_module(&wasm_path)?;
  let cwasm_bytes = fs::read(&cwasm_path)
    .with_context(|| format!("Failed to read executable artifact from {}", cwasm_path))?;

  let stdin: Box<dyn WasiFile> = Box::new(ReadPipe::new(std::io::stdin()));
  let stdout: Box<dyn WasiFile> = Box::new(WritePipe::new(std::io::stdout()));
  let stderr: Box<dyn WasiFile> = Box::new(WritePipe::new(std::io::stderr()));

  let cwd = resolve_cwd(opts.cwd.as_deref())?;
  let preopened_dir = Some(preopen_cwd(&cwd)?);

  info!("Running program");
  let result = runner::run(
    &cwasm_bytes,
    &opts.args,
    opts.tick_limit.unwrap_or(10u64.pow(18)),
    opts.memory_limit.unwrap_or(u32::MAX as u64),
    [stdin, stdout, stderr],
    preopened_dir,
  );

  // Show status if requested
  if opts.show_status {
    use crate::format::{format_size, format_tick};
    eprintln!("Status: {:?}", result.status);
    eprintln!("Exit code: {}", result.exit_code);
    eprintln!("Tick: {}", format_tick(result.tick));
    eprintln!("Memory: {}", format_size(result.memory));
    if !result.error_message.is_empty() {
      eprintln!("Error message:\n{}", result.error_message);
    }
  }

  Ok(())
}

fn resolve_cwd(cwd: Option<&Path>) -> Result<PathBuf> {
  let cwd = cwd
    .map(Path::to_path_buf)
    .map_or_else(std::env::current_dir, Ok)?;
  let cwd = cwd
    .canonicalize()
    .with_context(|| format!("Failed to resolve working directory {}", cwd.display()))?;
  if !cwd.is_dir() {
    anyhow::bail!("Working directory {} is not a directory", cwd.display());
  }
  Ok(cwd)
}

fn preopen_cwd(cwd: &Path) -> Result<Box<dyn WasiDir>> {
  let dir = Dir::open_ambient_dir(cwd, ambient_authority())
    .with_context(|| format!("Failed to open working directory {}", cwd.display()))?;
  Ok(Box::new(WasiSyncDir::from_cap_std(dir)))
}

#[cfg(test)]
mod tests {
  use std::io;

  use super::*;
  use crate::runner::{self, RunStatus};
  use wasi_common::pipe::{ReadPipe, WritePipe};

  #[test]
  fn explicit_cwd() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(resolve_cwd(Some(dir.path())).unwrap(), dir.path());
  }

  #[test]
  fn default_cwd() {
    assert_eq!(
      resolve_cwd(None).unwrap(),
      std::env::current_dir().unwrap().canonicalize().unwrap()
    );
  }

  #[test]
  fn rejects_file_cwd() {
    let file = tempfile::NamedTempFile::new().unwrap();
    assert!(resolve_cwd(Some(file.path())).is_err());
  }

  #[test]
  fn cwd_access() {
    let root = tempfile::tempdir().unwrap();
    let sandbox = root.path().join("sandbox");
    fs::create_dir(&sandbox).unwrap();
    fs::write(sandbox.join("a.txt"), "inside").unwrap();
    fs::write(root.path().join("outside.txt"), "outside").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink("../outside.txt", sandbox.join("escape.txt")).unwrap();

    for (path, follow_symlinks, should_open) in [
      ("a.txt", false, true),
      ("./a.txt", false, true),
      ("../outside.txt", false, false),
      ("etc/passwd", false, false),
      #[cfg(unix)]
      ("escape.txt", true, false),
    ] {
      let condition = if should_open { "i32.ne" } else { "i32.eq" };
      let lookup_flags = u8::from(follow_symlinks);
      let wasm = format!(
        r#"(module
          (import "wasi_snapshot_preview1" "path_open"
            (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
          (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
          (memory (export "memory") 1)
          (data (i32.const 0) "{path}")
          (func (export "_start")
            i32.const 3
            i32.const {lookup_flags}
            i32.const 0
            i32.const {path_len}
            i32.const 0
            i64.const 2
            i64.const 0
            i32.const 0
            i32.const 32
            call $path_open
            i32.const 0
            {condition}
            if
              i32.const 1
              call $proc_exit
            end))"#,
        path_len = path.len()
      );
      let result = runner::run(
        wasm.as_bytes(),
        &[],
        1_000_000,
        1 << 20,
        [
          Box::new(ReadPipe::new(io::empty())),
          Box::new(WritePipe::new(io::sink())),
          Box::new(WritePipe::new(io::sink())),
        ],
        Some(preopen_cwd(&sandbox).unwrap()),
      );
      assert_eq!(result.status, RunStatus::Accepted, "path: {path}");
    }
  }
}
