use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use clap::Parser;
use comfy_table::presets::UTF8_FULL;
use comfy_table::{Cell, Color, Table};
use serde::Deserialize;
use tracing::info;

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
  tick: u64,
  memory: u64,
}

#[derive(Deserialize)]
struct FlakeMetadata {
  url: String,
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
  test_case_table.set_header(vec!["Name", "Status", "Score", "Tick", "Memory"]);

  // Sort test cases by name for consistent output
  let mut sorted_test_cases: Vec<_> = report.test_case_results.iter().collect();
  sorted_test_cases.sort_by_key(|(k, _)| *k);

  for (name, case) in sorted_test_cases {
    let title_case_status = to_title_case(&case.status);
    let colored_status = colorize_status(&case.status, &title_case_status);
    let score_str = format!("{:.3}", case.score);
    let tick_str = tick_string(case.tick);
    let memory_str = size_string(case.memory);

    test_case_table.add_row(vec![
      Cell::new(name),
      colored_status,
      Cell::new(score_str),
      Cell::new(tick_str),
      Cell::new(memory_str),
    ]);
  }
  println!("\nTest Case Details:");
  println!("{test_case_table}");
}

fn tick_string(tick: u64) -> String {
  const THRESHOLD: u64 = 100_000;

  if tick < THRESHOLD {
    tick.to_string()
  } else {
    format!("{:.3e}", tick as f64)
  }
}

fn size_string(memory: u64) -> String {
  const KIB: u64 = 1024;
  const MIB: u64 = 1024 * KIB;
  const GIB: u64 = 1024 * MIB;
  const TIB: u64 = 1024 * GIB;

  if memory < KIB {
    format!("{} Bytes", memory)
  } else if memory < MIB {
    let kib_value = memory as f64 / KIB as f64;
    format!("{:.3} KiB", kib_value)
  } else if memory < GIB {
    let mib_value = memory as f64 / MIB as f64;
    format!("{:.3} MiB", mib_value)
  } else if memory < TIB {
    let gib_value = memory as f64 / GIB as f64;
    format!("{:.3} GiB", gib_value)
  } else {
    let tib_value = memory as f64 / TIB as f64;
    format!("{:.3} TiB", tib_value)
  }
}

fn get_current_system() -> Result<String> {
  let output = Command::new("nix")
    .args(["eval", "--raw", "nixpkgs#system"])
    .output()?;
  Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Get the flake URL for the current directory by running `nix flake metadata`.
fn get_flake_url() -> Result<String> {
  let output = Command::new("nix")
    .args(["flake", "metadata", ".", "--json"])
    .output()
    .context("Failed to execute `nix flake metadata`")?;

  if !output.status.success() {
    let stderr = String::from_utf8_lossy(&output.stderr);
    bail!("Failed to get flake metadata. Stderr:\n{}", stderr.trim());
  }

  let metadata_str = String::from_utf8(output.stdout)
    .context("Failed to parse `nix flake metadata` output as UTF-8")?;

  let metadata: FlakeMetadata = serde_json::from_str(&metadata_str)
    .context("Failed to parse JSON from `nix flake metadata`")?;

  Ok(metadata.url)
}

pub fn run(judge_opts: &JudgeOpts) -> Result<()> {
  let system = judge_opts.system.clone().unwrap_or(
    get_current_system().context("Failed to determine current system using `nix eval`")?,
  );

  // Get the flake URL dynamically instead of assuming a git repository.
  let flake_url =
    get_flake_url().context("Could not determine the flake URL for the current project")?;

  // The submodule argument is now a URL query parameter.
  let submodule_query = if judge_opts.submodules {
    "?submodules=1"
  } else {
    ""
  };

  let src_path_abs = Path::new(&judge_opts.src_path)
    .canonicalize()
    .with_context(|| format!("Failed to find source file: {}", judge_opts.src_path))?;

  // Construct the final flake reference and the Nix expression.
  let final_flake_ref = format!("{}{}", flake_url, submodule_query);

  info!("Flake reference: {}", &final_flake_ref);

  let nix_expr = format!(
    r#"
    let
      flake = builtins.getFlake "{final_flake_ref}";
    in
    flake.outputs.hull.{system}.judgeSingleFile flake.outputs.hullProblems.{system}.{}.config.problemAttrs {}"#,
    judge_opts.problem,
    src_path_abs.to_str().unwrap()
  );

  // Execute the nix build command to get the path to the report
  let mut nix_build = Command::new("nix")
    .arg("build")
    .arg("--impure")
    .arg("--expr")
    .arg(&nix_expr)
    .arg("--print-out-paths")
    .arg("--log-format")
    .arg("internal-json") // Corrected from "internal-jso"
    .arg("-v")
    .args(&judge_opts.extra_args)
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .context("Failed to execute `nix build` for judging")?;

  // Take the stderr handle from the nix_build process. This allows us to pipe it
  // to another process while still being able to call `wait_with_output` on nix_build.
  let nix_stderr = nix_build
    .stderr
    .take()
    .context("Failed to capture stderr from nix build process")?;

  // Spawn the `nom` process to format the nix build logs.
  let mut nom_process = Command::new("nom")
    .arg("--json")
    .stdin(nix_stderr)
    .stdout(Stdio::inherit())
    .stderr(Stdio::inherit())
    .spawn()
    .context("Failed to spawn `nom` log processor")?;

  // Wait for the main `nix build` command to finish. Its output contains the path
  // to the result, and its completion will close the pipe to `nom`.
  let output = nix_build
    .wait_with_output()
    .context("Failed to wait for nix build process")?;

  // Wait for the `nom` log processor to finish.
  let nom_status = nom_process
    .wait()
    .context("Failed to wait for `nom` log processor")?;

  // Check if the log processor itself ran successfully.
  if !nom_status.success() {
    bail!(
      "Log processor `nom` failed with exit code: {:?}",
      nom_status
    );
  }

  // Check if the nix build command was successful. If not, the formatted logs
  // from `nom` should have already been printed to the user's terminal.
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
