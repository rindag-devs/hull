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
  build::BuildOpts, build_contest::BuildContestOpts, judge::JudgeOpts, patch::PatchOpts,
  run::RunOpts, run_wasm::RunWasmOpts, selfeval::SelfEvalOpts, stress::StressOpts,
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
  #[command(
    about = "Analyze one problem and package a target",
    long_about = "Load one problem from the current flake, realize its runtime artifacts, run validator/checker/solution analysis, and then package the selected problem target with `nix build`."
  )]
  Build(BuildOpts),
  #[command(
    about = "Analyze a contest and package a target",
    long_about = "Load one contest from the current flake, realize runtime artifacts for every problem in it, analyze each problem, and then package the selected contest target with `nix build`."
  )]
  BuildContest(BuildContestOpts),
  #[command(
    about = "Judge one source file as an ad-hoc solution",
    long_about = "Treat the given source file as an extra solution for the selected problem, run the full problem analysis for it, and print either a human-readable or JSON judging report."
  )]
  Judge(JudgeOpts),
  #[command(
    about = "Patch source code with a regex rewrite",
    long_about = "Parse a C or C++ source file, apply a regex replacement to the path inside each `#include \"...\"` string literal, and write the patched file to a new path."
  )]
  Patch(PatchOpts),
  #[command(
    about = "Compile a source file and run its WASM",
    long_about = "Compile one source file in the selected problem context to a WebAssembly executable, cache a native module for it, and run it with optional tick, memory, and argv overrides."
  )]
  Run(RunOpts),
  #[command(
    about = "Run a WASM module in Hull's sandbox",
    long_about = "Execute a WebAssembly module directly with Hull's runner, configurable stdio, tick and memory limits, optional sandbox files, and a JSON run report."
  )]
  RunWasm(RunWasmOpts),
  #[command(
    about = "Evaluate participant samples offline from an exported bundle",
    long_about = "Compile participant sources to WASM with the bundled toolchain, then judge contest samples serially with the bundled Hull runtime and exported judger artifacts."
  )]
  SelfEval(SelfEvalOpts),
  #[command(
    about = "Search for hacks with generated test cases",
    long_about = "Run a generator repeatedly, build one temporary test case per generated input, judge the selected solutions against the problem's main correct solution, and stop when a non-accepted result is found."
  )]
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
