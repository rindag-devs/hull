/*
  This file is part of Hull.

  Hull is free software: you can redistribute it and/or modify it under the terms of the GNU
  Lesser General Public License as published by the Free Software Foundation, either version 3 of
  the License, or (at your option) any later version.
*/

mod module;
mod request;
mod scheduler;
mod wasi;

use std::{
  cell::Cell,
  fmt,
  future::Future,
  path::{Path, PathBuf},
  pin::Pin,
  rc::Rc,
  task::{Context as TaskContext, Poll},
};

use anyhow::{Context, Result, anyhow};
use futures::{FutureExt, future::LocalBoxFuture};
pub use request::{
  Deadlock, DirectoryBinding, DirectoryPermissions, File, FileBinding, FilePermissions,
  FileSizeLimit, FileSystem, InitialDescriptor, ProgramRequest, ProgramResult, RunStatus,
  SessionReport, SessionRequest, ToolLimit,
};
use wasmtime::{
  Config, Engine, Inlining, Linker, Module, OptLevel, ProfilingStrategy, Store, Strategy,
  WasmFeatures,
};

/// The tick ceiling used by trusted Hull tools.
pub const TOOL_TICK_LIMIT: u64 = 10u64.pow(18);
/// The memory and stack ceiling used by trusted Hull tools.
pub const TOOL_MEMORY_LIMIT: u64 = u32::MAX as u64;
/// The file-size ceiling used by trusted Hull tools.
pub const TOOL_FILE_SIZE_LIMIT: usize = usize::MAX;

const ASYNC_HOST_STACK_RESERVE: usize = 2 * 1024 * 1024;
const SCHEDULER_TICK_INTERVAL: u64 = 10_000_000;

/// Returns Hull's private Wasmtime module-cache directory when one is available.
pub fn module_cache_directory() -> Option<PathBuf> {
  if let Some(cache) = std::env::var_os("HULL_WASMTIME_CACHE_DIR").filter(|path| !path.is_empty()) {
    return Some(PathBuf::from(cache));
  }
  if let Some(cache) = std::env::var_os("XDG_CACHE_HOME").filter(|path| !path.is_empty()) {
    return Some(PathBuf::from(cache).join("hull").join("cwasm"));
  }
  std::env::var_os("HOME")
    .filter(|path| !path.is_empty())
    .map(PathBuf::from)
    .map(|home| home.join(".cache").join("hull").join("cwasm"))
}

/// Builds an engine with Hull's complete guest feature policy.
pub fn engine_config(max_wasm_stack: usize) -> Result<Config> {
  if max_wasm_stack == 0 {
    return Err(anyhow!("the Wasm stack limit must be nonzero"));
  }
  let async_stack_size = max_wasm_stack
    .checked_add(ASYNC_HOST_STACK_RESERVE)
    .ok_or_else(|| {
      anyhow!("the Wasm stack limit leaves no address space for the async host stack")
    })?;
  let mut config = Config::new();
  let features = (WasmFeatures::MVP - WasmFeatures::GC_TYPES) | WasmFeatures::CUSTOM_PAGE_SIZES;
  config
    .wasm_features(WasmFeatures::all(), false)
    .wasm_features(features, true)
    .consume_fuel(true)
    .strategy(Strategy::Cranelift)
    .profiler(ProfilingStrategy::None)
    .cranelift_opt_level(OptLevel::Speed)
    .compiler_inlining(Inlining::Yes)
    .wasm_backtrace_max_frames(None)
    .max_wasm_stack(max_wasm_stack)
    .async_stack_size(async_stack_size);
  Ok(config)
}

fn load_module_path(engine: &Engine, source_path: &Path) -> Result<Module> {
  let source = std::fs::read(source_path)
    .with_context(|| format!("failed to read {}", source_path.display()))?;
  module::load_module(engine, &source)
}

struct Execution {
  result: wasmtime::Result<()>,
  setup_error: Option<String>,
  state: wasi::State,
  tick: u64,
  memory: u64,
}

type ExecutionFuture = LocalBoxFuture<'static, Execution>;

#[derive(Clone, Copy, Default)]
struct PendingTelemetry {
  memory_exceeded: bool,
  memory: u64,
  local_file_error_exceeded: bool,
}

struct TrackedExecutionFuture {
  inner: ExecutionFuture,
  state: *const wasi::State,
  telemetry: Rc<Cell<PendingTelemetry>>,
}

impl Future for TrackedExecutionFuture {
  type Output = Execution;

  fn poll(mut self: Pin<&mut Self>, context: &mut TaskContext<'_>) -> Poll<Self::Output> {
    let result = Pin::new(&mut self.inner).poll(context);
    if result.is_pending() {
      // The store is pinned inside `inner`, so its state remains at this address until `inner`
      // is dropped. Pending telemetry must be copied before the scheduler drops that future.
      let state = unsafe { &*self.state };
      self.telemetry.set(PendingTelemetry {
        memory_exceeded: state.memory.exceeded,
        memory: u64::try_from(state.memory.peak).unwrap_or(u64::MAX),
        local_file_error_exceeded: state.local_file_error_exceeded(),
      });
    }
    result
  }
}

struct PreparedProgram {
  future: ExecutionFuture,
  telemetry: Rc<Cell<PendingTelemetry>>,
}

fn prepare_program(
  program: &ProgramRequest,
  files: &wasi::Files,
  periodic_yield: bool,
) -> Result<Option<PreparedProgram>> {
  let mut state = wasi::State::new(program, files)?;
  if state.file_error_exceeded(files) {
    state.close_descriptors();
    return Ok(None);
  }
  let setup = (|| {
    let stack = usize::try_from(program.memory_limit)
      .context("memory_limit does not fit the host address width")?;
    let engine = Engine::new(&engine_config(stack.max(1))?)?;
    let module = load_module_path(&engine, &program.wasm_path)?;
    let mut linker = Linker::new(&engine);
    wasi::add_to_linker(&mut linker)?;
    Ok::<_, anyhow::Error>((engine, module, linker))
  })();
  let (engine, module, linker) = match setup {
    Ok(setup) => setup,
    Err(error) => {
      state.close_descriptors();
      return Err(error);
    }
  };
  let mut store = Box::pin(Store::new(&engine, state));
  let store_setup = (|| {
    store.limiter(|state| &mut state.memory);
    store.set_fuel(program.tick_limit)?;
    if periodic_yield {
      store.fuel_async_yield_interval(Some(SCHEDULER_TICK_INTERVAL))?;
    }
    Ok::<_, anyhow::Error>(())
  })();
  if let Err(error) = store_setup {
    store.data_mut().close_descriptors();
    return Err(error);
  }
  let tick_limit = program.tick_limit;
  let state = store.data() as *const wasi::State;
  let telemetry = Rc::new(Cell::new(PendingTelemetry::default()));
  let inner = async move {
    let (result, setup_error) = match linker
      .instantiate_async(store.as_mut().get_mut(), &module)
      .await
    {
      Err(error) => {
        let message = error.to_string();
        (Err(error), Some(message))
      }
      Ok(instance) => match instance.get_typed_func::<(), ()>(store.as_mut().get_mut(), "_start") {
        Err(error) => {
          let message = error.to_string();
          (Err(error), Some(message))
        }
        Ok(start) => (start.call_async(store.as_mut().get_mut(), ()).await, None),
      },
    };
    let tick = tick_limit.saturating_sub(store.get_fuel().unwrap_or(0));
    let memory = u64::try_from(store.data().memory.peak).unwrap_or(u64::MAX);
    store.data_mut().close_descriptors();
    let state = (*Pin::into_inner(store)).into_data();
    Execution {
      result,
      setup_error,
      state,
      tick,
      memory,
    }
  }
  .boxed_local();
  Ok(Some(PreparedProgram {
    future: TrackedExecutionFuture {
      inner,
      state,
      telemetry: Rc::clone(&telemetry),
    }
    .boxed_local(),
    telemetry,
  }))
}

/// Executes a strict deterministic session.
pub fn run_session(request: SessionRequest) -> SessionReport {
  if let Err(error) = request.validate() {
    return SessionReport::internal_errors(&request.programs, error.to_string());
  }
  match run_validated_session(&request) {
    Ok(report) => report,
    Err(error) => SessionReport::internal_errors(&request.programs, error.to_string()),
  }
}

fn run_validated_session(request: &SessionRequest) -> Result<SessionReport> {
  let files = wasi::Files::new(request)?;
  let mut setup_results = vec![None; request.programs.len()];
  let mut telemetry = vec![None; request.programs.len()];
  let periodic_yield = request.programs.len() > 1;
  let futures = request
    .programs
    .iter()
    .enumerate()
    .map(
      |(index, program)| match prepare_program(program, &files, periodic_yield) {
        Ok(Some(prepared)) => {
          telemetry[index] = Some(prepared.telemetry);
          Some(prepared.future)
        }
        Ok(None) => {
          setup_results[index] = Some(file_error_result(program.name.clone(), 0, 0));
          None
        }
        Err(error) => {
          files.disable_file_commits(program);
          setup_results[index] = Some(ProgramResult::internal_error(
            program.name.clone(),
            error.to_string(),
          ));
          None
        }
      },
    )
    .collect();
  let schedule = scheduler::round_robin(futures);
  let deadlocks = scheduler::deadlocks(request, &schedule.waiting);
  for (index, execution) in schedule.completed.into_iter().enumerate() {
    if let Some(execution) = execution {
      let file_error = execution.state.file_error_exceeded(&files);
      // File-limit termination is still a program result and publishes its final files.
      // Only a failure before usable guest execution protects existing destinations.
      if execution.setup_error.is_some() && !execution.state.memory.exceeded && !file_error {
        files.disable_file_commits(&request.programs[index]);
      }
      setup_results[index] = Some(if execution.state.memory.exceeded || file_error {
        wasi::classify(
          &execution.result,
          &execution.state,
          file_error,
          execution.tick,
          execution.memory,
          &request.programs[index].name,
        )
      } else if let Some(error) = execution.setup_error {
        ProgramResult::internal_error(request.programs[index].name.clone(), error)
      } else {
        wasi::classify(
          &execution.result,
          &execution.state,
          false,
          execution.tick,
          execution.memory,
          &request.programs[index].name,
        )
      });
    } else if setup_results[index].is_none() {
      let pending = telemetry[index].as_ref().unwrap().get();
      setup_results[index] = Some(pending_result(
        &request.programs[index],
        pending,
        &files,
        request,
      ));
    }
  }
  let mut results = setup_results
    .into_iter()
    .map(Option::unwrap)
    .collect::<Vec<_>>();
  if let Err(error) = files.commit() {
    apply_commit_error(&mut results, &error);
  }
  Ok(SessionReport { results, deadlocks })
}

fn file_error_result(program: String, tick: u64, memory: u64) -> ProgramResult {
  ProgramResult {
    program,
    status: RunStatus::FileError,
    tick,
    memory,
    exit_code: None,
    error_message: Some("File size limit exceeded".into()),
  }
}

fn pending_result(
  program: &ProgramRequest,
  telemetry: PendingTelemetry,
  files: &wasi::Files,
  request: &SessionRequest,
) -> ProgramResult {
  if telemetry.memory_exceeded {
    return ProgramResult {
      program: program.name.clone(),
      status: RunStatus::MemoryLimitExceeded,
      tick: 0,
      memory: telemetry.memory,
      exit_code: None,
      error_message: Some("Memory limit exceeded".into()),
    };
  }
  let file_error = request
    .files
    .iter()
    .enumerate()
    .any(|(index, file)| files.exceeded(index) && program.writes_file(file.name()));
  if file_error {
    file_error_result(program.name.clone(), 0, telemetry.memory)
  } else {
    ProgramResult {
      program: program.name.clone(),
      status: RunStatus::TimeLimitExceeded,
      tick: 0,
      memory: telemetry.memory,
      exit_code: None,
      error_message: Some("Protocol deadlock".into()),
    }
  }
}

fn apply_commit_error(results: &mut [ProgramResult], error: &anyhow::Error) {
  for result in results
    .iter_mut()
    .filter(|result| result.status == RunStatus::Accepted)
  {
    result.status = RunStatus::InternalError;
    result.exit_code = None;
    result.error_message = Some(format!("failed to commit files: {error}"));
  }
}

/// Rust-only request for local execution with inherited process endpoints.
#[derive(Clone, Debug)]
pub struct LocalProgramRequest {
  /// Authoritative source Wasm path.
  pub wasm_path: PathBuf,
  /// Arguments after synthetic `argv[0]`.
  pub arguments: Vec<String>,
  /// Guest tick ceiling.
  pub tick_limit: u64,
  /// Guest memory and stack ceiling.
  pub memory_limit: u64,
  /// Byte ceiling applied independently to inherited stdout and stderr.
  pub file_size_limit: usize,
  /// Optional ambient working directory exposed to the guest.
  pub cwd: Option<PathBuf>,
}

/// Runs one local program with inherited streams and an explicit file-size ceiling.
pub fn run_local(request: LocalProgramRequest) -> Result<ProgramResult> {
  let stack = usize::try_from(request.memory_limit)
    .context("memory_limit does not fit the host address width")?;
  let engine = Engine::new(&engine_config(stack.max(1))?)?;
  let module = load_module_path(&engine, &request.wasm_path)?;
  let mut linker = Linker::new(&engine);
  wasi::add_to_linker(&mut linker)?;
  let state = wasi::State::new_local(
    &request.arguments,
    request.memory_limit,
    request.file_size_limit,
    request.cwd.as_deref(),
  )?;
  let mut store = Box::pin(Store::new(&engine, state));
  store.limiter(|state| &mut state.memory);
  store.set_fuel(request.tick_limit)?;
  let tick_limit = request.tick_limit;
  let state = store.data() as *const wasi::State;
  let telemetry = Rc::new(Cell::new(PendingTelemetry::default()));
  let inner = async move {
    let (result, setup_error) = match linker
      .instantiate_async(store.as_mut().get_mut(), &module)
      .await
    {
      Err(error) => {
        let message = error.to_string();
        (Err(error), Some(message))
      }
      Ok(instance) => match instance.get_typed_func::<(), ()>(store.as_mut().get_mut(), "_start") {
        Err(error) => {
          let message = error.to_string();
          (Err(error), Some(message))
        }
        Ok(start) => (start.call_async(store.as_mut().get_mut(), ()).await, None),
      },
    };
    let tick = tick_limit.saturating_sub(store.get_fuel().unwrap_or(0));
    let memory = u64::try_from(store.data().memory.peak).unwrap_or(u64::MAX);
    Execution {
      result,
      setup_error,
      state: (*Pin::into_inner(store)).into_data(),
      tick,
      memory,
    }
  }
  .boxed_local();
  let future = TrackedExecutionFuture {
    inner,
    state,
    telemetry: Rc::clone(&telemetry),
  }
  .boxed_local();
  let schedule = scheduler::round_robin(vec![Some(future)]);
  let Some(execution) = schedule.completed.into_iter().next().flatten() else {
    let pending = telemetry.get();
    return Ok(ProgramResult {
      program: "local".into(),
      status: if pending.memory_exceeded {
        RunStatus::MemoryLimitExceeded
      } else if pending.local_file_error_exceeded {
        RunStatus::FileError
      } else {
        RunStatus::TimeLimitExceeded
      },
      tick: 0,
      memory: pending.memory,
      exit_code: None,
      error_message: Some(
        if pending.memory_exceeded {
          "Memory limit exceeded"
        } else if pending.local_file_error_exceeded {
          "File size limit exceeded"
        } else {
          "Protocol deadlock"
        }
        .into(),
      ),
    });
  };
  Ok(
    if execution.state.memory.exceeded || execution.state.local_file_error_exceeded() {
      wasi::classify(
        &execution.result,
        &execution.state,
        execution.state.local_file_error_exceeded(),
        execution.tick,
        execution.memory,
        "local",
      )
    } else if let Some(error) = execution.setup_error {
      ProgramResult::internal_error("local".into(), error)
    } else {
      wasi::classify(
        &execution.result,
        &execution.state,
        execution.state.local_file_error_exceeded(),
        execution.tick,
        execution.memory,
        "local",
      )
    },
  )
}

impl fmt::Display for RunStatus {
  fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
    let status = match self {
      Self::Accepted => "accepted",
      Self::RuntimeError => "runtime_error",
      Self::TimeLimitExceeded => "time_limit_exceeded",
      Self::MemoryLimitExceeded => "memory_limit_exceeded",
      Self::FileError => "file_error",
      Self::InternalError => "internal_error",
    };
    formatter.write_str(status)
  }
}

/// Writes a session report through an adjacent temporary file.
pub fn write_report(path: &Path, report: &SessionReport) -> Result<()> {
  let parent = path.parent().unwrap_or_else(|| Path::new("."));
  let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
  serde_json::to_writer(&mut temporary, report)?;
  temporary.persist(path).map_err(|error| error.error)?;
  Ok(())
}

#[cfg(test)]
mod tests {
  use std::{process::Command, sync::OnceLock};

  use super::*;

  fn file_access_module() -> PathBuf {
    static MODULE: OnceLock<Result<(tempfile::TempDir, PathBuf), String>> = OnceLock::new();
    MODULE
      .get_or_init(|| {
        let directory = tempfile::tempdir().map_err(|error| error.to_string())?;
        let output = directory.path().join("file-access.wasm");
        let status = Command::new("wasm32-wasi-wasip1-clang")
          .args(["-O2", "-std=c99", "src/runner/testdata/file_access.c", "-o"])
          .arg(&output)
          .status()
          .map_err(|error| format!("failed to start WASIp1 clang: {error}"))?;
        if !status.success() {
          return Err(format!("WASIp1 clang exited with {status}"));
        }
        Ok((directory, output))
      })
      .as_ref()
      .unwrap_or_else(|error| panic!("{error}"))
      .1
      .clone()
  }

  fn program(name: &str, wasm_path: PathBuf) -> ProgramRequest {
    ProgramRequest {
      name: name.into(),
      wasm_path,
      arguments: Vec::new(),
      tick_limit: 1_000_000,
      memory_limit: 1 << 20,
      required_accepted: false,
      file_system: FileSystem {
        directories: vec![DirectoryBinding {
          path: ".".into(),
          permissions: DirectoryPermissions::ReadExecute,
        }],
        bindings: Vec::new(),
      },
      initial_descriptors: null_descriptors(),
    }
  }

  fn null_descriptors() -> Vec<InitialDescriptor> {
    [
      FilePermissions::Read,
      FilePermissions::Write,
      FilePermissions::Write,
    ]
    .into_iter()
    .map(|permissions| InitialDescriptor {
      file: None,
      permissions,
    })
    .collect()
  }

  fn connect(program: &mut ProgramRequest, fd: usize, file: &str, permissions: FilePermissions) {
    program.initial_descriptors[fd] = InitialDescriptor {
      file: Some(file.into()),
      permissions,
    };
  }

  fn module(directory: &Path, name: &str, wat: &str) -> PathBuf {
    let path = directory.join(name);
    std::fs::write(&path, wat).unwrap();
    path
  }

  #[test]
  fn engine_accepts_mvp() {
    let engine = Engine::new(&engine_config(1024).unwrap()).unwrap();
    Module::new(&engine, b"\0asm\x01\0\0\0").unwrap();
  }

  #[test]
  fn deep_recursion_uses_memory_limit() {
    let directory = tempfile::tempdir().unwrap();
    let wasm = module(
      directory.path(),
      "deep-recursion.wat",
      r#"(module
        (func $recurse (param $depth i32) (result i32)
          local.get $depth
          i32.eqz
          if (result i32)
            i32.const 0
          else
            local.get $depth
            i32.const 1
            i32.sub
            call $recurse
            i32.const 1
            i32.add
          end)
        (func (export "_start")
          i32.const 100000
          call $recurse
          drop))"#,
    );
    let run = |memory_limit| {
      let mut recursive = program("recursive", wasm.clone());
      recursive.memory_limit = memory_limit;
      recursive.tick_limit = 10_000_000;
      run_session(SessionRequest {
        report_path: directory.path().join("report.json"),
        files: Vec::new(),
        programs: vec![recursive],
      })
      .results
      .remove(0)
    };

    let limited = run(512 * 1024);
    assert_eq!(limited.status, RunStatus::RuntimeError);
    assert!(
      limited
        .error_message
        .as_deref()
        .is_some_and(|message| message.contains("call stack exhausted"))
    );
    assert_eq!(run(16 * 1024 * 1024).status, RunStatus::Accepted);
  }

  #[test]
  fn engine_rejects_simd() {
    let engine = Engine::new(&engine_config(1024).unwrap()).unwrap();
    assert!(Module::new(&engine, "(module (func (drop (v128.const i32x4 0 0 0 0))))").is_err());
  }

  #[test]
  fn session_accepts_ignored_stdio() {
    let directory = tempfile::tempdir().unwrap();
    let wasm = module(
      directory.path(),
      "empty.wat",
      "(module (func (export \"_start\")))",
    );
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: Vec::new(),
      programs: vec![program("empty", wasm)],
    });
    assert_eq!(report.results[0].status, RunStatus::Accepted);
    assert!(report.deadlocks.is_empty());
  }

  #[test]
  fn session_latches_pipe_file_error() {
    let directory = tempfile::tempdir().unwrap();
    let writer_wasm = module(
      directory.path(),
      "write.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (data (i32.const 16) "ab")
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 2 i32.store
          i32.const 1 i32.const 0 i32.const 1 i32.const 8
          call $fd_write drop))"#,
    );
    let reader_wasm = module(
      directory.path(),
      "read-after-file-error.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop))"#,
    );
    let mut writer = program("writer", writer_wasm);
    connect(&mut writer, 1, "output", FilePermissions::Write);
    let mut reader = program("reader", reader_wasm);
    connect(&mut reader, 0, "output", FilePermissions::Read);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::pipe("output", 1, FileSizeLimit::Bytes(1))],
      programs: vec![writer, reader],
    });
    assert_eq!(report.results[0].status, RunStatus::FileError);
    assert_eq!(report.results[1].status, RunStatus::Accepted);
  }

  #[test]
  fn session_latches_mapped_file_error() {
    let directory = tempfile::tempdir().unwrap();
    let wasm = module(
      directory.path(),
      "write-file.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "path_open"
          (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (data (i32.const 64) "output_file")
        (data (i32.const 80) "ab")
        (func (export "_start")
          i32.const 3 i32.const 0 i32.const 64 i32.const 11 i32.const 9
          i64.const 64 i64.const 0 i32.const 0 i32.const 32
          call $path_open drop
          i32.const 0 i32.const 80 i32.store
          i32.const 4 i32.const 2 i32.store
          i32.const 32 i32.load i32.const 0 i32.const 1 i32.const 8
          call $fd_write drop))"#,
    );
    let mut writer = program("writer", wasm);
    writer.file_system.bindings.push(FileBinding {
      path: "output_file".into(),
      file: "output".into(),
      permissions: FilePermissions::Write,
    });
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::regular(
        "output",
        None,
        FilePermissions::Write,
        FileSizeLimit::Bytes(1),
      )],
      programs: vec![writer],
    });
    assert_eq!(report.results[0].status, RunStatus::FileError);
  }

  #[test]
  fn session_latches_sparse_file_error() {
    let directory = tempfile::tempdir().unwrap();
    let wasm = module(
      directory.path(),
      "write-sparse-file.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "path_open"
          (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_pwrite"
          (func $fd_pwrite (param i32 i32 i32 i64 i32) (result i32)))
        (memory (export "memory") 1)
        (data (i32.const 64) "output_file")
        (data (i32.const 80) "x")
        (func (export "_start")
          i32.const 3 i32.const 0 i32.const 64 i32.const 11 i32.const 9
          i64.const 68 i64.const 0 i32.const 0 i32.const 32
          call $path_open drop
          i32.const 0 i32.const 80 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 32 i32.load i32.const 0 i32.const 1 i64.const 1 i32.const 8
          call $fd_pwrite drop))"#,
    );
    let mut writer = program("writer", wasm);
    writer.file_system.bindings.push(FileBinding {
      path: "output_file".into(),
      file: "output".into(),
      permissions: FilePermissions::Write,
    });
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::regular(
        "output",
        None,
        FilePermissions::Write,
        FileSizeLimit::Bytes(1),
      )],
      programs: vec![writer],
    });
    assert_eq!(report.results[0].status, RunStatus::FileError);
  }

  #[test]
  fn initial_oversize_isolated_without_commit() {
    let directory = tempfile::tempdir().unwrap();
    let destination = directory.path().join("shared");
    std::fs::write(&destination, b"original").unwrap();
    let wasm = module(
      directory.path(),
      "empty.wat",
      "(module (func (export \"_start\")))",
    );
    let mut affected = program("affected", wasm.clone());
    affected.file_system.bindings.push(FileBinding {
      path: "shared".into(),
      file: "shared".into(),
      permissions: FilePermissions::ReadWrite,
    });
    let mut descriptor_affected = program("descriptor-affected", wasm.clone());
    connect(&mut descriptor_affected, 0, "shared", FilePermissions::Read);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::regular(
        "shared",
        Some(destination.clone()),
        FilePermissions::ReadWrite,
        FileSizeLimit::Bytes(1),
      )],
      programs: vec![affected, descriptor_affected, program("unrelated", wasm)],
    });

    assert!(report.results[..2].iter().all(|result| {
      (result.status, result.tick, result.memory) == (RunStatus::FileError, 0, 0)
    }));
    assert_eq!(report.results[2].status, RunStatus::Accepted);
    assert_eq!(std::fs::read(destination).unwrap(), b"original");
  }

  #[test]
  fn file_error_belongs_to_writer() {
    let directory = tempfile::tempdir().unwrap();
    let writer_wasm = module(
      directory.path(),
      "file-writer.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (data (i32.const 16) "ab")
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 2 i32.store
          i32.const 1 i32.const 0 i32.const 1 i32.const 8
          call $fd_write drop))"#,
    );
    let reader_wasm = module(
      directory.path(),
      "file-reader.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop))"#,
    );
    let mut writer = program("writer", writer_wasm);
    connect(&mut writer, 1, "shared", FilePermissions::Write);
    let mut reader = program("reader", reader_wasm);
    connect(&mut reader, 0, "shared", FilePermissions::Read);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::regular(
        "shared",
        None,
        FilePermissions::ReadWrite,
        FileSizeLimit::Bytes(1),
      )],
      programs: vec![writer, reader],
    });

    assert_eq!(report.results[0].status, RunStatus::FileError);
    assert_eq!(report.results[1].status, RunStatus::Accepted);
  }

  #[test]
  fn pending_memory_precedes_writer_file_error() {
    let directory = tempfile::tempdir().unwrap();
    let writer_wasm = module(
      directory.path(),
      "blocked-writer.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (data (i32.const 16) "ab")
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 2 i32.store
          i32.const 1 i32.const 0 i32.const 1 i32.const 8
          call $fd_write drop
          i32.const 4 i32.const 1 i32.store
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop))"#,
    );
    let memory_writer_wasm = module(
      directory.path(),
      "blocked-memory-writer.wat",
      &std::fs::read_to_string(&writer_wasm).unwrap().replace(
        "(func (export \"_start\")",
        "(func (export \"_start\") i32.const 1 memory.grow drop",
      ),
    );
    let peer_wasm = module(
      directory.path(),
      "blocked-peer.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop))"#,
    );
    let run = |writer_wasm, memory_limit| {
      let mut writer = program("writer", writer_wasm);
      writer.memory_limit = memory_limit;
      connect(&mut writer, 0, "left", FilePermissions::Read);
      connect(&mut writer, 1, "right", FilePermissions::Write);
      let mut peer = program("peer", peer_wasm.clone());
      connect(&mut peer, 0, "right", FilePermissions::Read);
      connect(&mut peer, 1, "left", FilePermissions::Write);
      run_session(SessionRequest {
        report_path: directory.path().join("report.json"),
        files: vec![
          File::pipe("left", 1, FileSizeLimit::Bytes(1)),
          File::pipe("right", 1, FileSizeLimit::Bytes(1)),
        ],
        programs: vec![writer, peer],
      })
    };

    let file_error = run(writer_wasm, 1 << 20);
    assert_eq!(
      file_error.results[0].status,
      RunStatus::FileError,
      "{file_error:?}"
    );
    let memory_error = run(memory_writer_wasm, 64 * 1024);
    assert_eq!(
      memory_error.results[0].status,
      RunStatus::MemoryLimitExceeded
    );
  }

  #[test]
  fn commit_error_preserves_failed_statuses() {
    let statuses = [
      RunStatus::Accepted,
      RunStatus::RuntimeError,
      RunStatus::MemoryLimitExceeded,
      RunStatus::FileError,
      RunStatus::TimeLimitExceeded,
    ];
    let mut results = statuses
      .into_iter()
      .enumerate()
      .map(|(index, status)| ProgramResult {
        program: format!("program-{index}"),
        status,
        tick: 7,
        memory: 11,
        exit_code: Some(0),
        error_message: None,
      })
      .collect::<Vec<_>>();

    apply_commit_error(&mut results, &anyhow!("commit failed"));

    assert_eq!(results[0].status, RunStatus::InternalError);
    assert_eq!(
      results[1..]
        .iter()
        .map(|result| result.status)
        .collect::<Vec<_>>(),
      statuses[1..]
    );
    assert!(results[1..].iter().all(|result| result.tick == 7));
  }

  #[test]
  fn session_pwrite_ignores_append_flag() {
    let directory = tempfile::tempdir().unwrap();
    let output_path = directory.path().join("output");
    let wasm = module(
      directory.path(),
      "pwrite-append.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "path_open"
          (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_pwrite"
          (func $fd_pwrite (param i32 i32 i32 i64 i32) (result i32)))
        (memory (export "memory") 1)
        (data (i32.const 64) "output_file")
        (data (i32.const 80) "AB")
        (func (export "_start")
          i32.const 3 i32.const 0 i32.const 64 i32.const 11 i32.const 0
          i64.const 68 i64.const 0 i32.const 1 i32.const 32
          call $path_open drop
          i32.const 0 i32.const 80 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 32 i32.load i32.const 0 i32.const 1 i32.const 8
          call $fd_write drop
          i32.const 0 i32.const 81 i32.store
          i32.const 32 i32.load i32.const 0 i32.const 1 i64.const 0 i32.const 8
          call $fd_pwrite drop))"#,
    );
    let mut writer = program("writer", wasm);
    writer.file_system.bindings.push(FileBinding {
      path: "output_file".into(),
      file: "output".into(),
      permissions: FilePermissions::Write,
    });
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::regular(
        "output",
        Some(output_path.clone()),
        FilePermissions::Write,
        FileSizeLimit::Bytes(2),
      )],
      programs: vec![writer],
    });
    assert_eq!(report.results[0].status, RunStatus::Accepted);
    assert_eq!(std::fs::read(output_path).unwrap(), b"B");
  }

  fn run_file_access(
    directory: &Path,
    mode: &str,
    initial: &[u8],
    maximum: FilePermissions,
    binding_permissions: FilePermissions,
  ) -> (ProgramResult, Vec<u8>) {
    let host_path = directory.join(format!("{mode}.data"));
    std::fs::write(&host_path, initial).unwrap();
    let mut guest = program(mode, file_access_module());
    guest.arguments = vec![mode.into(), "data".into()];
    guest.file_system.bindings.push(FileBinding {
      path: "data".into(),
      file: "data".into(),
      permissions: binding_permissions,
    });
    let report = run_session(SessionRequest {
      report_path: directory.join(format!("{mode}.json")),
      files: vec![File::regular(
        "data",
        Some(host_path.clone()),
        maximum,
        FileSizeLimit::Bytes(1024),
      )],
      programs: vec![guest],
    });
    (
      report.results.into_iter().next().unwrap(),
      std::fs::read(host_path).unwrap(),
    )
  }

  #[test]
  fn wasi_libc_combines_rdwr_truncate_and_append() {
    let directory = tempfile::tempdir().unwrap();
    for (mode, expected) in [
      ("rdwr", b"abXYef".as_slice()),
      ("trunc-rdwr", b"new".as_slice()),
      ("append-rdwr", b"ZbcdefG".as_slice()),
      ("trunc-append-rdwr", b"AB".as_slice()),
    ] {
      let (result, output) = run_file_access(
        directory.path(),
        mode,
        b"abcdef",
        FilePermissions::ReadWrite,
        FilePermissions::ReadWrite,
      );
      assert_eq!(result.status, RunStatus::Accepted, "{mode}: {result:?}");
      assert_eq!(output, expected, "{mode}");
    }
  }

  #[test]
  fn wasi_libc_enforces_open_capabilities_and_creation() {
    let directory = tempfile::tempdir().unwrap();
    let (result, output) = run_file_access(
      directory.path(),
      "downgraded-access",
      b"abcdef",
      FilePermissions::ReadWrite,
      FilePermissions::ReadWrite,
    );
    assert_eq!(result.status, RunStatus::Accepted, "{result:?}");
    assert_eq!(output, b"Qbcdef");

    for (mode, maximum, binding_access) in [
      ("deny-rdwr", FilePermissions::Read, FilePermissions::Read),
      (
        "deny-read",
        FilePermissions::ReadWrite,
        FilePermissions::Write,
      ),
      ("deny-trunc", FilePermissions::Read, FilePermissions::Read),
    ] {
      let (result, output) =
        run_file_access(directory.path(), mode, b"abcdef", maximum, binding_access);
      assert_eq!(result.status, RunStatus::Accepted, "{mode}: {result:?}");
      assert_eq!(output, b"abcdef", "{mode}");
    }

    for (mode, expected) in [
      ("create-existing", b"abcdef".as_slice()),
      ("set-append", b"abcdefG".as_slice()),
    ] {
      let (result, output) = run_file_access(
        directory.path(),
        mode,
        b"abcdef",
        FilePermissions::ReadWrite,
        FilePermissions::ReadWrite,
      );
      assert_eq!(result.status, RunStatus::Accepted, "{mode}: {result:?}");
      assert_eq!(output, expected, "{mode}");
    }
  }

  #[test]
  fn wasi_libc_uses_fd_four_beside_root_preopen() {
    let directory = tempfile::tempdir().unwrap();
    let host_path = directory.path().join("data");
    std::fs::write(&host_path, b"abcdef").unwrap();
    let mut guest = program("descriptor-four", file_access_module());
    guest.arguments = vec!["descriptor-four".into(), "data".into()];
    guest.initial_descriptors.push(InitialDescriptor {
      file: Some("data".into()),
      permissions: FilePermissions::Read,
    });
    guest.file_system.bindings.push(FileBinding {
      path: "data".into(),
      file: "data".into(),
      permissions: FilePermissions::Read,
    });
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::regular(
        "data",
        Some(host_path),
        FilePermissions::Read,
        FileSizeLimit::Bytes(1024),
      )],
      programs: vec![guest],
    });
    assert_eq!(report.results[0].status, RunStatus::Accepted, "{report:?}");
  }

  #[test]
  fn wasi_libc_nonzero_clock_wait_is_protocol_deadlock() {
    let directory = tempfile::tempdir().unwrap();
    let (immediate, _) = run_file_access(
      directory.path(),
      "poll-zero",
      b"data",
      FilePermissions::Read,
      FilePermissions::Read,
    );
    assert_eq!(immediate.status, RunStatus::Accepted, "{immediate:?}");

    let host_path = directory.path().join("clock.data");
    std::fs::write(&host_path, b"data").unwrap();
    let mut waiting = program("poll-nonzero", file_access_module());
    waiting.arguments = vec!["poll-nonzero".into(), "data".into()];
    waiting.file_system.bindings.push(FileBinding {
      path: "data".into(),
      file: "data".into(),
      permissions: FilePermissions::Read,
    });
    let report = run_session(SessionRequest {
      report_path: directory.path().join("clock.json"),
      files: vec![File::regular(
        "data",
        Some(host_path),
        FilePermissions::Read,
        FileSizeLimit::Bytes(1024),
      )],
      programs: vec![waiting],
    });
    assert_eq!(
      report.results[0].status,
      RunStatus::TimeLimitExceeded,
      "{report:?}"
    );
    assert_eq!(
      report.results[0].error_message.as_deref(),
      Some("Protocol deadlock")
    );
    assert_eq!(
      report.deadlocks,
      vec![Deadlock {
        programs: vec!["poll-nonzero".into()],
        pipes: Vec::new(),
      }]
    );
  }

  #[test]
  fn session_completes_large_vectored_write_through_short_writes() {
    let directory = tempfile::tempdir().unwrap();
    let output_path = directory.path().join("output");
    let wasm = module(
      directory.path(),
      "large-write.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
        (memory (export "memory") 4)
        (func (export "_start") (local $pointer i32) (local $remaining i32) (local $written i32)
          i32.const 1024 local.set $pointer
          i32.const 200000 local.set $remaining
          loop $write
            i32.const 0 local.get $pointer i32.store
            i32.const 4 local.get $remaining i32.store
            i32.const 1 i32.const 0 i32.const 1 i32.const 8
            call $fd_write
            if i32.const 1 call $proc_exit end
            i32.const 8 i32.load local.tee $written
            i32.eqz
            if i32.const 2 call $proc_exit end
            local.get $pointer local.get $written i32.add local.set $pointer
            local.get $remaining local.get $written i32.sub local.tee $remaining
            br_if $write
          end))"#,
    );
    let mut writer = program("writer", wasm);
    connect(&mut writer, 1, "output", FilePermissions::Write);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::regular(
        "output",
        Some(output_path.clone()),
        FilePermissions::Write,
        FileSizeLimit::Bytes(200_000),
      )],
      programs: vec![writer],
    });

    assert_eq!(report.results[0].status, RunStatus::Accepted, "{report:?}");
    let output = std::fs::read(output_path).unwrap();
    assert_eq!(output.len(), 200_000);
    assert!(output.iter().all(|byte| *byte == 0));
  }

  #[test]
  fn session_completes_large_vectored_read_through_short_reads() {
    let directory = tempfile::tempdir().unwrap();
    let input_path = directory.path().join("input");
    std::fs::write(&input_path, vec![b'x'; 200_000]).unwrap();
    let wasm = module(
      directory.path(),
      "large-read.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
        (memory (export "memory") 4)
        (func (export "_start") (local $pointer i32) (local $remaining i32) (local $read i32)
          i32.const 1024 local.set $pointer
          i32.const 200000 local.set $remaining
          loop $read_more
            i32.const 0 local.get $pointer i32.store
            i32.const 4 local.get $remaining i32.store
            i32.const 0 i32.const 0 i32.const 1 i32.const 8
            call $fd_read
            if i32.const 1 call $proc_exit end
            i32.const 8 i32.load local.tee $read
            i32.eqz
            if i32.const 2 call $proc_exit end
            local.get $pointer local.get $read i32.add local.set $pointer
            local.get $remaining local.get $read i32.sub local.tee $remaining
            br_if $read_more
          end
          i32.const 0 i32.const 1024 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read
          if i32.const 3 call $proc_exit end
          i32.const 8 i32.load
          if i32.const 4 call $proc_exit end
          i32.const 1024 i32.load8_u i32.const 120 i32.ne
          if i32.const 5 call $proc_exit end
          i32.const 201023 i32.load8_u i32.const 120 i32.ne
          if i32.const 6 call $proc_exit end))"#,
    );
    let mut reader = program("reader", wasm);
    connect(&mut reader, 0, "input", FilePermissions::Read);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::regular(
        "input",
        Some(input_path),
        FilePermissions::Read,
        FileSizeLimit::Bytes(200_000),
      )],
      programs: vec![reader],
    });
    assert_eq!(report.results[0].status, RunStatus::Accepted, "{report:?}");
  }

  #[test]
  fn zero_length_io_still_checks_descriptor_capabilities() {
    let directory = tempfile::tempdir().unwrap();
    let wasm = module(
      directory.path(),
      "zero-length-rights.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
        (memory (export "memory") 1)
        (func (export "_start")
          i32.const 0 i32.const 0 i32.const 0 i32.const 8
          call $fd_read i32.const 76 i32.ne
          if i32.const 1 call $proc_exit end
          i32.const 1 i32.const 0 i32.const 0 i32.const 8
          call $fd_write i32.const 76 i32.ne
          if i32.const 2 call $proc_exit end
          i32.const 99 i32.const 0 i32.const 0 i32.const 8
          call $fd_read i32.const 8 i32.ne
          if i32.const 3 call $proc_exit end))"#,
    );
    let mut guest = program("zero-length", wasm);
    guest.initial_descriptors[0].permissions = FilePermissions::None;
    guest.initial_descriptors[1].permissions = FilePermissions::None;
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: Vec::new(),
      programs: vec![guest],
    });
    assert_eq!(report.results[0].status, RunStatus::Accepted, "{report:?}");
  }

  #[test]
  fn setup_failures_preserve_writer_destinations() {
    let directory = tempfile::tempdir().unwrap();
    let missing_start_path = module(directory.path(), "missing-start.wat", "(module)");
    let destinations = [
      directory.path().join("load-failure.out"),
      directory.path().join("missing-start.out"),
    ];
    for destination in &destinations {
      std::fs::write(destination, b"original").unwrap();
    }
    let mut load_failure = program("load-failure", directory.path().join("missing.wasm"));
    connect(&mut load_failure, 1, "load-output", FilePermissions::Write);
    let mut missing_start = program("missing-start", missing_start_path);
    connect(
      &mut missing_start,
      1,
      "start-output",
      FilePermissions::Write,
    );
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![
        File::regular(
          "load-output",
          Some(destinations[0].clone()),
          FilePermissions::Write,
          FileSizeLimit::Bytes(1024),
        ),
        File::regular(
          "start-output",
          Some(destinations[1].clone()),
          FilePermissions::Write,
          FileSizeLimit::Bytes(1024),
        ),
      ],
      programs: vec![load_failure, missing_start],
    });
    assert!(
      report
        .results
        .iter()
        .all(|result| result.status == RunStatus::InternalError),
      "{report:?}"
    );
    for destination in destinations {
      assert_eq!(std::fs::read(destination).unwrap(), b"original");
    }
  }

  #[test]
  fn instantiation_mle_publishes_empty_outputs() {
    let directory = tempfile::tempdir().unwrap();
    let output = directory.path().join("stdout");
    let wasm = module(
      directory.path(),
      "static-memory.wat",
      "(module (memory 2) (func (export \"_start\")))",
    );
    let mut guest = program("static-memory", wasm);
    guest.memory_limit = 64 * 1024;
    connect(&mut guest, 1, "stdout", FilePermissions::Write);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::regular(
        "stdout",
        Some(output.clone()),
        FilePermissions::Write,
        FileSizeLimit::Bytes(1024),
      )],
      programs: vec![guest],
    });

    assert_eq!(report.results[0].status, RunStatus::MemoryLimitExceeded);
    assert_eq!(std::fs::read(output).unwrap(), b"");
  }

  #[test]
  fn session_classifies_missing_start_as_internal_error() {
    let directory = tempfile::tempdir().unwrap();
    let wasm = module(directory.path(), "missing-start.wat", "(module)");
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: Vec::new(),
      programs: vec![program("missing-start", wasm)],
    });
    assert_eq!(report.results[0].status, RunStatus::InternalError);
  }

  #[test]
  fn session_setup_failure_closes_pipe_writer() {
    let directory = tempfile::tempdir().unwrap();
    let writer_wasm = module(
      directory.path(),
      "invalid-writer.wat",
      r#"(module
        (import "missing" "function" (func))
        (func (export "_start")))"#,
    );
    let reader_wasm = module(
      directory.path(),
      "eof-reader.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop))"#,
    );
    let mut reader = program("reader", reader_wasm);
    connect(&mut reader, 0, "pipe", FilePermissions::Read);
    let mut writer = program("writer", writer_wasm);
    connect(&mut writer, 1, "pipe", FilePermissions::Write);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::pipe("pipe", 1, FileSizeLimit::Bytes(1))],
      programs: vec![reader, writer],
    });
    assert_eq!(report.results[0].status, RunStatus::Accepted);
    assert_eq!(report.results[1].status, RunStatus::InternalError);
    assert!(report.deadlocks.is_empty());
  }

  #[test]
  fn session_load_failure_closes_pipe_writer() {
    let directory = tempfile::tempdir().unwrap();
    let reader_wasm = module(
      directory.path(),
      "eof-after-load-failure.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop))"#,
    );
    let mut reader = program("reader", reader_wasm);
    connect(&mut reader, 0, "pipe", FilePermissions::Read);
    let mut writer = program("writer", directory.path().join("missing.wasm"));
    connect(&mut writer, 1, "pipe", FilePermissions::Write);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::pipe("pipe", 1, FileSizeLimit::Bytes(1))],
      programs: vec![reader, writer],
    });

    assert_eq!(report.results[0].status, RunStatus::Accepted);
    assert_eq!(report.results[1].status, RunStatus::InternalError);
    assert!(report.deadlocks.is_empty());
  }

  #[test]
  fn session_rejects_undeclared_file_creation() {
    let directory = tempfile::tempdir().unwrap();
    let wasm = module(
      directory.path(),
      "create-file.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "path_open"
          (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
        (memory (export "memory") 1)
        (data (i32.const 64) "output_file")
        (func (export "_start")
          i32.const 3 i32.const 0 i32.const 64 i32.const 11 i32.const 1
          i64.const 64 i64.const 0 i32.const 0 i32.const 32
          call $path_open
          i32.eqz
          if
            i32.const 1
            call $proc_exit
          end))"#,
    );
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: Vec::new(),
      programs: vec![program("writer", wasm)],
    });
    assert_eq!(report.results[0].status, RunStatus::Accepted);
  }

  #[test]
  fn session_transfers_bounded_pipe() {
    let directory = tempfile::tempdir().unwrap();
    let writer_wasm = module(
      directory.path(),
      "writer.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (data (i32.const 16) "x")
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 1 i32.const 0 i32.const 1 i32.const 8
          call $fd_write drop))"#,
    );
    let reader_wasm = module(
      directory.path(),
      "reader.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop))"#,
    );
    let mut reader = program("reader", reader_wasm);
    connect(&mut reader, 0, "pipe", FilePermissions::Read);
    let mut writer = program("writer", writer_wasm);
    connect(&mut writer, 1, "pipe", FilePermissions::Write);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::pipe("pipe", 1, FileSizeLimit::Bytes(1))],
      programs: vec![reader, writer],
    });
    assert_eq!(
      report
        .results
        .iter()
        .map(|result| result.status)
        .collect::<Vec<_>>(),
      [RunStatus::Accepted, RunStatus::Accepted]
    );
    assert!(report.deadlocks.is_empty());
  }

  #[test]
  fn session_reader_observes_eof_after_writer_exits() {
    let directory = tempfile::tempdir().unwrap();
    let writer_wasm = module(
      directory.path(),
      "writer-exits.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (data (i32.const 16) "x")
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 1 i32.const 0 i32.const 1 i32.const 8
          call $fd_write drop))"#,
    );
    let reader_wasm = module(
      directory.path(),
      "reader-until-eof.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
        (memory (export "memory") 1)
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop
          i32.const 8 i32.load i32.const 1 i32.ne
          if i32.const 1 call $proc_exit end
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop
          i32.const 8 i32.load
          if i32.const 2 call $proc_exit end))"#,
    );
    let mut reader = program("reader", reader_wasm);
    connect(&mut reader, 0, "pipe", FilePermissions::Read);
    let mut writer = program("writer", writer_wasm);
    connect(&mut writer, 1, "pipe", FilePermissions::Write);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![File::pipe("pipe", 1, FileSizeLimit::Bytes(1))],
      programs: vec![reader, writer],
    });
    assert_eq!(
      report
        .results
        .iter()
        .map(|result| result.status)
        .collect::<Vec<_>>(),
      [RunStatus::Accepted, RunStatus::Accepted]
    );
    assert!(report.deadlocks.is_empty());
  }

  #[test]
  fn session_reports_connected_deadlock() {
    let directory = tempfile::tempdir().unwrap();
    let reader_wasm = module(
      directory.path(),
      "reader.wat",
      r#"(module
        (import "wasi_snapshot_preview1" "fd_read"
          (func $fd_read (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 1)
        (func (export "_start")
          i32.const 0 i32.const 16 i32.store
          i32.const 4 i32.const 1 i32.store
          i32.const 0 i32.const 0 i32.const 1 i32.const 8
          call $fd_read drop))"#,
    );
    let mut first = program("first", reader_wasm.clone());
    connect(&mut first, 0, "left", FilePermissions::Read);
    connect(&mut first, 1, "right", FilePermissions::Write);
    let mut second = program("second", reader_wasm);
    connect(&mut second, 0, "right", FilePermissions::Read);
    connect(&mut second, 1, "left", FilePermissions::Write);
    let report = run_session(SessionRequest {
      report_path: directory.path().join("report.json"),
      files: vec![
        File::pipe("left", 1, FileSizeLimit::Bytes(1)),
        File::pipe("right", 1, FileSizeLimit::Bytes(1)),
      ],
      programs: vec![first, second],
    });
    assert_eq!(
      report
        .results
        .iter()
        .map(|result| result.status)
        .collect::<Vec<_>>(),
      [RunStatus::TimeLimitExceeded, RunStatus::TimeLimitExceeded],
      "{report:?}"
    );
    assert_eq!(
      report.deadlocks,
      vec![Deadlock {
        programs: vec!["first".into(), "second".into()],
        pipes: vec!["left".into(), "right".into()],
      }]
    );
  }
}
