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

use std::collections::BTreeMap;

use anyhow::{Context, Result};
use clap::Parser;
use rand::Rng;
use rayon::{ThreadPoolBuilder, prelude::*};
use tracing::info;

use crate::{
  interactive,
  runtime::{
    ProblemSpec, RuntimeOptions, RuntimeWorkspace, SubtaskSpec, TestCaseSpec, analyze_problem,
    load_problem_spec, run_wasm_for_stdio,
  },
  utils::{format_size, format_tick},
};

#[derive(Parser)]
pub struct StressOpts {
  /// Standard solution name. Defaults to the problem's `mainCorrectSolution`.
  #[arg(long, short)]
  pub std: Option<String>,

  /// Solution names to test against the standard solution.
  #[arg(required = true)]
  pub solutions: Vec<String>,

  /// Generator name used to produce candidate inputs.
  #[arg(long, short)]
  pub generator: String,

  /// Problem name that provides the generator, checker, and solutions.
  #[arg(long, short, default_value = "default")]
  pub problem: String,

  /// Number of generated cases to test in parallel per round.
  #[arg(short = 'j', long = "jobs")]
  pub jobs: Option<usize>,

  /// Number of stress rounds to run. If omitted, run until interrupted.
  #[arg(long, short)]
  pub rounds: Option<u64>,

  /// Generator argument name used to pass the per-case random salt.
  #[arg(long, default_value = "salt")]
  pub salt_arg: String,

  /// Override the per-test tick limit for generated cases.
  #[arg(long, short)]
  pub tick_limit: Option<u64>,

  /// Override the per-test memory limit in bytes for generated cases.
  #[arg(long, short)]
  pub memory_limit: Option<u64>,

  /// Extra arguments to pass to the generator after `--`.
  #[arg(allow_hyphen_values = true, last = true)]
  pub args: Vec<String>,
}

#[derive(Debug)]
struct FailingTestCase {
  args: Vec<String>,
  failing_solution_name: String,
  report: JudgeRunResult,
}

#[derive(Debug)]
struct JudgeRunResult {
  status: String,
  score: f64,
  tick: u64,
  memory: u64,
  message: String,
}

pub fn run(opts: &StressOpts) -> Result<()> {
  let mut generator_args: Vec<String> = Vec::new();
  let mut args_iter = opts.args.iter();
  for arg in args_iter.by_ref() {
    if arg == "--" {
      break;
    }
    generator_args.push(arg.clone());
  }

  let jobs = opts.jobs.unwrap_or_else(num_cpus::get).max(1);

  let mut problem = load_problem_spec(&opts.problem)?;
  let progress = interactive::create_problem_progress(&problem.name);
  let available_solutions = problem
    .solutions
    .iter()
    .map(|solution| solution.name.clone())
    .collect::<std::collections::BTreeSet<_>>();
  if let Some(std_name) = &opts.std {
    if !available_solutions.contains(std_name) {
      anyhow::bail!("Standard solution `{std_name}` does not exist in problem metadata");
    }
    problem.main_correct_solution = std_name.clone();
  }

  let solutions_to_test = opts.solutions.clone();
  let missing_solutions = solutions_to_test
    .iter()
    .filter(|name| !available_solutions.contains(name.as_str()))
    .cloned()
    .collect::<Vec<_>>();
  if !missing_solutions.is_empty() {
    anyhow::bail!("Unknown stress solutions: {}", missing_solutions.join(", "));
  }
  problem.solutions.retain(|solution| {
    solution.name == problem.main_correct_solution || solutions_to_test.contains(&solution.name)
  });

  let generator_wasm = problem
    .generators
    .get(&opts.generator)
    .and_then(|program| program.wasm.as_ref())
    .with_context(|| format!("Generator `{}` is missing `wasm` metadata", opts.generator))?
    .clone();

  let mut round = 1;
  loop {
    if let Some(max_rounds) = opts.rounds {
      if round > max_rounds {
        info!("Finished {} stress testing rounds.", max_rounds);
        break;
      }
      info!(
        "Starting stress test round {}/{} with {} jobs...",
        round, max_rounds, jobs
      );
    } else {
      info!("Starting stress test round {} with {} jobs...", round, jobs);
    }

    let mut all_generator_args = Vec::new();
    let mut rng = rand::thread_rng();
    const CHARSET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    for _ in 0..jobs {
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

    let hacked_case = run_stress_round(&StressRoundContext {
      problem: &problem,
      generator_wasm: &crate::runtime::realize_artifact(&generator_wasm)?,
      generator_args_list: &all_generator_args,
      generator_name: &opts.generator,
      tick_limit_override: opts.tick_limit,
      memory_limit_override: opts.memory_limit,
      round,
      options: RuntimeOptions::new(Some(jobs)).with_progress(progress.clone()),
    })?;

    info!("Stress test batch finished.");
    match hacked_case {
      Some(case) => {
        println!("\nHacked! Found a failing test case.");
        let report = case.report;
        println!(
          "  Solution `{}` failed with status: {}, score: {:.3}, tick: {}, memory: {}",
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
      None => {
        if let Some(max_rounds) = opts.rounds {
          info!(
            "Round {}/{} finished. Not hacked. All solutions passed {} test cases.",
            round, max_rounds, jobs
          );
        } else {
          info!(
            "Round {} finished. Not hacked. All solutions passed {} test cases.",
            round, jobs
          );
        }
      }
    }

    round += 1;
  }

  Ok(())
}

fn run_stress_round(context: &StressRoundContext<'_>) -> Result<Option<FailingTestCase>> {
  ThreadPoolBuilder::new()
    .num_threads(context.options.jobs)
    .build()
    .context("Failed to build stress worker pool")?
    .install(|| {
      context
        .generator_args_list
        .par_iter()
        .enumerate()
        .map(|(case_index, generator_args)| {
          let test_case_name = format!("stress-round-{}-case-{case_index}", context.round);
          let generated_input =
            generate_input(context.generator_wasm, generator_args, &test_case_name)?;
          let mut dynamic_problem = context.problem.clone();
          dynamic_problem.test_cases = vec![TestCaseSpec {
            name: test_case_name.clone(),
            input_file: Some(generated_input.to_string_lossy().into_owned()),
            tick_limit: context
              .tick_limit_override
              .unwrap_or(context.problem.tick_limit),
            memory_limit: context
              .memory_limit_override
              .unwrap_or(context.problem.memory_limit),
            groups: Vec::new(),
            traits: BTreeMap::new(),
            generator: Some(context.generator_name.to_string()),
            arguments: Some(generator_args.to_vec()),
          }];
          dynamic_problem.validator_tests = Vec::new();
          dynamic_problem.checker_tests = Vec::new();
          dynamic_problem.subtasks = vec![SubtaskSpec {
            full_score: 1.0,
            scoring_method: "min".to_string(),
            traits: BTreeMap::new(),
          }];

          let workspace = RuntimeWorkspace::new(
            std::env::temp_dir().join(format!("hull-stress-{}-{case_index}", context.round)),
          )?;
          let runtime = analyze_problem(&dynamic_problem, &workspace, context.options.clone())?;

          for solution in dynamic_problem
            .solutions
            .iter()
            .filter(|solution| solution.name != dynamic_problem.main_correct_solution)
          {
            let solution_report = runtime
              .solutions
              .get(&solution.name)
              .and_then(|solution_runtime| solution_runtime.test_case_results.get(&test_case_name))
              .with_context(|| {
                format!(
                  "Missing stress result for solution `{}` and test case `{}`",
                  solution.name, test_case_name
                )
              })?;
            if solution_report.status != "accepted" {
              return Ok(Some(FailingTestCase {
                args: generator_args.to_vec(),
                failing_solution_name: solution.name.clone(),
                report: JudgeRunResult {
                  status: solution_report.status.clone(),
                  score: solution_report.score,
                  tick: solution_report.tick,
                  memory: solution_report.memory,
                  message: solution_report.message.clone(),
                },
              }));
            }
          }

          Ok(None)
        })
        .collect::<Result<Vec<_>>>()
        .map(|cases| cases.into_iter().flatten().next())
    })
}

struct StressRoundContext<'a> {
  problem: &'a ProblemSpec,
  generator_wasm: &'a str,
  generator_args_list: &'a [Vec<String>],
  generator_name: &'a str,
  tick_limit_override: Option<u64>,
  memory_limit_override: Option<u64>,
  round: u64,
  options: RuntimeOptions,
}

fn generate_input(
  generator_wasm: &str,
  arguments: &[String],
  test_case_name: &str,
) -> Result<std::path::PathBuf> {
  let result = run_wasm_for_stdio(
    generator_wasm,
    None,
    arguments,
    u64::MAX,
    u32::MAX as u64,
    &[],
  )?;
  let path = std::env::temp_dir().join(format!("hull-stress-input-{test_case_name}.txt"));
  std::fs::write(&path, result.stdout)
    .with_context(|| format!("Failed to write generated stress input {}", path.display()))?;
  Ok(path)
}
