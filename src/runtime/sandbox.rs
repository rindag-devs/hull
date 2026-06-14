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
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

use anyhow::{Context, Result};
use wasi_common::{
  WasiFile,
  pipe::{ReadPipe, WritePipe},
};

use crate::{
  runner::{self, RunStatus, limited_buffer::LimitedBuffer},
  runtime::artifact::cache_native_module,
};

/// Captured result of executing one WASM module in Hull's sandbox.
pub struct WasmRunResult {
  pub status: RunStatus,
  pub tick: u64,
  pub memory: u64,
  pub error_message: String,
  pub stdout: Vec<u8>,
  pub stderr: Vec<u8>,
}

/// Runs one WASM module with optional stdin and read-only sandbox files.
pub fn run_wasm_for_stdio(
  wasm_path: &str,
  stdin_path: Option<&Path>,
  arguments: &[String],
  tick_limit: u64,
  memory_limit: u64,
  output_limit: usize,
  read_files: &[(PathBuf, String)],
) -> Result<WasmRunResult> {
  let executable_path = cache_native_module(wasm_path)?;
  let wasm_bytes = fs::read(&executable_path)
    .with_context(|| format!("Failed to read executable artifact {}", executable_path))?;

  let stdin: Box<dyn WasiFile> = match stdin_path {
    Some(path) => Box::new(ReadPipe::from(
      fs::read(path)
        .with_context(|| format!("Failed to read stdin file {}", path.display()))?
        .as_slice(),
    )),
    None => Box::new(ReadPipe::new(std::io::empty())),
  };

  let stdout_capture = Arc::new(RwLock::new(LimitedBuffer::new(output_limit)));
  let stderr_capture = Arc::new(RwLock::new(LimitedBuffer::new(output_limit)));
  let stdout_pipe = WritePipe::from_shared(stdout_capture.clone());
  let stderr_pipe = WritePipe::from_shared(stderr_capture.clone());

  let preopened_dir = if read_files.is_empty() {
    None
  } else {
    let mappings = read_files
      .iter()
      .map(|(src, dest)| Ok((src.clone(), dest.clone())))
      .collect::<Result<Vec<_>>>()?;
    let judge_dir = crate::runner::judge_dir::JudgeDir::from_mappings(&mappings, &[])?;
    Some(Box::new(judge_dir) as Box<dyn wasi_common::WasiDir>)
  };

  let result = runner::run(
    &wasm_bytes,
    arguments,
    tick_limit,
    memory_limit,
    [stdin, Box::new(stdout_pipe), Box::new(stderr_pipe)],
    preopened_dir,
  );

  let stdout = stdout_capture
    .read()
    .map_err(|_| anyhow::anyhow!("Failed to capture stdout buffer"))?
    .as_ref()
    .to_vec();
  let stderr = stderr_capture
    .read()
    .map_err(|_| anyhow::anyhow!("Failed to capture stderr buffer"))?
    .as_ref()
    .to_vec();

  Ok(WasmRunResult {
    status: result.status,
    tick: result.tick,
    memory: result.memory,
    error_message: result.error_message,
    stdout,
    stderr,
  })
}
