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

use std::{fs, path::Path};

use anyhow::{Context, Result, bail};
use clap::Parser;
use rand::Rng;
use serde::Deserialize;
use tracing::info;

use crate::{
  nix::{BuildCommand, get_current_system, get_flake_url},
  utils::{format_size, format_tick},
};

#[derive(Parser)]
pub struct StressOpts {
  /// Name of the standard solution. If not provided, the problem's mainCorrectSolution will be used.
  #[arg(long, short)]
  std: Option<String>,

  /// Names of the solutions to test.
  #[arg(required = true)]
  solutions: Vec<String>,

  /// Name of the generator to use.
  #[arg(long, short)]
  generator: String,

  /// The problem to build, e.g., "aPlusB".
  #[arg(long, short, default_value = "default")]
  problem: String,

  /// The system to build, e.g., "x86_64-linux".
  #[arg(long)]
  system: Option<String>,

  /// Number of test cases to run in parallel in a single batch.
  #[arg(long, short)]
  batch_size: Option<usize>,

  /// Number of rounds to run. If not set, runs indefinitely.
  #[arg(long, short)]
  rounds: Option<u64>,

  /// The name of the argument used to pass a random salt to the generator.
  #[arg(long, default_value = "salt")]
  salt_arg: String,

  /// Override the tick limit for this run.
  #[arg(long, short)]
  tick_limit: Option<u64>,

  /// Override the memory limit (in bytes) for this run.
  #[arg(long, short)]
  memory_limit: Option<u64>,

  /// Whether to let nix resolve git submodules.
  #[arg(long)]
  submodules: bool,

  /// Arguments for the generator, followed by '--' and then extra arguments for nix build.
  #[arg(allow_hyphen_values = true, last = true)]
  args: Vec<String>,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct StressReport {
  outcome: String,
  failing_test_case: Option<FailingTestCase>,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct FailingTestCase {
  args: Vec<String>,
  failing_solution_name: String,
  report: JudgeRunResult,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct JudgeRunResult {
  status: String,
  score: f64,
  tick: u64,
  memory: u64,
  message: String,
}

pub fn run(opts: &StressOpts) -> Result<()> {
  let mut generator_args: Vec<String> = Vec::new();
  let mut extra_nix_args: Vec<String> = Vec::new();
  let mut args_iter = opts.args.iter();
  for arg in args_iter.by_ref() {
    if arg == "--" {
      break;
    }
    generator_args.push(arg.clone());
  }
  extra_nix_args.extend(args_iter.cloned());

  let batch_size = opts.batch_size.unwrap_or_else(|| 4 * num_cpus::get());

  let mut round = 1;
  loop {
    if let Some(max_rounds) = opts.rounds {
      if round > max_rounds {
        info!("Finished {} stress testing rounds.", max_rounds);
        break;
      }
      info!(
        "Starting stress test round {}/{} with batch size {}...",
        round, max_rounds, batch_size
      );
    } else {
      info!(
        "Starting stress test round {} with batch size {}...",
        round, batch_size
      );
    }

    let mut all_generator_args = Vec::new();
    let mut rng = rand::thread_rng();
    const CHARSET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    for _ in 0..batch_size {
      let salt: String = (0..32)
        .map(|_| {
          let idx = rng.gen_range(0..CHARSET.len());
          CHARSET[idx] as char
        })
        .collect();

      let mut current_args = generator_args.clone();
      current_args.push(format!("--{}={}", opts.salt_arg, salt));
      all_generator_args.push(current_args);
    }

    let generator_args_json = serde_json::to_string(&all_generator_args)
      .context("Failed to serialize generator arguments to JSON")?;
    let test_solutions_json = serde_json::to_string(&opts.solutions)
      .context("Failed to serialize solution names to JSON")?;
    let std_name_json =
      serde_json::to_string(&opts.std).context("Failed to serialize std name to JSON")?;
    let tick_limit = opts
      .tick_limit
      .map(|x| x.to_string())
      .unwrap_or("null".to_string());
    let memory_limit = opts
      .memory_limit
      .map(|x| x.to_string())
      .unwrap_or("null".to_string());

    let system = opts
      .system
      .clone()
      .unwrap_or(get_current_system().context("Failed to determine current system")?);
    let flake_url = get_flake_url().context("Could not determine flake URL")?;
    let submodule_query = if opts.submodules { "?submodules=1" } else { "" };
    let final_flake_ref = format!("{}{}", flake_url, submodule_query);

    let nix_expr = format!(
      r#"
      {{ generatorArgsJSON, testSolutionsJSON, stdNameJSON, generatorName }}:
      let
        flake = builtins.getFlake "{final_flake_ref}";
        hullLib = (flake.inputs.hull.lib or flake.outputs.lib).{system};
        problemConfig = flake.outputs.hullProblems.{system}.{problem}.config;
      in
      hullLib.stress problemConfig {{
        testSolNames = builtins.fromJSON testSolutionsJSON;
        generatorArgs = builtins.fromJSON generatorArgsJSON;
        stdName = builtins.fromJSON stdNameJSON;
        tickLimit = {tick_limit};
        memoryLimit = {memory_limit};
        inherit generatorName;
      }}
      "#,
      problem = opts.problem,
    );

    info!("Starting Nix build for stress test batch...");
    let report_path_str = BuildCommand::new()
      .impure(true)
      .expr(&nix_expr)
      .argstr("generatorArgsJSON", &generator_args_json)
      .argstr("testSolutionsJSON", &test_solutions_json)
      .argstr("stdNameJSON", &std_name_json)
      .argstr("generatorName", &opts.generator)
      .print_out_paths(true)
      .no_link(true)
      .extra_args(&extra_nix_args)
      .run_and_capture_stdout()
      .context("Failed to execute `nix build` for stress testing")?;

    let report_path = Path::new(&report_path_str);
    let report_content = fs::read_to_string(report_path)
      .with_context(|| format!("Failed to read report from {}", report_path.display()))?;

    let report: StressReport =
      serde_json::from_str(&report_content).context("Failed to parse stress report JSON")?;

    info!("Stress test batch finished.");
    match report.outcome.as_str() {
      "hacked" => {
        println!("\nHacked! Found a failing test case.");
        let case = report.failing_test_case.unwrap();
        let report = case.report;
        println!(
          "  Solution '{}' failed with status: {}, score: {:.3}, tick: {}, memory: {}",
          case.failing_solution_name,
          report.status,
          report.score,
          format_tick(report.tick),
          format_size(report.memory),
        );
        println!("  Message: {}", report.message);
        println!(
          "\nTo add this test case to your problem, copy the following into your `problem.nix`:\n"
        );
        println!("  testCases.hack-{} = {{", case.failing_solution_name);
        println!("    generator = \"{}\";", opts.generator);
        println!("    arguments = [");
        for arg in case.args {
          println!("      \"{}\"", arg.escape_default());
        }
        println!("    ];");
        println!("  }};");
        println!();
        return Ok(());
      }
      "not_hacked" => {
        if let Some(max_rounds) = opts.rounds {
          info!(
            "Round {}/{} finished. Not hacked. All solutions passed {} test cases.",
            round, max_rounds, batch_size
          );
        } else {
          info!(
            "Round {} finished. Not hacked. All solutions passed {} test cases.",
            round, batch_size
          );
        }
      }
      _ => {
        bail!("Unknown outcome from stress test: {}", report.outcome);
      }
    }
    round += 1;
  }

  Ok(())
}
