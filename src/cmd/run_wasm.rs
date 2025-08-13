use anyhow::Result;
use clap::Parser;
use wasi_common::{
  WasiFile,
  pipe::{ReadPipe, WritePipe},
};

use crate::runner;

const DEFAULT_TICK_LIMIT: u64 = 100_000_000_000;
const DEFAULT_MEMORY_LIMIT: u64 = u32::MAX as u64;

#[derive(Parser)]
pub struct RunWasmOpts {
  wasm_path: String,

  #[arg(long, default_value_t = DEFAULT_TICK_LIMIT)]
  tick_limit: u64,

  #[arg(long, default_value_t = DEFAULT_MEMORY_LIMIT)]
  memory_limit: u64,

  #[arg(long)]
  stdin_path: Option<String>,

  #[arg(long)]
  stdout_path: Option<String>,

  #[arg(long)]
  stderr_path: Option<String>,

  #[arg(long)]
  inherit_stdin: bool,

  #[arg(long)]
  inherit_stdout: bool,

  #[arg(long)]
  inherit_stderr: bool,

  #[arg(trailing_var_arg = true)]
  arguments: Vec<String>,
}

pub fn run(run_wasm_opts: &RunWasmOpts) -> Result<()> {
  let stdin: Box<dyn WasiFile> = if let Some(path) = &run_wasm_opts.stdin_path {
    Box::new(wasi_common::sync::file::File::from_cap_std(
      cap_std::fs::File::from_std(std::fs::File::open(path)?),
    ))
  } else if run_wasm_opts.inherit_stdin {
    Box::new(ReadPipe::new(std::io::stdin()))
  } else {
    Box::new(ReadPipe::new(std::io::empty()))
  };
  let stdout: Box<dyn WasiFile> = if let Some(path) = &run_wasm_opts.stdout_path {
    Box::new(wasi_common::sync::file::File::from_cap_std(
      cap_std::fs::File::from_std(std::fs::File::create(path)?),
    ))
  } else if run_wasm_opts.inherit_stdout {
    Box::new(WritePipe::new(std::io::stdout()))
  } else {
    Box::new(WritePipe::new(std::io::sink()))
  };
  let stderr: Box<dyn WasiFile> = if let Some(path) = &run_wasm_opts.stderr_path {
    Box::new(wasi_common::sync::file::File::from_cap_std(
      cap_std::fs::File::from_std(std::fs::File::create(path)?),
    ))
  } else if run_wasm_opts.inherit_stderr {
    Box::new(WritePipe::new(std::io::stderr()))
  } else {
    Box::new(WritePipe::new(std::io::sink()))
  };

  let wasm_bytes = std::fs::read(&run_wasm_opts.wasm_path)?;

  let result = runner::run(
    &wasm_bytes,
    &run_wasm_opts.arguments,
    run_wasm_opts.tick_limit,
    run_wasm_opts.memory_limit,
    stdin,
    stdout,
    stderr,
    None,
  );

  println!("{}", serde_json::to_string(&result)?);

  std::process::exit(result.exit_code);
}
