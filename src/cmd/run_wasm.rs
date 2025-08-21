use anyhow::{Ok, Result};
use clap::Parser;
use wasi_common::{
  WasiFile,
  pipe::{ReadPipe, WritePipe},
};

use crate::runner::{self, judge_dir::JudgeDir};

const DEFAULT_TICK_LIMIT: u64 = 100_000_000_000;
const DEFAULT_MEMORY_LIMIT: u64 = u32::MAX as u64;

#[derive(Parser)]
pub struct RunWasmOpts {
  /// Path to the WebAssembly file to execute.
  wasm_path: String,

  /// Maximum number of ticks the WASM module can execute.
  #[arg(long, default_value_t = DEFAULT_TICK_LIMIT)]
  tick_limit: u64,

  /// Memory limit for the WASM module in bytes.
  #[arg(long, default_value_t = DEFAULT_MEMORY_LIMIT)]
  memory_limit: u64,

  /// Path to a file to use as stdin.
  #[arg(long, conflicts_with = "inherit_stdin")]
  stdin_path: Option<String>,

  /// Path to a file to use as stdout.
  #[arg(long, conflicts_with = "inherit_stdout")]
  stdout_path: Option<String>,

  /// Path to a file to use as stderr.
  #[arg(long, conflicts_with = "inherit_stderr")]
  stderr_path: Option<String>,

  /// Inherit stdin from the host process.
  #[arg(long)]
  inherit_stdin: bool,

  /// Inherit stdout from the host process.
  #[arg(long)]
  inherit_stdout: bool,

  /// Inherit stderr from the host process.
  #[arg(long)]
  inherit_stderr: bool,

  /// A file to be made available for reading inside the WASM sandbox's root directory.
  /// Can be specified multiple times.
  #[arg(long = "read-file")]
  read_files: Vec<String>,

  /// A file to be made available for writing inside the WASM sandbox's root directory.
  /// Can be specified multiple times.
  #[arg(long = "write-file")]
  write_files: Vec<String>,

  /// Path to write report files.
  // If not set, the report will be written to stdout.
  #[arg(long)]
  report_path: Option<String>,

  /// Arguments to pass to the WASM module.
  #[arg(trailing_var_arg = true)]
  arguments: Vec<String>,
}

pub fn run(run_wasm_opts: &RunWasmOpts) -> Result<()> {
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

  let wasm_bytes = std::fs::read(&run_wasm_opts.wasm_path)?;

  let judge_dir = JudgeDir::new(&run_wasm_opts.read_files, &run_wasm_opts.write_files)?;

  let result = runner::run(
    &wasm_bytes,
    &run_wasm_opts.arguments,
    run_wasm_opts.tick_limit,
    run_wasm_opts.memory_limit,
    stdin,
    stdout,
    stderr,
    Some(Box::new(judge_dir)),
  );

  match &run_wasm_opts.report_path {
    Some(path) => std::fs::write(path, serde_json::to_string(&result)?)?,
    None => println!("{}", serde_json::to_string(&result)?),
  };

  Ok(())
}
