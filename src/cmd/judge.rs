use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use clap::Parser;
use comfy_table::presets::UTF8_FULL;
use comfy_table::{Cell, Color, Table};
use serde::Deserialize;

#[derive(Parser)]
pub struct JudgeOpts {
  /// The problem to build, e.g., "aPlusB".
  problem: String,

  /// Path to the source file to judge.
  src_path: String,

  /// The system to build, e.g., "x86_64-linux".
  #[arg(long)]
  system: Option<String>,

  /// Whether to let nix resolve git submodules.
  #[arg(long)]
  submodules: bool,

  /// Output the result in JSON format.
  #[arg(long)]
  json: bool,

  /// Extra arguments passed to nix build.
  #[arg(trailing_var_arg = true)]
  extra_args: Vec<String>,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct JudgeReport {
  score: f64,
  full_score: f64,
  subtask_results: Vec<SubtaskResult>,
  test_case_results: HashMap<String, TestCaseResult>,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct SubtaskResult {
  full_score: f64,
  scaled_score: f64,
  statuses: Vec<String>,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct TestCaseResult {
  status: String,
  score: f64,
}

/// Converts a snake_case string to Title Case.
/// e.g., "wrong_answer" -> "Wrong Answer"
fn to_title_case(s: &str) -> String {
  s.split('_')
    .map(|word| {
      let mut c = word.chars();
      match c.next() {
        None => String::new(),
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
      }
    })
    .collect::<Vec<String>>()
    .join(" ")
}

/// Determines the overall status for a subtask based on its test cases.
/// Logic: If empty, "N/A". If any non-"accepted", return the first one. Otherwise, "accepted".
fn get_subtask_status(statuses: &[String]) -> String {
  if statuses.is_empty() {
    return "N/A".to_string();
  }
  statuses
    .iter()
    .find(|s| *s != "accepted")
    .cloned()
    .unwrap_or_else(|| "accepted".to_string())
}

/// Applies color to a status string based on predefined rules.
fn colorize_status(status: &str, text: &str) -> Cell {
  match status {
    "accepted" => Cell::new(text).fg(Color::Green),
    "wrong_answer" => Cell::new(text).fg(Color::Red),
    "partially_correct" => Cell::new(text).fg(Color::Cyan),
    "runtime_error" => Cell::new(text).fg(Color::Magenta),
    "time_limit_exceeded" | "memory_limit_exceeded" => Cell::new(text).fg(Color::Yellow),
    "internal_error" => Cell::new(text).fg(Color::Grey),
    _ => Cell::new(text), // For "N/A" or other statuses
  }
}

/// Prints a human-readable report to the console.
fn print_human_readable_report(report: &JudgeReport) {
  println!(
    "Overall Score: {:.3} / {:.3}\n",
    report.score, report.full_score
  );

  // --- Subtasks Table ---
  let mut subtask_table = Table::new();
  subtask_table.load_preset(UTF8_FULL);
  subtask_table.set_header(vec!["#", "Status", "Score", "Full Score"]);

  for (i, subtask) in report.subtask_results.iter().enumerate() {
    let status_str = get_subtask_status(&subtask.statuses);
    let title_case_status = to_title_case(&status_str);
    let colored_status = colorize_status(&status_str, &title_case_status);

    let full_score = subtask.full_score;
    let obtained_score = subtask.scaled_score;

    let score_str = format!("{:.3}", obtained_score);
    let full_score_str = format!("{:.3}", full_score);

    subtask_table.add_row(vec![
      Cell::new(i + 1),
      colored_status,
      Cell::new(score_str),
      Cell::new(full_score_str),
    ]);
  }
  println!("Subtask Results:");
  println!("{subtask_table}");

  // --- Test Cases Table ---
  let mut test_case_table = Table::new();
  test_case_table.load_preset(UTF8_FULL);
  test_case_table.set_header(vec!["Name", "Status", "Score"]);

  // Sort test cases by name for consistent output
  let mut sorted_test_cases: Vec<_> = report.test_case_results.iter().collect();
  sorted_test_cases.sort_by_key(|(k, _)| *k);

  for (name, case) in sorted_test_cases {
    let title_case_status = to_title_case(&case.status);
    let colored_status = colorize_status(&case.status, &title_case_status);
    let score_str = format!("{:.3}", case.score);

    test_case_table.add_row(vec![Cell::new(name), colored_status, Cell::new(score_str)]);
  }
  println!("\nTest Case Details:");
  println!("{test_case_table}");
}

fn get_current_system() -> Result<String> {
  let output = Command::new("nix")
    .args(["eval", "--raw", "nixpkgs#system"])
    .output()?;
  Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub fn run(judge_opts: &JudgeOpts) -> Result<()> {
  let system = judge_opts.system.clone().unwrap_or(
    get_current_system().context("Failed to determine current system using `nix eval`")?,
  );

  let submodule_arg = if judge_opts.submodules {
    " + \"?submodules=1\""
  } else {
    ""
  };

  let src_path_abs = Path::new(&judge_opts.src_path)
    .canonicalize()
    .with_context(|| format!("Failed to find source file: {}", judge_opts.src_path))?;

  let nix_expr = format!(
    r#"
    let
      flake = builtins.getFlake ("git+file://" + toString ./.{submodule_arg});
    in
    flake.outputs.hull.{system}.judgeSingleFile flake.outputs.hullProblems.{system}.{}.config.problemAttrs {}"#,
    judge_opts.problem,
    src_path_abs.to_str().unwrap()
  );

  // Execute the nix build command to get the path to the report
  let output = Command::new("nix")
    .arg("build")
    .arg("--impure")
    .arg("--expr")
    .arg(&nix_expr)
    .arg("--print-out-paths")
    .args(&judge_opts.extra_args)
    .stdout(Stdio::piped())
    .stderr(Stdio::inherit())
    .output()
    .context("Failed to execute `nix build` for judging")?;

  if !output.status.success() {
    bail!("Nix build command failed during judging.");
  }

  let report_path_str = String::from_utf8(output.stdout)?.trim().to_string();
  let report_path = Path::new(&report_path_str);

  let report_content = fs::read_to_string(report_path)
    .with_context(|| format!("Failed to read report from {}", report_path.display()))?;

  if judge_opts.json {
    let parsed_json: serde_json::Value = serde_json::from_str(&report_content)?;
    println!("{}", serde_json::to_string(&parsed_json)?);
  } else {
    let report: JudgeReport =
      serde_json::from_str(&report_content).context("Failed to parse judge report JSON")?;
    print_human_readable_report(&report);
  }

  Ok(())
}
