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
