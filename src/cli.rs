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
  build::BuildOpts, build_contest::BuildContestOpts, integration_judge::IntegrationJudgeCommand,
  judge::JudgeOpts, patch::PatchOpts, run::RunOpts, run_wasm::RunWasmOpts,
  source_config::SourceConfigOpts, stress::StressOpts,
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
  /// Extracts Hull configuration from source comments.
  SourceConfig(SourceConfigOpts),
  #[command(
    about = "Run judge-system integration helpers",
    long_about = "Run hidden helpers used by exported judge-system bundles and participant self-evaluation launchers."
  )]
  /// Runs judge-system integration helpers.
  IntegrationJudge {
    #[command(subcommand)]
    command: IntegrationJudgeCommand,
  },
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

#[cfg(test)]
mod tests {
  use super::*;
  use crate::cmd::source_config::SourceLanguage;

  #[test]
  fn source_config_cli() {
    let c_opts = Opts::try_parse_from(["hull", "source-config", "c"])
      .expect("source-config c subcommand parses");
    assert!(matches!(
      c_opts.command,
      Command::SourceConfig(SourceConfigOpts {
        language: SourceLanguage::C
      })
    ));

    let cpp_opts = Opts::try_parse_from(["hull", "source-config", "cpp"])
      .expect("source-config cpp subcommand parses");
    assert!(matches!(
      cpp_opts.command,
      Command::SourceConfig(SourceConfigOpts {
        language: SourceLanguage::Cpp
      })
    ));

    assert!(Opts::try_parse_from(["hull", "source-config", "unsupported"]).is_err());
  }

  #[test]
  fn judge_cli() {
    let uoj_opts = Opts::try_parse_from([
      "hull",
      "integration-judge",
      "uoj",
      "--bundle-root",
      "/bundle",
      "--metadata-path",
      "metadata.json",
      "--submission-file",
      "main.cpp",
      "--submission-language",
      "C++20",
      "--uoj-work-path",
      "/work",
      "--uoj-result-path",
      "/result",
      "--uoj-data-path",
      "/data",
      "--threads",
      "1",
    ])
    .expect("integration judge uoj subcommand parses");

    assert!(matches!(
      uoj_opts.command,
      Command::IntegrationJudge {
        command: IntegrationJudgeCommand::Uoj(_)
      }
    ));

    let cnoi_opts = Opts::try_parse_from([
      "hull",
      "integration-judge",
      "cnoi",
      "/participant",
      "--bundle-root",
      "/bundle",
      "--package-root",
      "/package",
    ])
    .expect("integration judge cnoi subcommand parses");

    assert!(matches!(
      cnoi_opts.command,
      Command::IntegrationJudge {
        command: IntegrationJudgeCommand::Cnoi(_)
      }
    ));

    let hydro_opts = Opts::try_parse_from([
      "hull",
      "integration-judge",
      "hydro",
      "--bundle-root",
      "/bundle",
      "--metadata-path",
      "metadata.json",
      "--submission-file",
      "main.cpp",
      "--submission-language",
      "cc.cc20",
      "--language-map-path",
      "language-map.json",
      "--participant-solution-name",
      "hydro",
      "--threads",
      "1",
      "--stdout-report-path",
      "/report",
    ])
    .expect("integration judge hydro subcommand parses");

    assert!(matches!(
      hydro_opts.command,
      Command::IntegrationJudge {
        command: IntegrationJudgeCommand::Hydro(_)
      }
    ));

    let lemon_opts = Opts::try_parse_from([
      "hull",
      "integration-judge",
      "lemon",
      "--bundle-root",
      "/bundle",
      "--metadata-path",
      "problem.json",
      "--submission-file",
      "main.cpp",
      "--submission-language",
      "HullBundle",
      "--language-map-path",
      "lemon-language-map.json",
      "--participant-solution-name",
      "lemon",
      "--threads",
      "1",
      "--plain-output-path",
      "/report",
    ])
    .expect("integration judge lemon subcommand parses");

    assert!(matches!(
      lemon_opts.command,
      Command::IntegrationJudge {
        command: IntegrationJudgeCommand::Lemon(_)
      }
    ));
  }
}
