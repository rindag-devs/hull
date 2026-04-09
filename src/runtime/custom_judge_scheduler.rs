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

use std::collections::{BTreeMap, BTreeSet};

use anyhow::{Result, anyhow};
use rayon::prelude::*;

use super::analysis::install_with_pool;
use super::types::{JudgeReport, SubtaskSpec};
use crate::platform::default_parallelism;

type TestCaseTraitsMap = BTreeMap<String, BTreeMap<String, bool>>;

#[derive(Clone, Debug, PartialEq, Eq)]
enum TestCaseState {
  Pending,
  Running,
  Done,
}

#[derive(Clone, Debug)]
struct SubtaskSchedule {
  test_case_names: Vec<String>,
  scoring_method: String,
  next_index: usize,
  skipped: bool,
}

#[derive(Clone, Debug)]
struct SchedulerState {
  test_case_states: BTreeMap<String, TestCaseState>,
  subtask_schedules: Vec<SubtaskSchedule>,
}

#[derive(Clone, Debug)]
/// One testcase made available to the custom-judge scheduler.
pub struct ScheduledTestCase {
  /// Stable testcase name used for dependency tracking and result aggregation.
  pub name: String,
  /// Runtime traits used to decide which subtasks this testcase belongs to.
  pub traits: BTreeMap<String, bool>,
}

#[derive(Clone, Debug)]
/// Progress snapshot emitted by the custom-judge scheduler.
pub struct SchedulerProgress {
  /// Number of testcases that have already finished or become irrelevant.
  pub completed: usize,
  /// Number of testcases currently being executed in the active batch.
  pub running: usize,
  /// Total number of known testcases before subtask pruning.
  pub total: usize,
}

/// Executes custom-judge testcases with UOJ-style subtask ordering and `min` short-circuiting.
///
/// The scheduler stays independent from any specific adapter. Callers provide testcase metadata,
/// subtask definitions, a worker count, and an evaluation closure for one testcase name.
pub fn execute_scheduled_test_cases<F>(
  test_cases: &[ScheduledTestCase],
  subtasks: &[SubtaskSpec],
  threads: usize,
  mut progress: impl FnMut(SchedulerProgress) -> Result<()>,
  evaluate_test_case: F,
) -> Result<BTreeMap<String, JudgeReport>>
where
  F: Fn(&str) -> Result<JudgeReport> + Sync,
{
  let total = test_cases.len();
  let thread_count = normalize_thread_count(threads);
  let runtime_traits = collect_runtime_traits(test_cases);
  let mut scheduler = SchedulerState::new(test_cases, subtasks, &runtime_traits);
  let mut reports = BTreeMap::new();

  progress(SchedulerProgress {
    completed: 0,
    running: 0,
    total,
  })?;

  while !scheduler.is_finished() {
    let ready_test_case_names = scheduler.collect_ready_test_case_names(thread_count);
    if ready_test_case_names.is_empty() {
      scheduler.mark_irrelevant_pending_test_cases_done();
      if scheduler.is_finished() {
        break;
      }
      return Err(anyhow!(
        "custom judge scheduler reached a dead end with unfinished active subtasks"
      ));
    }

    scheduler.mark_running(&ready_test_case_names);
    progress(SchedulerProgress {
      completed: scheduler.completed_count(),
      running: ready_test_case_names.len(),
      total,
    })?;

    let executions =
      evaluate_test_case_batch(&ready_test_case_names, thread_count, &evaluate_test_case)?;

    scheduler.finish_batch(&ready_test_case_names, &executions);
    reports.extend(executions);
    scheduler.mark_irrelevant_pending_test_cases_done();

    progress(SchedulerProgress {
      completed: scheduler.completed_count(),
      running: 0,
      total,
    })?;
  }

  Ok(reports)
}

/// Returns true when the testcase traits satisfy every trait required by the subtask.
pub fn test_case_matches_traits(
  test_case_name: &str,
  required_traits: &BTreeMap<String, bool>,
  runtime_traits: &BTreeMap<String, BTreeMap<String, bool>>,
) -> bool {
  required_traits.iter().all(|(name, value)| {
    runtime_traits
      .get(test_case_name)
      .and_then(|traits| traits.get(name))
      == Some(value)
  })
}

/// Collects testcase traits into the lookup shape expected by scheduling and subtask aggregation.
pub fn collect_runtime_traits(
  test_cases: &[ScheduledTestCase],
) -> BTreeMap<String, BTreeMap<String, bool>> {
  test_cases
    .iter()
    .map(|test_case| (test_case.name.clone(), test_case.traits.clone()))
    .collect()
}

fn evaluate_test_case_batch<F>(
  test_case_names: &[String],
  thread_count: usize,
  evaluate_test_case: &F,
) -> Result<BTreeMap<String, JudgeReport>>
where
  F: Fn(&str) -> Result<JudgeReport> + Sync,
{
  let evaluate = || {
    test_case_names
      .par_iter()
      .map(|test_case_name| Ok((test_case_name.clone(), evaluate_test_case(test_case_name)?)))
      .collect::<Result<BTreeMap<_, _>>>()
  };

  install_with_pool(
    super::types::RuntimeOptions::new(Some(thread_count)),
    evaluate,
  )
}

fn normalize_thread_count(threads: usize) -> usize {
  if threads > 0 {
    threads
  } else {
    default_parallelism()
  }
}

impl SchedulerState {
  fn new(
    test_cases: &[ScheduledTestCase],
    subtasks: &[SubtaskSpec],
    runtime_traits: &TestCaseTraitsMap,
  ) -> Self {
    let test_case_states = test_cases
      .iter()
      .map(|test_case| (test_case.name.clone(), TestCaseState::Pending))
      .collect::<BTreeMap<_, _>>();
    let subtask_schedules = subtasks
      .iter()
      .map(|subtask| SubtaskSchedule {
        test_case_names: test_cases
          .iter()
          .filter(|test_case| {
            test_case_matches_traits(&test_case.name, &subtask.traits, runtime_traits)
          })
          .map(|test_case| test_case.name.clone())
          .collect(),
        scoring_method: subtask.scoring_method.clone(),
        next_index: 0,
        skipped: false,
      })
      .collect();
    Self {
      test_case_states,
      subtask_schedules,
    }
  }

  fn is_finished(&self) -> bool {
    self
      .subtask_schedules
      .iter()
      .all(|schedule| schedule.skipped || schedule.next_index >= schedule.test_case_names.len())
  }

  fn completed_count(&self) -> usize {
    self
      .test_case_states
      .values()
      .filter(|state| **state == TestCaseState::Done)
      .count()
  }

  fn collect_ready_test_case_names(&self, limit: usize) -> Vec<String> {
    if limit == 0 {
      return Vec::new();
    }

    let mut ready = Vec::new();
    let mut seen = BTreeSet::new();
    let mut scan_indices = self
      .subtask_schedules
      .iter()
      .map(|schedule| schedule.next_index)
      .collect::<Vec<_>>();

    while ready.len() < limit {
      let mut made_progress = false;
      for (subtask_index, schedule) in self.subtask_schedules.iter().enumerate() {
        if schedule.skipped {
          continue;
        }

        while scan_indices[subtask_index] < schedule.test_case_names.len() {
          let test_case_name = &schedule.test_case_names[scan_indices[subtask_index]];
          scan_indices[subtask_index] += 1;

          let Some(state) = self.test_case_states.get(test_case_name) else {
            continue;
          };
          if *state != TestCaseState::Pending {
            continue;
          }

          if seen.insert(test_case_name.clone()) {
            ready.push(test_case_name.clone());
          }
          made_progress = true;
          break;
        }

        if ready.len() >= limit {
          break;
        }
      }

      if !made_progress {
        break;
      }
    }

    ready
  }

  fn mark_running(&mut self, test_case_names: &[String]) {
    for test_case_name in test_case_names {
      self
        .test_case_states
        .insert(test_case_name.clone(), TestCaseState::Running);
    }
  }

  fn finish_batch(
    &mut self,
    scheduled_test_case_names: &[String],
    executions: &BTreeMap<String, JudgeReport>,
  ) {
    for test_case_name in scheduled_test_case_names {
      self
        .test_case_states
        .insert(test_case_name.clone(), TestCaseState::Done);
    }

    for schedule in &mut self.subtask_schedules {
      if schedule.skipped {
        continue;
      }
      while let Some(test_case_name) = schedule.current_test_case_name().cloned() {
        let Some(state) = self.test_case_states.get(&test_case_name) else {
          break;
        };
        if *state != TestCaseState::Done {
          break;
        }
        schedule.next_index += 1;
        if schedule.scoring_method == "min"
          && executions
            .get(&test_case_name)
            .is_some_and(|report| report.score <= 0.0)
        {
          schedule.skipped = true;
          break;
        }
      }
    }
  }

  fn mark_irrelevant_pending_test_cases_done(&mut self) {
    let active_test_case_names = self
      .subtask_schedules
      .iter()
      .filter(|schedule| !schedule.skipped)
      .flat_map(|schedule| schedule.test_case_names.iter().skip(schedule.next_index))
      .cloned()
      .collect::<BTreeSet<_>>();

    for (test_case_name, state) in &mut self.test_case_states {
      if *state == TestCaseState::Pending && !active_test_case_names.contains(test_case_name) {
        *state = TestCaseState::Done;
      }
    }
  }
}

impl SubtaskSchedule {
  fn current_test_case_name(&self) -> Option<&String> {
    self.test_case_names.get(self.next_index)
  }
}
