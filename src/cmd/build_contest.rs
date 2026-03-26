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

use crate::interactive;
use crate::runtime::{self, RuntimeOptions};

#[derive(Parser)]
pub struct BuildContestOpts {
  /// The contest to build, e.g., "day1".
  #[arg(long, short, default_value = "default")]
  pub contest: String,

  /// The target to build, e.g., "default".
  #[arg(long, short, default_value = "default")]
  pub target: String,

  /// Path to save the result link.
  #[arg(long, short, default_value = "result")]
  pub out_link: String,

  /// Number of parallel jobs used by the Rust runtime.
  #[arg(short = 'j', long = "jobs")]
  pub jobs: Option<usize>,

  /// Extra arguments passed through to the final `nix build` invocation.
  #[arg(trailing_var_arg = true)]
  pub nix_args: Vec<String>,
}

pub fn run(build_opts: &BuildContestOpts) -> Result<()> {
  let progress = interactive::create_problem_progress(&build_opts.contest);
  runtime::build_contest(
    &build_opts.contest,
    &build_opts.target,
    &build_opts.out_link,
    RuntimeOptions::new(build_opts.jobs).with_progress(progress),
    &build_opts.nix_args,
  )
}
