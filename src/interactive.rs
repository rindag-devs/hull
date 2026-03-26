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
use std::io::{IsTerminal, Write, stdout};
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
  NixPrepare,
  Runtime,
  NixBuild,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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
  task_id: String,
}

#[derive(Clone, Debug)]
struct InteractiveState {
  enabled: bool,
  title_label: String,
  title_name: Option<String>,
  phase: Option<PhaseState>,
  roots: BTreeMap<String, TreeNode>,
  last_rendered_lines: usize,
}

#[derive(Clone, Debug)]
struct PhaseState {
  kind: PhaseKind,
  label: String,
  started_at: Instant,
}

#[derive(Clone, Debug)]
struct TreeNode {
  id: String,
  kind: NodeKind,
  label: String,
  state: ExecutionState,
  score: Option<f64>,
  report: TaskItemReport,
  started_at: Option<Instant>,
  finished_at: Option<Instant>,
  children: BTreeMap<String, TreeNode>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NodeKind {
  Group(TaskKind),
  Item,
}

static SETTINGS: OnceLock<InteractiveSettings> = OnceLock::new();
static OUTPUT_LOCK: OnceLock<Arc<Mutex<()>>> = OnceLock::new();
static ACTIVE_PROGRESS: OnceLock<Arc<Mutex<Option<Weak<Mutex<InteractiveState>>>>>> =
  OnceLock::new();

pub fn init(settings: InteractiveSettings) {
  let _ = SETTINGS.set(settings);
  let _ = OUTPUT_LOCK.set(Arc::new(Mutex::new(())));
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

pub fn suspend_live_render() {
  with_output_lock(detach_active_render);
}

pub fn resume_live_render(separate_line: bool) {
  with_output_lock(|| {
    if separate_line {
      println!();
    }
    redraw_active_render_locked();
  });
}

pub fn create_problem_progress(name: &str) -> ProblemProgressHandle {
  let inner = Arc::new(Mutex::new(InteractiveState {
    enabled: current_settings().enabled(),
    title_label: "Problem".to_string(),
    title_name: Some(name.to_string()),
    phase: None,
    roots: BTreeMap::new(),
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
        title_name: None,
        phase: None,
        roots: BTreeMap::new(),
        last_rendered_lines: 0,
      })),
      scope: None,
    }
  }

  pub fn enabled(&self) -> bool {
    self.inner.lock().unwrap().enabled
  }

  pub fn reset(&self, name: impl Into<String>) {
    self.set_title("Problem", name);
  }

  pub fn set_title(&self, label: impl Into<String>, name: impl Into<String>) {
    {
      let mut state = self.inner.lock().unwrap();
      state.title_label = label.into();
      state.title_name = Some(name.into());
      state.phase = None;
      state.roots.clear();
      state.last_rendered_lines = 0;
    }
    render(&self.inner);
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
    render(&self.inner);
  }

  pub fn finish_phase(&self) {
    {
      let mut state = self.inner.lock().unwrap();
      state.phase = None;
      state.roots.clear();
    }
    render(&self.inner);
  }

  pub fn register_group(
    &self,
    kind: TaskKind,
    name: impl Into<String>,
    item_names: impl IntoIterator<Item = impl Into<String>>,
    score: Option<f64>,
  ) -> TaskHandle {
    let name = name.into();
    let task_id = scoped_id(self.scope.as_deref(), &name);
    let node = TreeNode {
      id: task_id.clone(),
      kind: NodeKind::Group(kind),
      label: name,
      state: ExecutionState::Pending,
      score,
      report: TaskItemReport::default(),
      started_at: None,
      finished_at: None,
      children: item_names
        .into_iter()
        .map(|item_name| {
          let item_name = item_name.into();
          (
            item_name.clone(),
            TreeNode {
              id: scoped_id(Some(&task_id), &item_name),
              kind: NodeKind::Item,
              label: item_name,
              state: ExecutionState::Pending,
              score: None,
              report: TaskItemReport::default(),
              started_at: None,
              finished_at: None,
              children: BTreeMap::new(),
            },
          )
        })
        .collect(),
    };

    {
      let mut state = self.inner.lock().unwrap();
      insert_group(&mut state, self.scope.as_deref(), node);
    }
    render(&self.inner);

    TaskHandle {
      inner: self.inner.clone(),
      task_id,
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

  pub fn start_item(&self, name: &str) {
    update_item(&self.inner, &self.task_id, name, |item| {
      item.state = ExecutionState::Running;
      item.report = TaskItemReport::default();
      item.started_at = Some(Instant::now());
      item.finished_at = None;
    });
  }

  pub fn finish_item_with_report(&self, name: &str, success: bool, report: TaskItemReport) {
    update_item(&self.inner, &self.task_id, name, |item| {
      item.state = if success {
        ExecutionState::Passed
      } else {
        ExecutionState::Failed
      };
      let duration = report
        .duration
        .or_else(|| item.started_at.map(|started| started.elapsed()));
      item.report = TaskItemReport { duration, ..report };
      item.started_at = None;
      item.finished_at = Some(Instant::now());
    });
  }

  pub fn set_score(&self, score: f64) {
    {
      let mut state = self.inner.lock().unwrap();
      if let Some(node) = find_node_mut_by_id(&mut state.roots, &self.task_id) {
        node.score = Some(score);
      }
    }
    render(&self.inner);
  }
}

fn insert_group(state: &mut InteractiveState, scope: Option<&str>, node: TreeNode) {
  if let Some(scope) = scope {
    if let Some(parent_item) = find_item_mut_by_label(&mut state.roots, scope) {
      parent_item.children.insert(node.id.clone(), node);
      return;
    }
  }
  state.roots.insert(node.id.clone(), node);
}

fn update_item(
  inner: &Arc<Mutex<InteractiveState>>,
  task_id: &str,
  item_name: &str,
  update: impl FnOnce(&mut TreeNode),
) {
  {
    let mut state = inner.lock().unwrap();
    if let Some(task) = find_node_mut_by_id(&mut state.roots, task_id) {
      if let Some(item) = task.children.get_mut(item_name) {
        update(item);
      }
    }
  }
  render(inner);
}

fn find_node_mut_by_id<'a>(
  roots: &'a mut BTreeMap<String, TreeNode>,
  id: &str,
) -> Option<&'a mut TreeNode> {
  for node in roots.values_mut() {
    if node.id == id {
      return Some(node);
    }
    if let Some(found) = find_node_mut_by_id(&mut node.children, id) {
      return Some(found);
    }
  }
  None
}

fn find_item_mut_by_label<'a>(
  roots: &'a mut BTreeMap<String, TreeNode>,
  label: &str,
) -> Option<&'a mut TreeNode> {
  for node in roots.values_mut() {
    if node.kind == NodeKind::Item && node.label == label {
      return Some(node);
    }
    if let Some(found) = find_item_mut_by_label(&mut node.children, label) {
      return Some(found);
    }
  }
  None
}

fn scoped_id(scope: Option<&str>, name: &str) -> String {
  match scope {
    Some(scope) => format!("{scope}/{name}"),
    None => name.to_string(),
  }
}

fn render(inner: &Arc<Mutex<InteractiveState>>) {
  with_output_lock(|| render_locked(inner));
}

fn render_locked(inner: &Arc<Mutex<InteractiveState>>) {
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
  if !lines.is_empty() {
    let _ = writeln!(out);
  }
  let _ = out.flush();
  state.last_rendered_lines = if lines.is_empty() { 0 } else { lines.len() + 1 };
}

fn render_lines(state: &InteractiveState) -> Vec<String> {
  let mut lines = Vec::new();

  if let Some(name) = &state.title_name {
    lines.push(format!(
      "{} {}",
      Style::new().bold().apply_to(&state.title_label),
      Style::new().yellow().bold().apply_to(name)
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

  let roots = state.roots.values().collect::<Vec<_>>();
  for (index, node) in roots.iter().enumerate() {
    let is_last = index + 1 == roots.len();
    lines.extend(render_node_tree(node, is_last, ""));
  }

  lines
}

fn render_node_tree(node: &TreeNode, is_last: bool, prefix: &str) -> Vec<String> {
  let branch = if is_last { "└─" } else { "├─" };
  let mut lines = vec![format!(
    "{}{} {}",
    prefix,
    Style::new().cyan().apply_to(branch),
    render_node_summary(node)
  )];

  let child_prefix = format!("{}{}", prefix, if is_last { "  " } else { "│ " });
  let visible_children = visible_children(node);
  for (index, child) in visible_children.iter().enumerate() {
    let child_is_last = index + 1 == visible_children.len();
    lines.extend(render_node_tree(child, child_is_last, &child_prefix));
  }

  if should_show_pending_suffix(node, visible_children.len()) {
    lines.push(format!(
      "{}{} {}",
      child_prefix,
      Style::new().cyan().apply_to("└─"),
      Style::new().dim().apply_to(format!(
        "{} more pending",
        hidden_pending_count(node, visible_children.len())
      ))
    ));
  }

  lines
}

fn render_node_summary(node: &TreeNode) -> String {
  match node.kind {
    NodeKind::Group(kind) => {
      let summary = summary_counts(node);
      let mut text = format!(
        "{} {} {}",
        Style::new().bold().apply_to(task_label(kind)),
        Style::new().yellow().bold().apply_to(&node.label),
        render_counter(
          summary.done,
          summary.running,
          summary.pending,
          summary.failed
        )
      );
      if let Some(score) = node.score {
        text.push(' ');
        text.push_str(
          &Style::new()
            .green()
            .apply_to(format!("{score:.3} / 1.000 pts"))
            .to_string(),
        );
      }
      text
    }
    NodeKind::Item => render_item_summary(node),
  }
}

fn render_item_summary(node: &TreeNode) -> String {
  if node.children.is_empty() {
    let marker = match node.state {
      ExecutionState::Pending => Style::new().dim().apply_to("P").to_string(),
      ExecutionState::Running => Style::new().blue().bold().apply_to("R").to_string(),
      ExecutionState::Passed => Style::new().green().bold().apply_to("D").to_string(),
      ExecutionState::Failed => Style::new().red().bold().apply_to("D").to_string(),
    };
    let name = Style::new().yellow().apply_to(&node.label).to_string();
    let status = status_text(node);
    let details = detail_parts(node);
    if details.is_empty() {
      format!("[{marker}] {name} {status}")
    } else {
      format!("[{marker}] {name} {status} - {}", details.join(" - "))
    }
  } else {
    let summary = summary_counts(node);
    format!(
      "{} {} {}",
      Style::new().bold().apply_to("Problem"),
      Style::new().yellow().bold().apply_to(&node.label),
      render_counter(
        summary.done,
        summary.running,
        summary.pending,
        summary.failed
      )
    )
  }
}

fn status_text(node: &TreeNode) -> String {
  node
    .report
    .status
    .as_ref()
    .map(|status| {
      let style = match node.state {
        ExecutionState::Pending => Style::new().dim(),
        ExecutionState::Running => Style::new().blue(),
        ExecutionState::Passed => Style::new().green(),
        ExecutionState::Failed => Style::new().red(),
      };
      style.apply_to(to_title_case(status)).to_string()
    })
    .unwrap_or_else(|| match node.state {
      ExecutionState::Pending => Style::new().dim().apply_to("Pending").to_string(),
      ExecutionState::Running => Style::new().blue().apply_to("Running").to_string(),
      ExecutionState::Passed => Style::new().green().apply_to("Accepted").to_string(),
      ExecutionState::Failed => Style::new().red().apply_to("Failed").to_string(),
    })
}

fn detail_parts(node: &TreeNode) -> Vec<String> {
  let mut details = Vec::new();
  if let Some(duration) = node
    .report
    .duration
    .or_else(|| node.started_at.map(|started| started.elapsed()))
  {
    details.push(
      Style::new()
        .dim()
        .apply_to(format_duration_ms(duration))
        .to_string(),
    );
  }
  if let Some(score) = node.report.score {
    details.push(
      Style::new()
        .green()
        .apply_to(format!("{score:.3} pts"))
        .to_string(),
    );
  }
  if let Some(tick) = node.report.tick {
    details.push(
      Style::new()
        .dim()
        .apply_to(format!("tick {}", format_tick(tick)))
        .to_string(),
    );
  }
  if let Some(memory) = node.report.memory {
    details.push(
      Style::new()
        .dim()
        .apply_to(format!("mem {}", format_size(memory)))
        .to_string(),
    );
  }
  details
}

fn visible_children(node: &TreeNode) -> Vec<&TreeNode> {
  let summary = summary_counts(node);
  if node.kind == NodeKind::Group(TaskKind::Solution)
    && summary.pending == 0
    && summary.running == 0
    && summary.failed == 0
  {
    return Vec::new();
  }
  if matches!(
    node.kind,
    NodeKind::Group(TaskKind::Validator | TaskKind::Checker)
  ) && summary.pending == 0
    && summary.running == 0
    && summary.failed == 0
  {
    return Vec::new();
  }

  let mut running = Vec::new();
  let mut failed = Vec::new();
  let mut finished = Vec::new();
  let mut groups = Vec::new();

  for child in node.children.values() {
    if !child.children.is_empty() {
      groups.push(child);
      continue;
    }
    match child.state {
      ExecutionState::Running => running.push(child),
      ExecutionState::Failed => failed.push(child),
      ExecutionState::Passed => finished.push(child),
      ExecutionState::Pending => {}
    }
  }

  if !groups.is_empty() {
    groups
  } else {
    sort_by_recent_finish(&mut failed);
    sort_by_recent_finish(&mut finished);
    let mut visible = Vec::new();
    visible.extend(running);
    visible.extend(failed);
    if visible.len() < 4 {
      visible.extend(finished.into_iter().take(4 - visible.len()));
    }
    visible.truncate(4);
    visible
  }
}

fn should_show_pending_suffix(node: &TreeNode, visible_count: usize) -> bool {
  let summary = summary_counts(node);
  !has_group_children(node) && summary.pending > 0 && hidden_pending_count(node, visible_count) > 0
}

fn hidden_pending_count(node: &TreeNode, visible_count: usize) -> usize {
  let pending = node
    .children
    .values()
    .filter(|child| child.state == ExecutionState::Pending && child.children.is_empty())
    .count();
  pending.saturating_sub(0.max(visible_count.saturating_sub(visible_leaf_count(node))))
}

fn visible_leaf_count(node: &TreeNode) -> usize {
  visible_children(node)
    .into_iter()
    .filter(|child| child.children.is_empty())
    .count()
}

fn has_group_children(node: &TreeNode) -> bool {
  node
    .children
    .values()
    .any(|child| !child.children.is_empty())
}

fn sort_by_recent_finish(nodes: &mut Vec<&TreeNode>) {
  nodes.sort_by_key(|node| node.finished_at.unwrap_or_else(Instant::now));
  nodes.reverse();
}

#[derive(Clone, Copy)]
struct SummaryCounts {
  done: usize,
  running: usize,
  pending: usize,
  failed: usize,
}

fn summary_counts(node: &TreeNode) -> SummaryCounts {
  if node.children.is_empty() {
    return match node.state {
      ExecutionState::Pending => SummaryCounts {
        done: 0,
        running: 0,
        pending: 1,
        failed: 0,
      },
      ExecutionState::Running => SummaryCounts {
        done: 0,
        running: 1,
        pending: 0,
        failed: 0,
      },
      ExecutionState::Passed => SummaryCounts {
        done: 1,
        running: 0,
        pending: 0,
        failed: 0,
      },
      ExecutionState::Failed => SummaryCounts {
        done: 1,
        running: 0,
        pending: 0,
        failed: 1,
      },
    };
  }

  node.children.values().fold(
    SummaryCounts {
      done: 0,
      running: 0,
      pending: 0,
      failed: 0,
    },
    |mut acc, child| {
      let counts = summary_counts(child);
      acc.done += counts.done;
      acc.running += counts.running;
      acc.pending += counts.pending;
      acc.failed += counts.failed;
      acc
    },
  )
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
    PhaseKind::NixPrepare => "Nix prepare",
    PhaseKind::Runtime => "Runtime",
    PhaseKind::NixBuild => "Nix build",
  }
}

fn with_output_lock(f: impl FnOnce()) {
  let lock = OUTPUT_LOCK.get_or_init(|| Arc::new(Mutex::new(()))).clone();
  let _guard = lock.lock().unwrap();
  f();
}

fn clear_active_render() {
  let Some(inner) = active_progress() else {
    return;
  };
  let mut state = inner.lock().unwrap();
  if !state.enabled || state.last_rendered_lines == 0 {
    return;
  }
  let mut out = stdout();
  clear_previous_lines(&mut out, state.last_rendered_lines);
  let _ = out.flush();
  state.last_rendered_lines = 0;
}

fn detach_active_render() {
  let Some(inner) = active_progress() else {
    return;
  };
  let mut state = inner.lock().unwrap();
  state.last_rendered_lines = 0;
}

fn redraw_active_render_locked() {
  if let Some(inner) = active_progress() {
    render_locked(&inner);
  }
}

fn active_progress() -> Option<Arc<Mutex<InteractiveState>>> {
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
  thread::spawn(move || {
    loop {
      thread::sleep(Duration::from_millis(100));
      let Some(inner) = weak.upgrade() else {
        break;
      };
      let should_refresh = {
        let state = inner.lock().unwrap();
        state.enabled && state.roots.values().any(has_running_nodes)
      };
      if should_refresh {
        render(&inner);
      }
    }
  });
}

fn has_running_nodes(node: &TreeNode) -> bool {
  node.state == ExecutionState::Running || node.children.values().any(has_running_nodes)
}

fn clear_previous_lines(out: &mut impl Write, line_count: usize) {
  for index in 0..line_count {
    if index > 0 {
      let _ = write!(out, "\x1b[1A");
    }
    let _ = write!(out, "\r\x1b[2K");
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  fn leaf(label: &str, state: ExecutionState) -> TreeNode {
    TreeNode {
      id: label.to_string(),
      kind: NodeKind::Item,
      label: label.to_string(),
      state,
      score: None,
      report: TaskItemReport::default(),
      started_at: None,
      finished_at: Some(Instant::now()),
      children: BTreeMap::new(),
    }
  }

  fn group(kind: TaskKind, label: &str, children: &[TreeNode]) -> TreeNode {
    TreeNode {
      id: label.to_string(),
      kind: NodeKind::Group(kind),
      label: label.to_string(),
      state: ExecutionState::Pending,
      score: None,
      report: TaskItemReport::default(),
      started_at: None,
      finished_at: None,
      children: children
        .iter()
        .cloned()
        .map(|child| (child.label.clone(), child))
        .collect(),
    }
  }

  #[test]
  fn scoped_id_includes_scope_when_present() {
    assert_eq!(scoped_id(None, "std"), "std");
    assert_eq!(scoped_id(Some("aPlusB"), "std"), "aPlusB/std");
  }

  #[test]
  fn summary_counts_reduce_entire_subtree() {
    let node = group(
      TaskKind::Problem,
      "contest",
      &[
        group(
          TaskKind::Solution,
          "std",
          &[
            leaf("a", ExecutionState::Passed),
            leaf("b", ExecutionState::Failed),
          ],
        ),
        group(
          TaskKind::Solution,
          "wa",
          &[
            leaf("c", ExecutionState::Running),
            leaf("d", ExecutionState::Pending),
          ],
        ),
      ],
    );

    let counts = summary_counts(&node);
    assert_eq!(counts.done, 2);
    assert_eq!(counts.running, 1);
    assert_eq!(counts.pending, 1);
    assert_eq!(counts.failed, 1);
  }

  #[test]
  fn finished_solution_subtree_is_collapsed_without_failures() {
    let node = group(
      TaskKind::Solution,
      "std",
      &[
        leaf("a", ExecutionState::Passed),
        leaf("b", ExecutionState::Passed),
      ],
    );

    assert!(visible_children(&node).is_empty());
  }

  #[test]
  fn visible_children_prioritize_running_then_failed_then_recent_finished() {
    let mut finished_a = leaf("finished-a", ExecutionState::Passed);
    finished_a.finished_at = Some(Instant::now() - Duration::from_secs(3));
    let mut finished_b = leaf("finished-b", ExecutionState::Passed);
    finished_b.finished_at = Some(Instant::now() - Duration::from_secs(2));
    let mut failed = leaf("failed", ExecutionState::Failed);
    failed.finished_at = Some(Instant::now() - Duration::from_secs(1));
    let running = leaf("running", ExecutionState::Running);
    let node = group(
      TaskKind::Solution,
      "std",
      &[finished_a, finished_b, failed, running],
    );

    let labels = visible_children(&node)
      .into_iter()
      .map(|child| child.label.clone())
      .collect::<Vec<_>>();
    assert_eq!(labels[0], "running");
    assert_eq!(labels[1], "failed");
    assert_eq!(labels[2], "finished-b");
    assert_eq!(labels[3], "finished-a");
  }

  #[test]
  fn problem_items_render_as_nested_problem_nodes() {
    let child_solution = group(
      TaskKind::Solution,
      "std",
      &[leaf("case1", ExecutionState::Running)],
    );
    let mut problem_item = leaf("aPlusB", ExecutionState::Pending);
    problem_item
      .children
      .insert(child_solution.label.clone(), child_solution);
    let root = group(TaskKind::Problem, "contest", &[problem_item]);

    let rendered = render_node_tree(&root, true, "").join("\n");
    let rendered = console::strip_ansi_codes(&rendered);
    dbg!(&rendered);
    assert!(rendered.contains("Problems contest"));
    assert!(rendered.contains("Problem aPlusB"));
    assert!(rendered.contains("Solution std"));
  }

  #[test]
  fn labels_and_phase_names_remain_stable() {
    assert_eq!(task_label(TaskKind::Problem), "Problems");
    assert_eq!(task_label(TaskKind::Validator), "Validator tests");
    assert_eq!(phase_label(PhaseKind::NixPrepare), "Nix prepare");
    assert_eq!(phase_label(PhaseKind::NixBuild), "Nix build");
  }
}
