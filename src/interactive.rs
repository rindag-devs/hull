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
use std::io::{stdout, IsTerminal, Write};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::thread;
use std::time::{Duration, Instant};

use console::Style;

use crate::utils::{format_duration_ms, format_size, format_tick, to_title_case};

pub struct LogWriter;

impl Write for LogWriter {
  fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
    let text = String::from_utf8_lossy(buf);
    for line in text.split('\n') {
      if !line.is_empty() {
        log_line(line);
      }
    }
    Ok(buf.len())
  }

  fn flush(&mut self) -> std::io::Result<()> {
    stdout().flush()
  }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InteractiveMode {
  Auto,
  Always,
  Never,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhaseKind {
  NixEval,
  Runtime,
  NixBuild,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum TaskKind {
  Problem,
  Validator,
  Checker,
  Solution,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExecutionState {
  Pending,
  Running,
  Passed,
  Failed,
}

#[derive(Clone, Debug, Default)]
pub struct TaskItemReport {
  pub status: Option<String>,
  pub duration: Option<Duration>,
  pub tick: Option<u64>,
  pub memory: Option<u64>,
  pub score: Option<f64>,
}

#[derive(Clone, Debug)]
pub struct InteractiveSettings {
  pub mode: InteractiveMode,
}

impl Default for InteractiveSettings {
  fn default() -> Self {
    Self {
      mode: InteractiveMode::Auto,
    }
  }
}

impl InteractiveSettings {
  pub fn enabled(self) -> bool {
    match self.mode {
      InteractiveMode::Always => true,
      InteractiveMode::Never => false,
      InteractiveMode::Auto => stdout().is_terminal(),
    }
  }
}

#[derive(Clone, Debug)]
pub struct ProblemProgressHandle {
  inner: Arc<Mutex<InteractiveState>>,
  scope: Option<String>,
}

#[derive(Clone, Debug)]
pub struct TaskHandle {
  inner: Arc<Mutex<InteractiveState>>,
  key: TaskKey,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct TaskKey {
  parent: Option<String>,
  kind: TaskKind,
  name: String,
}

#[derive(Clone, Debug)]
struct PhaseState {
  kind: PhaseKind,
  label: String,
  started_at: Instant,
}

#[derive(Clone, Debug)]
struct InteractiveState {
  enabled: bool,
  title_label: String,
  problem_name: Option<String>,
  phase: Option<PhaseState>,
  tasks: BTreeMap<TaskKey, TaskProgress>,
  last_rendered_lines: usize,
}

#[derive(Clone, Debug)]
struct TaskProgress {
  parent: Option<String>,
  kind: TaskKind,
  name: String,
  score: Option<f64>,
  items: BTreeMap<String, TaskItem>,
}

#[derive(Clone, Debug)]
struct TaskItem {
  name: String,
  state: ExecutionState,
  report: TaskItemReport,
  started_at: Option<Instant>,
  finished_at: Option<Instant>,
}

static SETTINGS: OnceLock<InteractiveSettings> = OnceLock::new();
static LOG_GUARD: OnceLock<Arc<Mutex<()>>> = OnceLock::new();
static ACTIVE_PROGRESS: OnceLock<Arc<Mutex<Option<Weak<Mutex<InteractiveState>>>>>> =
  OnceLock::new();

pub fn init(settings: InteractiveSettings) {
  let _ = SETTINGS.set(settings);
  let _ = LOG_GUARD.set(Arc::new(Mutex::new(())));
  let _ = ACTIVE_PROGRESS.set(Arc::new(Mutex::new(None)));
}

pub fn current_settings() -> InteractiveSettings {
  SETTINGS.get().cloned().unwrap_or_default()
}

pub fn log_line(message: &str) {
  with_output_lock(|| {
    clear_active_render();
    println!("{message}");
    redraw_active_render_locked();
  });
}

pub fn create_problem_progress(problem_name: &str) -> ProblemProgressHandle {
  let inner = Arc::new(Mutex::new(InteractiveState {
    enabled: current_settings().enabled(),
    title_label: "Problem".to_string(),
    problem_name: Some(problem_name.to_string()),
    phase: None,
    tasks: BTreeMap::new(),
    last_rendered_lines: 0,
  }));
  ACTIVE_PROGRESS
    .get_or_init(|| Arc::new(Mutex::new(None)))
    .lock()
    .unwrap()
    .replace(Arc::downgrade(&inner));
  if current_settings().enabled() {
    spawn_refresh_thread(&inner);
  }
  ProblemProgressHandle { inner, scope: None }
}

impl ProblemProgressHandle {
  pub fn disabled() -> Self {
    Self {
      inner: Arc::new(Mutex::new(InteractiveState {
        enabled: false,
        title_label: "Problem".to_string(),
        problem_name: None,
        phase: None,
        tasks: BTreeMap::new(),
        last_rendered_lines: 0,
      })),
      scope: None,
    }
  }

  pub fn enabled(&self) -> bool {
    self.inner.lock().unwrap().enabled
  }

  pub fn reset(&self, problem_name: impl Into<String>) {
    {
      let mut state = self.inner.lock().unwrap();
      state.problem_name = Some(problem_name.into());
      state.phase = None;
      state.tasks.clear();
      state.last_rendered_lines = 0;
    }
    render_handle(&self.inner);
  }

  pub fn set_title(&self, label: impl Into<String>, name: impl Into<String>) {
    {
      let mut state = self.inner.lock().unwrap();
      state.title_label = label.into();
      state.problem_name = Some(name.into());
      state.phase = None;
      state.tasks.clear();
      state.last_rendered_lines = 0;
    }
    render_handle(&self.inner);
  }

  pub fn child_scope(&self, name: impl Into<String>) -> Self {
    Self {
      inner: self.inner.clone(),
      scope: Some(name.into()),
    }
  }

  pub fn set_phase(&self, kind: PhaseKind, label: impl Into<String>) {
    {
      let mut state = self.inner.lock().unwrap();
      state.phase = Some(PhaseState {
        kind,
        label: label.into(),
        started_at: Instant::now(),
      });
    }
    render_handle(&self.inner);
  }

  pub fn finish_phase(&self) {
    {
      let mut state = self.inner.lock().unwrap();
      state.phase = None;
    }
    render_handle(&self.inner);
  }

  pub fn register_group(
    &self,
    kind: TaskKind,
    name: impl Into<String>,
    item_names: impl IntoIterator<Item = impl Into<String>>,
    score: Option<f64>,
  ) -> TaskHandle {
    let name = name.into();
    let key = TaskKey {
      parent: self.scope.clone(),
      kind,
      name: name.clone(),
    };
    let mut items = BTreeMap::new();
    for item_name in item_names {
      let item_name = item_name.into();
      items.insert(
        item_name.clone(),
        TaskItem {
          name: item_name,
          state: ExecutionState::Pending,
          report: TaskItemReport::default(),
          started_at: None,
          finished_at: None,
        },
      );
    }

    {
      let mut state = self.inner.lock().unwrap();
      state.tasks.insert(
        key.clone(),
        TaskProgress {
          parent: self.scope.clone(),
          kind,
          name,
          score,
          items,
        },
      );
    }
    render_handle(&self.inner);
    TaskHandle {
      inner: self.inner.clone(),
      key,
    }
  }

  pub fn println_fallback(&self, line: &str) {
    if !self.enabled() {
      log_line(line);
    }
  }

  pub fn finish(&self) {
    with_output_lock(|| {
      let mut state = self.inner.lock().unwrap();
      if !state.enabled || state.last_rendered_lines == 0 {
        return;
      }

      let lines = render_lines(&state);
      clear_previous_lines(&mut stdout(), state.last_rendered_lines);
      let mut out = stdout();
      for (index, line) in lines.iter().enumerate() {
        if index > 0 {
          let _ = writeln!(out);
        }
        let _ = write!(out, "{line}");
      }
      let _ = writeln!(out);
      let _ = out.flush();
      state.last_rendered_lines = 0;
    });
  }
}

impl TaskHandle {
  pub fn start_item(&self, name: &str) {
    {
      let mut state = self.inner.lock().unwrap();
      if let Some(item) = get_item_mut(&mut state, &self.key, name) {
        item.state = ExecutionState::Running;
        item.started_at = Some(Instant::now());
        item.finished_at = None;
        item.report = TaskItemReport::default();
      }
    }
    render_handle(&self.inner);
  }

  pub fn finish_item(&self, name: &str, status: Option<&str>, success: bool) {
    self.finish_item_with_report(
      name,
      success,
      TaskItemReport {
        status: status.map(ToOwned::to_owned),
        ..TaskItemReport::default()
      },
    );
  }

  pub fn finish_item_with_report(&self, name: &str, success: bool, report: TaskItemReport) {
    {
      let mut state = self.inner.lock().unwrap();
      if let Some(item) = get_item_mut(&mut state, &self.key, name) {
        item.state = if success {
          ExecutionState::Passed
        } else {
          ExecutionState::Failed
        };
        let duration = report
          .duration
          .or_else(|| item.started_at.map(|started_at| started_at.elapsed()));
        item.report = TaskItemReport { duration, ..report };
        item.started_at = None;
        item.finished_at = Some(Instant::now());
      }
    }
    render_handle(&self.inner);
  }

  pub fn set_score(&self, score: f64) {
    {
      let mut state = self.inner.lock().unwrap();
      if let Some(task) = state.tasks.get_mut(&self.key) {
        task.score = Some(score);
      }
    }
    render_handle(&self.inner);
  }
}

fn get_item_mut<'a>(
  state: &'a mut InteractiveState,
  key: &TaskKey,
  name: &str,
) -> Option<&'a mut TaskItem> {
  state
    .tasks
    .get_mut(key)
    .and_then(|task| task.items.get_mut(name))
}

fn render_handle(inner: &Arc<Mutex<InteractiveState>>) {
  with_output_lock(|| {
    render_handle_locked(inner);
  });
}

fn render_handle_locked(inner: &Arc<Mutex<InteractiveState>>) {
  let mut state = inner.lock().unwrap();
  if !state.enabled {
    return;
  }
  let lines = render_lines(&state);
  let mut out = stdout();
  clear_previous_lines(&mut out, state.last_rendered_lines);
  for (index, line) in lines.iter().enumerate() {
    if index > 0 {
      let _ = writeln!(out);
    }
    let _ = write!(out, "{line}");
  }
  let _ = out.flush();
  state.last_rendered_lines = lines.len();
}

fn with_output_lock(f: impl FnOnce()) {
  let guard = LOG_GUARD.get_or_init(|| Arc::new(Mutex::new(()))).clone();
  let _lock = guard.lock().unwrap();
  f();
}

fn clear_active_render() {
  let Some(inner) = active_progress_inner() else {
    return;
  };
  let mut state = inner.lock().unwrap();
  if state.enabled && state.last_rendered_lines > 0 {
    let mut out = stdout();
    clear_previous_lines(&mut out, state.last_rendered_lines);
    let _ = out.flush();
    state.last_rendered_lines = 0;
  }
}

fn redraw_active_render_locked() {
  if let Some(inner) = active_progress_inner() {
    render_handle_locked(&inner);
  }
}

fn active_progress_inner() -> Option<Arc<Mutex<InteractiveState>>> {
  let active = ACTIVE_PROGRESS.get_or_init(|| Arc::new(Mutex::new(None)));
  let mut guard = active.lock().unwrap();
  let upgraded = guard.as_ref().and_then(Weak::upgrade);
  if upgraded.is_none() {
    *guard = None;
  }
  upgraded
}

fn spawn_refresh_thread(inner: &Arc<Mutex<InteractiveState>>) {
  let weak = Arc::downgrade(inner);
  thread::spawn(move || loop {
    thread::sleep(Duration::from_millis(100));
    let Some(inner) = weak.upgrade() else {
      break;
    };
    let should_refresh = {
      let state = inner.lock().unwrap();
      state.enabled && has_running_items(&state)
    };
    if should_refresh {
      render_handle(&inner);
    }
  });
}

fn has_running_items(state: &InteractiveState) -> bool {
  state.tasks.values().any(|task| {
    task
      .items
      .values()
      .any(|item| item.state == ExecutionState::Running)
  })
}

fn clear_previous_lines(out: &mut impl Write, line_count: usize) {
  if line_count == 0 {
    return;
  }

  for index in 0..line_count {
    if index > 0 {
      let _ = write!(out, "\x1b[1A");
    }
    let _ = write!(out, "\r\x1b[2K");
  }
}

fn render_lines(state: &InteractiveState) -> Vec<String> {
  let mut lines = Vec::new();
  if let Some(problem_name) = &state.problem_name {
    lines.push(format!(
      "{} {}",
      Style::new().bold().apply_to(&state.title_label),
      Style::new().yellow().bold().apply_to(problem_name)
    ));
  }

  if let Some(phase) = &state.phase {
    lines.push(format!(
      "{} {} {}",
      Style::new().cyan().apply_to("├─"),
      Style::new().bold().apply_to(phase_label(phase.kind)),
      Style::new().dim().apply_to(format!(
        "{} ({})",
        phase.label,
        format_duration_ms(phase.started_at.elapsed())
      ))
    ));
  }

  let root_tasks = state
    .tasks
    .values()
    .filter(|task| task.parent.is_none())
    .collect::<Vec<_>>();
  let total = root_tasks.len();
  for (index, task) in root_tasks.iter().enumerate() {
    let is_last = index + 1 == total;
    lines.push(render_task_line(state, task, is_last));
    lines.extend(render_task_children(state, task, is_last, ""));
  }
  lines
}

fn render_task_children(
  state: &InteractiveState,
  task: &TaskProgress,
  parent_is_last: bool,
  ancestor_prefix: &str,
) -> Vec<String> {
  let mut lines = Vec::new();
  let prefix = format!(
    "{}{}",
    ancestor_prefix,
    if parent_is_last { "  " } else { "│ " }
  );

  let child_tasks = state
    .tasks
    .values()
    .filter(|candidate| {
      candidate.parent.as_deref() == Some(task.name.as_str())
        || candidate
          .parent
          .as_ref()
          .is_some_and(|parent| task.items.contains_key(parent))
    })
    .collect::<Vec<_>>();

  if !child_tasks.is_empty() {
    let total = child_tasks.len();
    for (index, child) in child_tasks.iter().enumerate() {
      let is_last_child = index + 1 == total;
      let branch = if is_last_child { "└─" } else { "├─" };
      lines.push(format!(
        "{}{} {}",
        prefix,
        Style::new().cyan().apply_to(branch),
        render_task_summary(state, child)
      ));
      lines.extend(render_task_children(state, child, is_last_child, &prefix));
    }
    return lines;
  }

  lines.extend(render_recent_items(
    state,
    task,
    parent_is_last,
    ancestor_prefix,
  ));
  lines
}

fn render_task_summary(state: &InteractiveState, task: &TaskProgress) -> String {
  let (done, running, pending, failed) = task_counts(state, task);
  let mut line = format!(
    "{} {} {}",
    Style::new().bold().apply_to(task_label(task.kind)),
    Style::new().yellow().bold().apply_to(&task.name),
    render_counter(done, running, pending, failed)
  );
  if let Some(score) = task.score {
    line.push(' ');
    line.push_str(
      &Style::new()
        .green()
        .apply_to(format!("{score:.3} / 1.000 pts"))
        .to_string(),
    );
  }
  line
}

fn render_task_line(state: &InteractiveState, task: &TaskProgress, is_last: bool) -> String {
  let branch = if is_last { "└─" } else { "├─" };
  format!(
    "{} {}",
    Style::new().cyan().apply_to(branch),
    render_task_summary(state, task)
  )
}

fn render_recent_items(
  state: &InteractiveState,
  task: &TaskProgress,
  parent_is_last: bool,
  ancestor_prefix: &str,
) -> Vec<String> {
  let (_, running_count, pending_count, failed_count) = task_counts(state, task);
  if pending_count == 0 && running_count == 0 && failed_count == 0 {
    return Vec::new();
  }

  let mut running = Vec::new();
  let mut failed = Vec::new();
  let mut finished = Vec::new();
  let mut pending_count = 0usize;

  for item in task.items.values() {
    match item.state {
      ExecutionState::Running => running.push(item),
      ExecutionState::Failed => failed.push(item),
      ExecutionState::Passed => finished.push(item),
      ExecutionState::Pending => pending_count += 1,
    }
  }

  failed.sort_by_key(|item| item.finished_at.unwrap_or_else(Instant::now));
  failed.reverse();
  finished.sort_by_key(|item| item.finished_at.unwrap_or_else(Instant::now));
  finished.reverse();

  let mut visible = Vec::new();
  visible.extend(running);
  visible.extend(failed);
  if visible.len() < 4 {
    visible.extend(finished.into_iter().take(4 - visible.len()));
  }
  if visible.len() > 4 {
    visible.truncate(4);
  }

  if visible.is_empty() && pending_count == 0 {
    return Vec::new();
  }

  let prefix = format!(
    "{}{}",
    ancestor_prefix,
    if parent_is_last { "  " } else { "│ " }
  );
  let mut lines = Vec::new();
  for (index, item) in visible.iter().enumerate() {
    let last_child = index + 1 == visible.len() && pending_count == 0;
    let branch = if last_child { "└─" } else { "├─" };
    lines.push(format!(
      "{}{} {}",
      prefix,
      Style::new().cyan().apply_to(branch),
      render_item_line(item)
    ));
  }

  if pending_count > 0 {
    lines.push(format!(
      "{}{} {}",
      prefix,
      Style::new().cyan().apply_to("└─"),
      Style::new()
        .dim()
        .apply_to(format!("{pending_count} more pending"))
    ));
  }

  lines
}

fn render_item_line(item: &TaskItem) -> String {
  let marker = match item.state {
    ExecutionState::Pending => Style::new().dim().apply_to("P").to_string(),
    ExecutionState::Running => Style::new().blue().bold().apply_to("R").to_string(),
    ExecutionState::Passed => Style::new().green().bold().apply_to("D").to_string(),
    ExecutionState::Failed => Style::new().red().bold().apply_to("D").to_string(),
  };
  let name = Style::new().yellow().apply_to(&item.name).to_string();
  let status = item
    .report
    .status
    .as_ref()
    .map(|status| {
      let style = match item.state {
        ExecutionState::Pending => Style::new().dim(),
        ExecutionState::Running => Style::new().blue(),
        ExecutionState::Passed => Style::new().green(),
        ExecutionState::Failed => Style::new().red(),
      };
      style.apply_to(to_title_case(status)).to_string()
    })
    .unwrap_or_else(|| match item.state {
      ExecutionState::Pending => Style::new().dim().apply_to("Pending").to_string(),
      ExecutionState::Running => Style::new().blue().apply_to("Running").to_string(),
      ExecutionState::Passed => Style::new().green().apply_to("Accepted").to_string(),
      ExecutionState::Failed => Style::new().red().apply_to("Failed").to_string(),
    });

  let elapsed = item
    .report
    .duration
    .or_else(|| item.started_at.map(|started_at| started_at.elapsed()));
  let mut details = Vec::new();
  if let Some(duration) = elapsed {
    details.push(
      Style::new()
        .dim()
        .apply_to(format_duration_ms(duration))
        .to_string(),
    );
  }
  if let Some(score) = item.report.score {
    details.push(
      Style::new()
        .green()
        .apply_to(format!("{score:.3} pts"))
        .to_string(),
    );
  }
  if let Some(tick) = item.report.tick {
    details.push(
      Style::new()
        .dim()
        .apply_to(format!("tick {}", format_tick(tick)))
        .to_string(),
    );
  }
  if let Some(memory) = item.report.memory {
    details.push(
      Style::new()
        .dim()
        .apply_to(format!("mem {}", format_size(memory)))
        .to_string(),
    );
  }

  if details.is_empty() {
    format!("[{marker}] {name} {status}")
  } else {
    format!("[{marker}] {name} {status} - {}", details.join(" - "))
  }
}

fn render_counter(done: usize, running: usize, pending: usize, failed: usize) -> String {
  let mut parts = vec![
    format!("{} {done}", Style::new().green().apply_to("D")),
    format!("{} {running}", Style::new().blue().apply_to("R")),
    format!("{} {pending}", Style::new().dim().apply_to("P")),
  ];
  if failed > 0 {
    parts.push(format!("{} {failed}", Style::new().red().apply_to("F")));
  }
  format!("[{}]", parts.join(" / "))
}

fn task_counts(state: &InteractiveState, task: &TaskProgress) -> (usize, usize, usize, usize) {
  let child_tasks = state
    .tasks
    .values()
    .filter(|candidate| {
      candidate.parent.as_deref() == Some(task.name.as_str())
        || candidate
          .parent
          .as_ref()
          .is_some_and(|parent| task.items.contains_key(parent))
    })
    .collect::<Vec<_>>();
  if !child_tasks.is_empty() {
    return child_tasks.into_iter().fold((0, 0, 0, 0), |acc, child| {
      let counts = task_counts(state, child);
      (
        acc.0 + counts.0,
        acc.1 + counts.1,
        acc.2 + counts.2,
        acc.3 + counts.3,
      )
    });
  }

  let mut done = 0;
  let mut running = 0;
  let mut pending = 0;
  let mut failed = 0;
  for item in task.items.values() {
    match item.state {
      ExecutionState::Pending => pending += 1,
      ExecutionState::Running => running += 1,
      ExecutionState::Passed => done += 1,
      ExecutionState::Failed => {
        done += 1;
        failed += 1;
      }
    }
  }
  (done, running, pending, failed)
}

fn task_label(kind: TaskKind) -> &'static str {
  match kind {
    TaskKind::Problem => "Problems",
    TaskKind::Validator => "Validator tests",
    TaskKind::Checker => "Checker tests",
    TaskKind::Solution => "Solution",
  }
}

fn phase_label(kind: PhaseKind) -> &'static str {
  match kind {
    PhaseKind::NixEval => "Nix eval",
    PhaseKind::Runtime => "Runtime",
    PhaseKind::NixBuild => "Nix build",
  }
}
