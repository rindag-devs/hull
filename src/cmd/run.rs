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

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use clap::Parser;
use tracing::info;

use crate::{
  cmd::compile::{SourceCompileOpts, compile_source},
  runner::{self, LocalProgramRequest},
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

  /// Limit bytes written to each inherited stdout and stderr stream.
  ///
  /// Ambient regular files exposed by `--cwd` are not subject to this limit.
  #[arg(long)]
  pub file_size_limit: Option<usize>,

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
  let cwd = resolve_cwd(opts.cwd.as_deref())?;

  info!("Running program");
  let result = runner::run_local(LocalProgramRequest {
    wasm_path: PathBuf::from(wasm_path),
    arguments: opts.args.clone(),
    tick_limit: opts.tick_limit.unwrap_or(runner::TOOL_TICK_LIMIT),
    memory_limit: opts.memory_limit.unwrap_or(runner::TOOL_MEMORY_LIMIT),
    file_size_limit: opts.file_size_limit.unwrap_or(runner::TOOL_FILE_SIZE_LIMIT),
    cwd: Some(cwd),
  })?;

  // Show status if requested
  if opts.show_status {
    use crate::format::{format_size, format_tick};
    eprintln!("Status: {}", result.status);
    if let Some(exit_code) = result.exit_code {
      eprintln!("Exit code: {exit_code}");
    }
    eprintln!("Tick: {}", format_tick(result.tick));
    eprintln!("Memory: {}", format_size(result.memory));
    if let Some(error_message) = result.error_message {
      eprintln!("Error message:\n{error_message}");
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

#[cfg(test)]
mod tests {
  use super::*;

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
}
