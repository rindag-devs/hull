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

use crate::runtime;

#[derive(Parser)]
pub struct BuildOpts {
  /// The problem to build, e.g., "aPlusB".
  #[arg(long, short, default_value = "default")]
  problem: String,

  /// The target to build, e.g., "default".
  #[arg(long, short, default_value = "default")]
  target: String,

  /// The system to build, e.g., "x86_64-linux".
  #[arg(long)]
  system: Option<String>,

  /// Path to save the result link.
  #[arg(long, short, default_value = "result")]
  out_link: String,

  /// Whether to let nix resolve git submodules.
  #[arg(long)]
  submodules: bool,

  /// Extra arguments passed to nix build.
  #[arg(trailing_var_arg = true)]
  extra_args: Vec<String>,
}

pub fn run(build_opts: &BuildOpts) -> Result<()> {
  let _ = (
    &build_opts.system,
    build_opts.submodules,
    &build_opts.extra_args,
  );
  runtime::build_problem(
    &build_opts.problem,
    &build_opts.target,
    &build_opts.out_link,
  )
}
