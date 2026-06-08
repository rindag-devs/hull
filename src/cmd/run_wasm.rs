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

use anyhow::{Context, Ok, Result, bail};
use clap::Parser;
use std::path::{Path, PathBuf};
use wasi_common::{
  WasiFile,
  pipe::{ReadPipe, WritePipe},
};

use crate::{
  runner::{self, RunStatus, judge_dir::JudgeDir},
  runtime::artifact::cache_native_module,
};

const DEFAULT_TICK_LIMIT: u64 = 100_000_000_000;
const DEFAULT_MEMORY_LIMIT: u64 = u32::MAX as u64;

#[derive(Parser)]
pub struct RunWasmOpts {
  /// Path to the WebAssembly file to execute.
  pub wasm_path: String,

  /// Maximum number of ticks the module may execute.
  #[arg(long, default_value_t = DEFAULT_TICK_LIMIT)]
  pub tick_limit: u64,

  /// Maximum linear memory usage in bytes.
  #[arg(long, default_value_t = DEFAULT_MEMORY_LIMIT)]
  pub memory_limit: u64,

  /// Read stdin for the module from this host file.
  #[arg(long, conflicts_with = "inherit_stdin")]
  pub stdin_path: Option<String>,

  /// Write stdout from the module to this host file.
  #[arg(long, conflicts_with = "inherit_stdout")]
  pub stdout_path: Option<String>,

  /// Write stderr from the module to this host file.
  #[arg(long, conflicts_with = "inherit_stderr")]
  pub stderr_path: Option<String>,

  /// Inherit stdin from the current process.
  #[arg(long)]
  pub inherit_stdin: bool,

  /// Inherit stdout from the current process.
  #[arg(long)]
  pub inherit_stdout: bool,

  /// Inherit stderr from the current process.
  #[arg(long)]
  pub inherit_stderr: bool,

  /// Expose a host file as a readable file at the same path inside the sandbox root.
  /// May be passed multiple times.
  #[arg(long = "read-file")]
  pub read_files: Vec<String>,

  /// Create a writable file at this path inside the sandbox root and on the host.
  /// May be passed multiple times.
  #[arg(long = "write-file")]
  pub write_files: Vec<String>,

  /// Write the JSON run report to this file instead of stdout.
  #[arg(long)]
  pub report_path: Option<String>,

  /// Exit with an error unless the run result is `accepted`.
  #[arg(long)]
  pub ensure_accepted: bool,

  /// Arguments to pass to the module.
  #[arg(trailing_var_arg = true)]
  pub arguments: Vec<String>,
}

pub fn run(run_wasm_opts: &RunWasmOpts) -> Result<()> {
  reject_stdio_output_conflicts(run_wasm_opts)?;

  let executable_path = cache_native_module(&run_wasm_opts.wasm_path)?;
  let wasm_bytes = std::fs::read(&executable_path)?;

  // Stdio paths may refer to FIFOs or other special files; opening one side
  // sequentially can block forever before the matching side is opened.
  let (stdin_res, stdout_res, stderr_res) = std::thread::scope(|s| {
    let stdin_handle = s.spawn(|| {
      if let Some(path) = &run_wasm_opts.stdin_path {
        let file = wasi_common::sync::file::File::from_cap_std(cap_std::fs::File::from_std(
          std::fs::File::open(path)?,
        ));
        Ok(Some(Box::new(file) as Box<dyn WasiFile>))
      } else {
        Ok(None)
      }
    });

    let stdout_handle = s.spawn(|| {
      if let Some(path) = &run_wasm_opts.stdout_path {
        let file = wasi_common::sync::file::File::from_cap_std(cap_std::fs::File::from_std(
          std::fs::File::create(path)?,
        ));
        Ok(Some(Box::new(file) as Box<dyn WasiFile>))
      } else {
        Ok(None)
      }
    });

    let stderr_handle = s.spawn(|| {
      if let Some(path) = &run_wasm_opts.stderr_path {
        let file = wasi_common::sync::file::File::from_cap_std(cap_std::fs::File::from_std(
          std::fs::File::create(path)?,
        ));
        Ok(Some(Box::new(file) as Box<dyn WasiFile>))
      } else {
        Ok(None)
      }
    });

    (
      stdin_handle.join().unwrap(),
      stdout_handle.join().unwrap(),
      stderr_handle.join().unwrap(),
    )
  });

  let stdin: Box<dyn WasiFile> = if let Some(file) = stdin_res? {
    file
  } else if run_wasm_opts.inherit_stdin {
    Box::new(ReadPipe::new(std::io::stdin()))
  } else {
    Box::new(ReadPipe::new(std::io::empty()))
  };

  let stdout: Box<dyn WasiFile> = if let Some(file) = stdout_res? {
    file
  } else if run_wasm_opts.inherit_stdout {
    Box::new(WritePipe::new(std::io::stdout()))
  } else {
    Box::new(WritePipe::new(std::io::sink()))
  };

  let stderr: Box<dyn WasiFile> = if let Some(file) = stderr_res? {
    file
  } else if run_wasm_opts.inherit_stderr {
    Box::new(WritePipe::new(std::io::stderr()))
  } else {
    Box::new(WritePipe::new(std::io::sink()))
  };

  let judge_dir = JudgeDir::new(&run_wasm_opts.read_files, &run_wasm_opts.write_files)?;

  let result = runner::run(
    &wasm_bytes,
    &run_wasm_opts.arguments,
    run_wasm_opts.tick_limit,
    run_wasm_opts.memory_limit,
    [stdin, stdout, stderr],
    Some(Box::new(judge_dir)),
  );

  match &run_wasm_opts.report_path {
    Some(path) => std::fs::write(path, serde_json::to_string(&result)?)?,
    None => println!("{}", serde_json::to_string(&result)?),
  };

  if run_wasm_opts.ensure_accepted && result.status != RunStatus::Accepted {
    bail!(
      "The run returned an unaccepted status, report: {}",
      serde_json::to_string(&result)?
    );
  }

  Ok(())
}

fn reject_stdio_output_conflicts(opts: &RunWasmOpts) -> Result<()> {
  let wasm_path = comparable_regular_file_path(&opts.wasm_path)?
    .with_context(|| format!("WASM path {} is not a regular file", opts.wasm_path))?;
  let stdin_path = opts
    .stdin_path
    .as_deref()
    .map(comparable_regular_file_path)
    .transpose()?
    .flatten();

  for output_path in [&opts.stdout_path, &opts.stderr_path].into_iter().flatten() {
    let Some(output_path) = comparable_regular_file_path(output_path)? else {
      continue;
    };
    if output_path == wasm_path || stdin_path.as_ref() == Some(&output_path) {
      panic!("stdio output path must not equal the wasm path or stdin path");
    }
  }
  Ok(())
}

fn comparable_regular_file_path(path: &str) -> Result<Option<PathBuf>> {
  let path = Path::new(path);
  if path.exists() {
    if !path.is_file() {
      return Ok(None);
    }
    return path
      .canonicalize()
      .map(Some)
      .with_context(|| format!("Failed to canonicalize {}", path.display()));
  }
  let absolute_path = if path.is_absolute() {
    path.to_path_buf()
  } else {
    std::env::current_dir()
      .context("Failed to determine current directory")?
      .join(path)
  };
  let parent = absolute_path
    .parent()
    .with_context(|| format!("Path {} has no parent", absolute_path.display()))?;
  Ok(Some(
    parent
      .canonicalize()
      .with_context(|| {
        format!(
          "Failed to canonicalize parent of {}",
          absolute_path.display()
        )
      })?
      .join(
        absolute_path
          .file_name()
          .with_context(|| format!("Path {} has no file name", absolute_path.display()))?,
      ),
  ))
}
