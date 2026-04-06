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
use crate::runtime::build::build_problem;
use crate::runtime::types::RuntimeOptions;

#[derive(Parser)]
pub struct BuildOpts {
  /// Problem name to analyze and package, e.g. `aPlusB`.
  #[arg(long, short, default_value = "default")]
  pub problem: String,

  /// Problem target name to package, e.g. `default`.
  #[arg(long, short, default_value = "default")]
  pub target: String,

  /// Symlink path to create for the packaged result.
  #[arg(long, short, default_value = "result")]
  pub out_link: String,

  /// Number of parallel jobs to use during runtime analysis.
  #[arg(short = 'j', long = "jobs")]
  pub jobs: Option<usize>,

  /// Extra arguments to pass through to the final `nix build` step.
  #[arg(trailing_var_arg = true)]
  pub nix_args: Vec<String>,
}

pub fn run(build_opts: &BuildOpts) -> Result<()> {
  let progress = interactive::create_problem_progress(&build_opts.problem);
  build_problem(
    &build_opts.problem,
    &build_opts.target,
    &build_opts.out_link,
    RuntimeOptions::new(build_opts.jobs).with_progress(progress),
    &build_opts.nix_args,
  )
}
