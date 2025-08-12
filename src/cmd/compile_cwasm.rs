use anyhow::Result;
use clap::Parser;

use crate::runner::compile;

#[derive(Parser)]
pub struct CompileCwasmOpts {
  wasm_path: String,
  out_path: String,
}

pub fn run(compile_cwasm_opts: &CompileCwasmOpts) -> Result<()> {
  let wasm_bytes = std::fs::read(&compile_cwasm_opts.wasm_path)?;
  let result = compile(&wasm_bytes)?;
  std::fs::write(&compile_cwasm_opts.out_path, result)?;
  Ok(())
}
