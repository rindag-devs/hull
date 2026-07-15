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

use std::fs;

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

  // Grant real file system access by pre-opening the root directory.
  let dir = Dir::open_ambient_dir("/", ambient_authority())
    .context("Failed to open host root directory '/' for WASI preopen")?;
  let preopened_dir: Option<Box<dyn WasiDir>> = Some(Box::new(WasiSyncDir::from_cap_std(dir)));

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
