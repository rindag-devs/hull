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
use std::io::{IsTerminal, Write, stderr};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant};

use ratatui::backend::{Backend, CrosstermBackend};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, LineGauge, Paragraph, Row, Table, Widget};
use ratatui::{Terminal, TerminalOptions, Viewport};
use tracing::error;

use crate::format::{format_duration_ms, format_size, format_tick, to_title_case};

const MIN_VIEWPORT_HEIGHT: u16 = 12;

type InlineTerminal = Terminal<CrosstermBackend<std::io::Stderr>>;

/// Writes tracing output through Hull's interactive log area.
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
    stderr().flush()
  }
}

/// Controls whether the inline interactive dashboard is enabled.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InteractiveMode {
  /// Enable the dashboard only when stderr is a terminal.
  Auto,
  /// Always enable the dashboard.
  Always,
  /// Never enable the dashboard.
  Never,
}

/// Identifies the high-level phase shown in the dashboard header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhaseKind {
  /// Nix is evaluating expressions.
  NixEval,
  /// Nix is preparing runtime inputs.
  NixPrepare,
  /// Hull is running runtime analysis.
  Runtime,
  /// Nix is building final outputs.
  NixBuild,
}

/// Identifies the kind of task represented by a progress group.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskKind {
  /// A whole problem task.
  Problem,
  /// A validator task.
  Validator,
  /// A checker task.
  Checker,
  /// A solution task.
  Solution,
  /// An artifact preparation task.
  Artifact,
}

/// Tracks the execution state of a progress row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExecutionState {
  /// Work has not started yet.
  Pending,
  /// Work is currently running.
  Running,
  /// Work completed successfully.
  Passed,
  /// Work completed with a failure.
  Failed,
}

/// Runtime details displayed for a completed progress item.
#[derive(Clone, Debug, Default)]
pub struct TaskItemReport {
  /// Optional status text reported by the runtime step.
  pub status: Option<String>,
  /// Optional elapsed wall-clock duration.
  pub duration: Option<Duration>,
  /// Optional consumed tick count.
  pub tick: Option<u64>,
  /// Optional consumed memory in bytes.
  pub memory: Option<u64>,
  /// Optional score associated with the item.
  pub score: Option<f64>,
}

/// Settings used to initialize interactive output.
#[derive(Clone, Debug)]
pub struct InteractiveSettings {
  /// Dashboard activation mode.
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
  /// Returns whether interactive rendering should be active for the current stderr.
  pub fn enabled(self) -> bool {
    match self.mode {
      InteractiveMode::Always => true,
      InteractiveMode::Never => false,
      InteractiveMode::Auto => stderr().is_terminal(),
    }
  }
}

/// Handle for updating the progress dashboard for one problem or scoped subtree.
#[derive(Clone, Debug)]
pub struct ProblemProgressHandle {
  inner: Arc<Mutex<InteractiveState>>,
  scope: Option<String>,
}

/// Guard that keeps a phase active until it is dropped.
pub struct PhaseGuard {
  inner: Arc<Mutex<InteractiveState>>,
  active: bool,
}

/// Guard that temporarily suspends live dashboard rendering.
pub struct LiveRenderSuspendGuard {
  active: bool,
}

/// Guard for one task item that records an internal error if dropped unfinished.
pub struct ItemGuard {
  handle: TaskHandle,
  item_name: String,
  active: bool,
}

/// Handle for updating a registered task group.
#[derive(Clone, Debug)]
pub struct TaskHandle {
  inner: Arc<Mutex<InteractiveState>>,
  task_id: String,
}

#[derive(Debug)]
struct InteractiveState {
  enabled: bool,
  suspended: bool,
  title_label: String,
  title_name: Option<String>,
  phase: Option<PhaseState>,
  roots: BTreeMap<String, TreeNode>,
  terminal: Option<InlineTerminal>,
  viewport_height: u16,
  dashboard_origin_y: Option<u16>,
}

#[derive(Clone, Debug)]
struct PhaseState {
  kind: PhaseKind,
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

#[derive(Clone)]
struct Dashboard {
  title: String,
  summary: String,
  total: SummaryCounts,
  headers: [&'static str; 6],
  rows: Vec<DashboardRow>,
  active: Vec<DashboardItem>,
  failures: Vec<DashboardItem>,
}

#[derive(Clone)]
struct DashboardRow {
  cells: [String; 6],
  style: RowStyle,
}

#[derive(Clone)]
struct DashboardItem {
  label: String,
  detail: String,
}

#[derive(Clone, Copy)]
enum RowStyle {
  Passed,
  Running,
  Failed,
  Pending,
}

#[derive(Clone, Copy, Default)]
struct SummaryCounts {
  done: usize,
  running: usize,
  pending: usize,
  failed: usize,
}

impl std::ops::Add for SummaryCounts {
  type Output = Self;

  fn add(self, rhs: Self) -> Self::Output {
    Self {
      done: self.done + rhs.done,
      running: self.running + rhs.running,
      pending: self.pending + rhs.pending,
      failed: self.failed + rhs.failed,
    }
  }
}

type OutputLock = Arc<Mutex<()>>;
type ActiveProgress = Arc<Mutex<Option<Weak<Mutex<InteractiveState>>>>>;
type SuspendState = Arc<Mutex<usize>>;

static SETTINGS: OnceLock<InteractiveSettings> = OnceLock::new();
static OUTPUT_LOCK: OnceLock<OutputLock> = OnceLock::new();
static ACTIVE_PROGRESS: OnceLock<ActiveProgress> = OnceLock::new();
static LIVE_RENDER_SUSPENDED: OnceLock<SuspendState> = OnceLock::new();

/// Initializes global interactive output settings.
pub fn init(settings: InteractiveSettings) {
  let _ = SETTINGS.set(settings);
  let _ = OUTPUT_LOCK.set(Arc::new(Mutex::new(())));
  let _ = ACTIVE_PROGRESS.set(Arc::new(Mutex::new(None)));
  let _ = LIVE_RENDER_SUSPENDED.set(Arc::new(Mutex::new(0)));
}

/// Returns the active interactive settings, or defaults if not initialized.
pub fn current_settings() -> InteractiveSettings {
  SETTINGS.get().cloned().unwrap_or_default()
}

fn log_line(message: &str) {
  with_output_lock(|| {
    if let Some(inner) = active_progress() {
      let mut state = inner.lock().unwrap();
      if state.enabled && !state.suspended {
        insert_log_line(&mut state, message);
        draw_locked(&mut state);
        return;
      }
    }
    eprintln!("{message}");
  });
}

/// Suspends live rendering so external output can write directly to the terminal.
pub fn suspend_live_render() -> LiveRenderSuspendGuard {
  let suspended = LIVE_RENDER_SUSPENDED
    .get_or_init(|| Arc::new(Mutex::new(0)))
    .clone();
  let first_suspend = {
    let mut guard = suspended.lock().unwrap();
    let first_suspend = *guard == 0;
    *guard += 1;
    first_suspend
  };
  if first_suspend {
    with_output_lock(|| {
      if let Some(inner) = active_progress() {
        let mut state = inner.lock().unwrap();
        clear_dashboard(&mut state);
        state.suspended = true;
      }
    });
  }
  LiveRenderSuspendGuard { active: true }
}

/// Creates an interactive progress dashboard for a problem.
pub fn create_problem_progress(name: &str) -> ProblemProgressHandle {
  let enabled = current_settings().enabled();
  let (terminal, viewport_height) = if enabled {
    create_terminal()
      .map(|(terminal, height)| (Some(terminal), height))
      .unwrap_or((None, MIN_VIEWPORT_HEIGHT))
  } else {
    (None, MIN_VIEWPORT_HEIGHT)
  };
  let inner = Arc::new(Mutex::new(InteractiveState {
    enabled,
    suspended: false,
    title_label: "Problem".to_string(),
    title_name: Some(name.to_string()),
    phase: None,
    roots: BTreeMap::new(),
    terminal,
    viewport_height,
    dashboard_origin_y: None,
  }));

  ACTIVE_PROGRESS
    .get_or_init(|| Arc::new(Mutex::new(None)))
    .lock()
    .unwrap()
    .replace(Arc::downgrade(&inner));

  render(&inner);
  ProblemProgressHandle { inner, scope: None }
}

impl ProblemProgressHandle {
  /// Creates a disabled progress handle for non-interactive contexts.
  pub fn disabled() -> Self {
    Self {
      inner: Arc::new(Mutex::new(InteractiveState {
        enabled: false,
        suspended: false,
        title_label: "Dummy".to_string(),
        title_name: None,
        phase: None,
        roots: BTreeMap::new(),
        terminal: None,
        viewport_height: MIN_VIEWPORT_HEIGHT,
        dashboard_origin_y: None,
      })),
      scope: None,
    }
  }

  /// Returns whether this handle is rendering a live dashboard.
  pub fn enabled(&self) -> bool {
    self.inner.lock().unwrap().enabled
  }

  /// Replaces the dashboard title and clears existing progress rows.
  pub fn set_title(&self, label: impl Into<String>, name: impl Into<String>) {
    {
      let mut state = self.inner.lock().unwrap();
      state.title_label = label.into();
      state.title_name = Some(name.into());
      state.phase = None;
      state.roots.clear();
    }
    render(&self.inner);
  }

  /// Creates a scoped handle whose task ids are nested under `name`.
  pub fn child_scope(&self, name: impl Into<String>) -> Self {
    Self {
      inner: self.inner.clone(),
      scope: Some(scoped_id(self.scope.as_deref(), &name.into())),
    }
  }

  /// Starts a dashboard phase at `started_at` and returns a guard that ends it on drop.
  pub fn phase(&self, kind: PhaseKind, started_at: Instant) -> PhaseGuard {
    {
      let mut state = self.inner.lock().unwrap();
      state.phase = Some(PhaseState { kind, started_at });
    }
    render(&self.inner);
    PhaseGuard {
      inner: self.inner.clone(),
      active: true,
    }
  }

  /// Registers a task group with its expected child item names.
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
}

impl Drop for ProblemProgressHandle {
  fn drop(&mut self) {
    if self.scope.is_none() {
      close_dashboard_if_last_reference(&self.inner);
    }
  }
}

impl Drop for TaskHandle {
  fn drop(&mut self) {
    close_dashboard_if_last_reference(&self.inner);
  }
}

impl Drop for PhaseGuard {
  fn drop(&mut self) {
    if !self.active {
      return;
    }
    {
      let mut state = self.inner.lock().unwrap();
      state.phase = None;
      state.roots.clear();
    }
    render(&self.inner);
    self.active = false;
  }
}

impl Drop for LiveRenderSuspendGuard {
  fn drop(&mut self) {
    if !self.active {
      return;
    }
    let should_resume = {
      let mut guard = LIVE_RENDER_SUSPENDED
        .get_or_init(|| Arc::new(Mutex::new(0)))
        .lock()
        .unwrap();
      *guard = guard.saturating_sub(1);
      *guard == 0
    };
    if !should_resume {
      self.active = false;
      return;
    }
    with_output_lock(|| {
      if let Some(inner) = active_progress() {
        {
          let mut state = inner.lock().unwrap();
          clear_dashboard(&mut state);
          state.suspended = false;
        }
        render_locked(&inner);
      }
    });
    self.active = false;
  }
}

impl TaskHandle {
  fn start_item(&self, name: &str) {
    update_item(&self.inner, &self.task_id, name, |item| {
      item.state = ExecutionState::Running;
      item.report = TaskItemReport::default();
      item.started_at = Some(Instant::now());
      item.finished_at = None;
    });
  }

  /// Marks an item as running and returns a guard used to finish it.
  pub fn item(&self, name: impl Into<String>) -> ItemGuard {
    let item_name = name.into();
    self.start_item(&item_name);
    ItemGuard {
      handle: self.clone(),
      item_name,
      active: true,
    }
  }

  fn finish_item(&self, name: &str, success: bool, report: TaskItemReport) {
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

  /// Sets the aggregate score for this task group.
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

impl ItemGuard {
  /// Marks the item complete and records its final report.
  pub fn finish(mut self, success: bool, report: TaskItemReport) {
    self.handle.finish_item(&self.item_name, success, report);
    self.active = false;
  }
}

impl Drop for ItemGuard {
  fn drop(&mut self) {
    if self.active {
      error!(
        "Task item {}/{} ended without an explicit result, status: internal_error",
        self.handle.task_id, self.item_name
      );
      self.handle.finish_item(
        &self.item_name,
        false,
        TaskItemReport {
          status: Some("internal_error".to_string()),
          ..TaskItemReport::default()
        },
      );
      self.active = false;
    }
  }
}

fn create_terminal() -> Option<(InlineTerminal, u16)> {
  let backend = CrosstermBackend::new(stderr());
  let height = backend
    .size()
    .map(|size| viewport_height_for_terminal_rows(size.height))
    .unwrap_or(MIN_VIEWPORT_HEIGHT);
  Terminal::with_options(
    backend,
    TerminalOptions {
      viewport: Viewport::Inline(height),
    },
  )
  .map(|terminal| (terminal, height))
  .ok()
}

fn viewport_height_for_terminal_rows(rows: u16) -> u16 {
  ((rows as u32 * 35).div_ceil(100) as u16).max(MIN_VIEWPORT_HEIGHT)
}

fn insert_log_line(state: &mut InteractiveState, message: &str) {
  let Some(terminal) = state.terminal.as_mut() else {
    eprintln!("{message}");
    return;
  };
  let text = message.to_string();
  let _ = terminal.insert_before(1, |buf| {
    Paragraph::new(Line::raw(text)).render(buf.area, buf);
  });
}

fn insert_group(state: &mut InteractiveState, scope: Option<&str>, node: TreeNode) {
  if let Some(scope) = scope
    && let Some(parent_item) = find_node_mut_by_id(&mut state.roots, scope)
  {
    parent_item.children.insert(node.id.clone(), node);
    return;
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
    if let Some(task) = find_node_mut_by_id(&mut state.roots, task_id)
      && let Some(item) = task.children.get_mut(item_name)
    {
      update(item);
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
  draw_locked(&mut state);
}

fn draw_locked(state: &mut InteractiveState) {
  if !state.enabled || state.suspended {
    return;
  }
  let dashboard = project_dashboard(state);
  update_terminal_for_resize(state);
  let Some(terminal) = state.terminal.as_mut() else {
    return;
  };
  let mut dashboard_origin_y = None;
  let _ = terminal.draw(|frame| {
    let area = frame.area();
    dashboard_origin_y = Some(area.y);
    render_dashboard(area, frame.buffer_mut(), &dashboard);
  });
  state.dashboard_origin_y = dashboard_origin_y;
}

fn update_terminal_for_resize(state: &mut InteractiveState) {
  let Some(terminal) = state.terminal.as_mut() else {
    return;
  };
  let Ok(size) = terminal.size() else {
    return;
  };
  let height = viewport_height_for_terminal_rows(size.height);
  if height == state.viewport_height {
    return;
  }
  clear_dashboard(state);
  if let Some((terminal, height)) = create_terminal() {
    state.terminal = Some(terminal);
    state.viewport_height = height;
  }
}

fn render_dashboard(area: Rect, buf: &mut ratatui::buffer::Buffer, dashboard: &Dashboard) {
  let chunks = Layout::default()
    .direction(Direction::Vertical)
    .constraints([
      Constraint::Length(3),
      Constraint::Ratio(1, 2),
      Constraint::Ratio(1, 2),
    ])
    .split(area);

  render_header(chunks[0], buf, dashboard);
  render_rows(chunks[1], buf, dashboard);
  render_panels(chunks[2], buf, dashboard);
}

fn render_header(area: Rect, buf: &mut ratatui::buffer::Buffer, dashboard: &Dashboard) {
  let block = Block::default()
    .borders(Borders::ALL)
    .border_style(Style::default().fg(Color::DarkGray))
    .title(Line::styled(
      dashboard.title.clone(),
      Style::default()
        .fg(Color::Cyan)
        .add_modifier(Modifier::BOLD),
    ));
  let inner = block.inner(area);
  block.render(area, buf);

  let chunks = Layout::default()
    .direction(Direction::Horizontal)
    .constraints([
      Constraint::Length(dashboard.summary.len() as u16 + 1),
      Constraint::Min(0),
    ])
    .split(inner);
  let progress = progress_ratio(dashboard.total);
  Paragraph::new(Line::from(dashboard.summary.clone())).render(chunks[0], buf);
  LineGauge::default()
    .filled_style(gauge_style(dashboard.total))
    .unfilled_style(Style::default().fg(Color::DarkGray))
    .label(format!("{:.0}%", progress * 100.0))
    .ratio(progress)
    .render(chunks[1], buf);
}

fn render_rows(area: Rect, buf: &mut ratatui::buffer::Buffer, dashboard: &Dashboard) {
  let row_capacity = area.height.saturating_sub(3) as usize;
  let visible_rows = dashboard
    .rows
    .iter()
    .take(row_capacity)
    .map(|row| Row::new(styled_row_cells(row)).height(1));

  let title = if dashboard.rows.len() > row_capacity {
    format!(
      " Progress - showing {row_capacity}/{} ",
      dashboard.rows.len()
    )
  } else {
    " Progress ".to_string()
  };
  Table::new(
    visible_rows,
    [
      Constraint::Percentage(22),
      Constraint::Percentage(14),
      Constraint::Percentage(20),
      Constraint::Percentage(12),
      Constraint::Percentage(14),
      Constraint::Percentage(18),
    ],
  )
  .header(
    Row::new(dashboard.headers)
      .style(Style::default().add_modifier(Modifier::BOLD))
      .height(1),
  )
  .block(
    Block::default()
      .borders(Borders::ALL)
      .border_style(Style::default().fg(Color::DarkGray))
      .title(Line::styled(
        title,
        Style::default()
          .fg(Color::Cyan)
          .add_modifier(Modifier::BOLD),
      )),
  )
  .render(area, buf);
}

fn render_panels(area: Rect, buf: &mut ratatui::buffer::Buffer, dashboard: &Dashboard) {
  let chunks = Layout::default()
    .direction(Direction::Horizontal)
    .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
    .split(area);
  render_item_panel(chunks[0], buf, " Active ", &dashboard.active, Color::Yellow);
  render_item_panel(
    chunks[1],
    buf,
    " Failures ",
    &dashboard.failures,
    Color::Red,
  );
}

fn render_item_panel(
  area: Rect,
  buf: &mut ratatui::buffer::Buffer,
  title: &str,
  items: &[DashboardItem],
  accent: Color,
) {
  let capacity = area.height.saturating_sub(2) as usize;
  let mut lines = if items.is_empty() {
    vec![Line::styled("none", Style::default().fg(Color::DarkGray))]
  } else {
    items
      .iter()
      .take(capacity)
      .map(|item| {
        Line::from(vec![
          Span::raw(item.label.clone()),
          Span::raw("  "),
          Span::styled(item.detail.clone(), Style::default().fg(Color::Gray)),
        ])
      })
      .collect::<Vec<_>>()
  };
  if items.len() > capacity && capacity > 0 {
    let hidden = items.len() - capacity + 1;
    if lines.len() == capacity {
      lines.pop();
    }
    lines.push(Line::styled(
      format!("+{hidden} more"),
      Style::default().fg(Color::DarkGray),
    ));
  }
  Paragraph::new(lines)
    .block(
      Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::DarkGray))
        .title(Line::styled(
          title,
          Style::default().fg(accent).add_modifier(Modifier::BOLD),
        )),
    )
    .render(area, buf);
}

fn clear_dashboard(state: &mut InteractiveState) {
  if let Some(terminal) = state.terminal.as_mut() {
    let _ = terminal.clear();
    if let Some(y) = state.dashboard_origin_y {
      let _ = terminal.set_cursor_position((0, y));
    }
  }
}

fn close_dashboard(state: &mut InteractiveState) {
  clear_dashboard(state);
  state.terminal = None;
  state.enabled = false;
}

fn close_dashboard_if_last_reference(inner: &Arc<Mutex<InteractiveState>>) {
  if Arc::strong_count(inner) != 1 {
    return;
  }
  with_output_lock(|| close_dashboard(&mut inner.lock().unwrap()));
}

fn row_style(style: RowStyle) -> Style {
  match style {
    RowStyle::Passed => Style::default().fg(Color::Green),
    RowStyle::Running => Style::default().fg(Color::Yellow),
    RowStyle::Failed => Style::default().fg(Color::Red),
    RowStyle::Pending => Style::default().fg(Color::Gray),
  }
}

fn styled_row_cells(row: &DashboardRow) -> Vec<Cell<'static>> {
  row
    .cells
    .iter()
    .enumerate()
    .map(|(index, cell)| {
      let style = match index {
        0..=3 => Style::default(),
        4 | 5 => row_style(row.style),
        _ => Style::default(),
      };
      Cell::from(cell.clone()).style(style)
    })
    .collect()
}

fn gauge_style(total: SummaryCounts) -> Style {
  if total.failed > 0 {
    Style::default().fg(Color::Red)
  } else if total.running > 0 {
    Style::default().fg(Color::Yellow)
  } else {
    Style::default().fg(Color::Green)
  }
}

fn progress_ratio(summary: SummaryCounts) -> f64 {
  let total = summary.done + summary.running + summary.pending;
  if total == 0 {
    1.0
  } else {
    summary.done as f64 / total as f64
  }
}

fn project_dashboard(state: &InteractiveState) -> Dashboard {
  if state.title_label == "Contest" {
    project_contest_dashboard(state)
  } else {
    project_problem_dashboard(state)
  }
}

fn project_contest_dashboard(state: &InteractiveState) -> Dashboard {
  let nodes = state.roots.values().collect::<Vec<_>>();
  let problems = nodes
    .iter()
    .find(|node| matches!(node.kind, NodeKind::Group(TaskKind::Problem)))
    .map(|node| node.children.values().collect::<Vec<_>>())
    .unwrap_or_default();
  let problem_counts = problems
    .iter()
    .fold(SummaryCounts::default(), |mut acc, problem| {
      match row_style_for_counts(summary_counts(problem)) {
        RowStyle::Failed => acc.failed += 1,
        RowStyle::Running => acc.running += 1,
        RowStyle::Pending => acc.pending += 1,
        RowStyle::Passed => acc.done += 1,
      }
      acc
    });
  let total = problems
    .iter()
    .fold(SummaryCounts::default(), |acc, problem| {
      acc + summary_counts(problem)
    });
  let rows = problems
    .iter()
    .map(|problem| {
      let summary = summary_counts(problem);
      DashboardRow {
        cells: [
          problem.label.clone(),
          problem_phase(summary),
          progress_text(summary),
          solution_cell(problem),
          active_cell(problem),
          status_cell(summary),
        ],
        style: row_style_for_counts(summary),
      }
    })
    .collect::<Vec<_>>();
  Dashboard {
    title: title_line(state),
    summary: format!(
      "problems: {}/{} | running: {} | failed: {} | pending: {}",
      problem_counts.done,
      problems.len(),
      problem_counts.running,
      problem_counts.failed,
      problem_counts.pending
    ),
    total,
    headers: [
      "Problem",
      "Phase",
      "Progress",
      "Solutions",
      "Active",
      "Status",
    ],
    active: collect_dashboard_items(&nodes, ExecutionState::Running),
    failures: collect_dashboard_items(&nodes, ExecutionState::Failed),
    rows,
  }
}

fn project_problem_dashboard(state: &InteractiveState) -> Dashboard {
  let nodes = state.roots.values().collect::<Vec<_>>();
  let solution_nodes = nodes
    .iter()
    .filter(|node| matches!(node.kind, NodeKind::Group(TaskKind::Solution)))
    .copied()
    .collect::<Vec<_>>();
  let table_nodes = if solution_nodes.is_empty() {
    nodes.clone()
  } else {
    solution_nodes
  };
  let total = nodes.iter().fold(SummaryCounts::default(), |acc, node| {
    acc + summary_counts(node)
  });
  let rows = table_nodes
    .iter()
    .map(|node| {
      let summary = summary_counts(node);
      DashboardRow {
        cells: [
          node.label.clone(),
          task_name(node),
          progress_text(summary),
          score_cell(node),
          active_cell(node),
          status_cell(summary),
        ],
        style: row_style_for_counts(summary),
      }
    })
    .collect::<Vec<_>>();
  Dashboard {
    title: title_line(state),
    summary: format!(
      "cases: {}/{} done | running: {} | failed: {} | pending: {}",
      total.done,
      total.done + total.running + total.pending,
      total.running,
      total.failed,
      total.pending
    ),
    total,
    headers: ["Task", "Kind", "Progress", "Score", "Active", "Status"],
    active: collect_dashboard_items(&nodes, ExecutionState::Running),
    failures: collect_dashboard_items(&nodes, ExecutionState::Failed),
    rows,
  }
}

fn title_line(state: &InteractiveState) -> String {
  let name = state.title_name.as_deref().unwrap_or("-");
  let phase = state
    .phase
    .as_ref()
    .map(|phase| {
      format!(
        "{} | {}",
        phase_label(phase.kind),
        format_duration_ms(phase.started_at.elapsed())
      )
    })
    .unwrap_or_else(|| "Idle".to_string());
  format!(" Hull | {} {} | {} ", state.title_label, name, phase)
}

fn problem_phase(summary: SummaryCounts) -> String {
  if summary.failed > 0 {
    "failed".to_string()
  } else if summary.running > 0 {
    "running".to_string()
  } else if summary.pending > 0 {
    "pending".to_string()
  } else {
    "done".to_string()
  }
}

fn progress_text(summary: SummaryCounts) -> String {
  let total = summary.done + summary.running + summary.pending;
  if total == 0 {
    return "0/0".to_string();
  }
  let percent = summary.done * 100 / total;
  format!("{}/{} | {}%", summary.done, total, percent)
}

fn solution_cell(node: &TreeNode) -> String {
  let mut done = 0;
  let mut total = 0;
  for child in node.children.values() {
    if matches!(child.kind, NodeKind::Group(TaskKind::Solution)) {
      let summary = summary_counts(child);
      total += 1;
      if summary.pending == 0 && summary.running == 0 && summary.failed == 0 {
        done += 1;
      }
    }
  }
  if total == 0 {
    "-".to_string()
  } else {
    format!("{done}/{total}")
  }
}

fn status_cell(summary: SummaryCounts) -> String {
  if summary.failed > 0 {
    format!("failed {}", summary.failed)
  } else if summary.running > 0 {
    format!("running {}", summary.running)
  } else if summary.pending > 0 {
    format!("pending {}", summary.pending)
  } else {
    "ok".to_string()
  }
}

fn active_cell(node: &TreeNode) -> String {
  let summary = summary_counts(node);
  if summary.failed > 0 {
    format!("{} failed", summary.failed)
  } else if summary.running > 0 {
    format!("{} active", summary.running)
  } else {
    "-".to_string()
  }
}

fn row_style_for_counts(summary: SummaryCounts) -> RowStyle {
  if summary.failed > 0 {
    RowStyle::Failed
  } else if summary.running > 0 {
    RowStyle::Running
  } else if summary.pending > 0 {
    RowStyle::Pending
  } else {
    RowStyle::Passed
  }
}

fn score_cell(node: &TreeNode) -> String {
  node
    .score
    .map(|score| format!("{score:.3}"))
    .unwrap_or_else(|| "-".to_string())
}

fn task_name(node: &TreeNode) -> String {
  match node.kind {
    NodeKind::Group(kind) => task_label(kind).to_string(),
    NodeKind::Item => "item".to_string(),
  }
}

fn collect_dashboard_items(nodes: &[&TreeNode], state: ExecutionState) -> Vec<DashboardItem> {
  let mut items = Vec::new();
  collect_nodes(nodes, state, &mut items);
  if state == ExecutionState::Running {
    items.sort_by_key(|item| item.started_at);
  }
  items
    .iter()
    .map(|item| {
      let detail = if state == ExecutionState::Running {
        elapsed_text(item)
      } else {
        let detail = detail_text(item);
        if detail.is_empty() {
          status_text(item)
        } else {
          format!("{} {}", status_text(item), detail)
        }
      };
      DashboardItem {
        label: compact_id(item),
        detail,
      }
    })
    .collect()
}

fn collect_nodes<'a>(nodes: &[&'a TreeNode], state: ExecutionState, items: &mut Vec<&'a TreeNode>) {
  for node in nodes {
    if node.state == state && node.children.is_empty() {
      items.push(node);
    }
    let children = node.children.values().collect::<Vec<_>>();
    collect_nodes(&children, state, items);
  }
}

fn compact_id(node: &TreeNode) -> String {
  node
    .id
    .split('/')
    .rev()
    .take(3)
    .collect::<Vec<_>>()
    .into_iter()
    .rev()
    .collect::<Vec<_>>()
    .join("/")
}

fn elapsed_text(node: &TreeNode) -> String {
  node
    .started_at
    .map(|started| format_duration_ms(started.elapsed()))
    .unwrap_or_default()
}

fn status_text(node: &TreeNode) -> String {
  node
    .report
    .status
    .as_ref()
    .map(|status| to_title_case(status))
    .unwrap_or_else(|| "Failed".to_string())
}

fn detail_text(node: &TreeNode) -> String {
  let mut parts = Vec::new();
  if let Some(duration) = node.report.duration {
    parts.push(format_duration_ms(duration));
  }
  if let Some(memory) = node.report.memory {
    parts.push(format_size(memory));
  }
  if let Some(tick) = node.report.tick {
    parts.push(format!("tick {}", format_tick(tick)));
  }
  parts.join(" ")
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

fn task_label(kind: TaskKind) -> &'static str {
  match kind {
    TaskKind::Problem => "problem",
    TaskKind::Validator => "validator",
    TaskKind::Checker => "checker",
    TaskKind::Solution => "solution",
    TaskKind::Artifact => "artifact",
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

fn active_progress() -> Option<Arc<Mutex<InteractiveState>>> {
  let active = ACTIVE_PROGRESS.get_or_init(|| Arc::new(Mutex::new(None)));
  let mut guard = active.lock().unwrap();
  let upgraded = guard.as_ref().and_then(Weak::upgrade);
  if upgraded.is_none() {
    *guard = None;
  }
  upgraded
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
  fn scoped_id_scope() {
    assert_eq!(scoped_id(None, "std"), "std");
    assert_eq!(scoped_id(Some("aPlusB"), "std"), "aPlusB/std");
  }

  #[test]
  fn summary_counts_tree() {
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
  fn item_guard_error() {
    let progress = ProblemProgressHandle::disabled();
    let handle = progress.register_group(TaskKind::Solution, "std", ["case1"], Some(0.0));

    {
      let _item = handle.item("case1");
    }

    let state = progress.inner.lock().unwrap();
    let node = state.roots.get("std").unwrap();
    let item = node.children.get("case1").unwrap();
    assert_eq!(item.state, ExecutionState::Failed);
    assert_eq!(item.report.status.as_deref(), Some("internal_error"));
  }

  #[test]
  fn dashboard_all_rows() {
    let mut state = InteractiveState {
      enabled: false,
      suspended: false,
      title_label: "Problem".to_string(),
      title_name: Some("many".to_string()),
      phase: None,
      roots: BTreeMap::new(),
      terminal: None,
      viewport_height: MIN_VIEWPORT_HEIGHT,
      dashboard_origin_y: None,
    };
    for index in 0..20 {
      let name = format!("solution-{index}");
      state.roots.insert(
        name.clone(),
        group(
          TaskKind::Solution,
          &name,
          &[leaf("case", ExecutionState::Passed)],
        ),
      );
    }
    let dashboard = project_dashboard(&state);
    assert_eq!(dashboard.rows.len(), 20);
  }

  #[test]
  fn viewport_height_bounds() {
    assert_eq!(viewport_height_for_terminal_rows(20), MIN_VIEWPORT_HEIGHT);
    assert_eq!(viewport_height_for_terminal_rows(100), 35);
    assert_eq!(viewport_height_for_terminal_rows(200), 70);
  }

  #[test]
  fn suspend_restores() {
    let _lock = suspend_test_lock();
    reset_suspend_depth();
    let guard = suspend_live_render();
    assert_eq!(suspend_depth(), 1);
    drop(guard);
    assert_eq!(suspend_depth(), 0);
  }

  #[test]
  fn suspend_nesting() {
    let _lock = suspend_test_lock();
    reset_suspend_depth();
    let outer = suspend_live_render();
    let inner = suspend_live_render();
    assert_eq!(suspend_depth(), 2);
    drop(outer);
    assert_eq!(suspend_depth(), 1);
    drop(inner);
    assert_eq!(suspend_depth(), 0);
  }

  fn suspend_depth() -> usize {
    *LIVE_RENDER_SUSPENDED
      .get_or_init(|| Arc::new(Mutex::new(0)))
      .lock()
      .unwrap()
  }

  fn reset_suspend_depth() {
    *LIVE_RENDER_SUSPENDED
      .get_or_init(|| Arc::new(Mutex::new(0)))
      .lock()
      .unwrap() = 0;
  }

  fn suspend_test_lock() -> std::sync::MutexGuard<'static, ()> {
    static TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    TEST_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
  }
}
