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

use clap::{Parser, Subcommand};

use crate::cmd::{
  build::BuildOpts, build_contest::BuildContestOpts, judge::JudgeOpts,
  patch_includes::PatchIncludesOpts, run::RunOpts, run_wasm::RunWasmOpts, stress::StressOpts,
};
use crate::interactive::InteractiveMode;

/// Competitive programming proposition automation tool
#[derive(Parser)]
#[command(
    name = "Hull",
    bin_name = "hull",
    author = "aberter0x3f <aberter0x3f@disroot.org>",
    version = env!("CARGO_PKG_VERSION"),
    max_term_width = 100,
)]
pub struct Opts {
  /// Control interactive terminal UI: auto, always, or never.
  #[arg(long, global = true, default_value = "auto", value_parser = parse_interactive_mode)]
  pub interactive: InteractiveMode,

  #[command(subcommand)]
  pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
  Build(BuildOpts),
  BuildContest(BuildContestOpts),
  Judge(JudgeOpts),
  PatchIncludes(PatchIncludesOpts),
  Run(RunOpts),
  RunWasm(RunWasmOpts),
  Stress(StressOpts),
}

fn parse_interactive_mode(value: &str) -> Result<InteractiveMode, String> {
  match value {
    "auto" => Ok(InteractiveMode::Auto),
    "always" => Ok(InteractiveMode::Always),
    "never" => Ok(InteractiveMode::Never),
    _ => Err("interactive must be one of: auto, always, never".to_string()),
  }
}
