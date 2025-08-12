pub mod judge_dir;
pub mod limited_buffer;

use std::time::{Duration, UNIX_EPOCH};

use anyhow::Result;
use rand::SeedableRng;
use serde::{Deserialize, Serialize};
use wasi_common::{
  I32Exit, Table, WasiClocks, WasiCtx, WasiDir, WasiFile, WasiSystemClock,
  pipe::{ReadPipe, WritePipe},
  sync::sched::SyncSched,
};
use wasmtime::{Config, Engine, Linker, Module, ResourceLimiter, Store, Trap};

pub use crate::runner::limited_buffer::LimitedBuffer;

#[derive(Clone, Debug)]
struct MemoryLimiter {
  memory_bytes: usize,
  memory_max_used_bytes: usize,
  memory_limit_exceeded: bool,
}

impl MemoryLimiter {
  pub fn new(memory_bytes: usize) -> Self {
    Self {
      memory_bytes,
      memory_max_used_bytes: 0,
      memory_limit_exceeded: false,
    }
  }
}

impl ResourceLimiter for MemoryLimiter {
  fn memory_growing(
    &mut self,
    _current: usize,
    desired: usize,
    _maximum: Option<usize>,
  ) -> Result<bool> {
    self.memory_max_used_bytes = self.memory_max_used_bytes.max(desired);
    let allow = desired <= self.memory_bytes;
    if !allow {
      self.memory_limit_exceeded = true
    }
    Ok(allow)
  }

  fn table_growing(
    &mut self,
    _current: usize,
    desired: usize,
    maximum: Option<usize>,
  ) -> Result<bool> {
    let allow = match maximum {
      Some(max) if desired > max => false,
      _ => true,
    };
    Ok(allow)
  }
}

struct NullSystemClock;

impl WasiSystemClock for &NullSystemClock {
  fn resolution(&self) -> std::time::Duration {
    Duration::from_nanos(1)
  }

  fn now(&self, _precision: std::time::Duration) -> cap_std::time::SystemTime {
    cap_std::time::SystemTime::from_std(UNIX_EPOCH)
  }
}

static NULL_SYSTEM_CLOCK: NullSystemClock = NullSystemClock;

struct ApplicationState {
  memory_limiter: MemoryLimiter,
  wasi_ctx: WasiCtx,
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
  InternalError,
  Accepted,
  RuntimeError,
  TimeLimitExceeded,
  MemoryLimitExceeded,
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunResult {
  pub status: RunStatus,
  pub tick: u64,
  pub memory: u64,
  pub exit_code: i32,
  pub error_message: String,
}

impl RunResult {
  fn new_internal_error(err: anyhow::Error) -> RunResult {
    Self {
      status: RunStatus::InternalError,
      tick: 0,
      memory: 0,
      exit_code: -1,
      error_message: err.to_string(),
    }
  }

  fn new_runtime_error(err: anyhow::Error) -> RunResult {
    Self {
      status: RunStatus::RuntimeError,
      tick: 0,
      memory: 0,
      exit_code: -1,
      error_message: err.to_string(),
    }
  }
}

pub fn compile(wasm: &[u8]) -> Result<Vec<u8>> {
  let engine = create_engine(512 * 1024)?;
  engine.precompile_module(wasm)
}

pub fn run(
  wasm: &[u8],
  tick_limit: u64,
  memory_limit: u64,
  stdin: Box<dyn WasiFile>,
  stdout: Box<dyn WasiFile>,
  stderr: Box<dyn WasiFile>,
  preopened_dir: Option<Box<dyn WasiDir>>,
) -> RunResult {
  let engine = match create_engine(memory_limit) {
    Ok(x) => x,
    Err(err) => return RunResult::new_internal_error(err),
  };

  let mut linker = match setup_linker(&engine) {
    Ok(x) => x,
    Err(err) => return RunResult::new_internal_error(err),
  };

  let mut store = match create_store(
    &engine,
    memory_limit,
    tick_limit,
    stdin,
    stdout,
    stderr,
    preopened_dir,
  ) {
    Ok(x) => x,
    Err(err) => return RunResult::new_internal_error(err),
  };

  let main_module = match create_main_module(&engine, wasm) {
    Ok(x) => x,
    Err(err) => return RunResult::new_internal_error(err),
  };

  let start_func = match setup_instance(&mut linker, &mut store, &main_module) {
    Ok(x) => x,
    Err(err) => return RunResult::new_internal_error(err),
  };

  match execute_and_get_results(store, start_func, tick_limit) {
    Ok(x) => x,
    Err(err) => return RunResult::new_runtime_error(err),
  }
}

pub fn run_fixed_stdio(
  wasm: &[u8],
  tick_limit: u64,
  memory_limit: u64,
  stdin_bytes: &[u8],
  stdout_limit: u64,
  stderr_limit: u64,
  preopened_dir: Option<Box<dyn WasiDir>>,
) -> Result<(RunResult, Vec<u8>, Vec<u8>)> {
  let engine = create_engine(memory_limit)?;
  let mut linker = setup_linker(&engine)?;

  let stdin = Box::new(ReadPipe::from(stdin_bytes));
  let stdout = Box::new(WritePipe::new(LimitedBuffer::new(
    stdout_limit.try_into().unwrap(),
  )));
  let stderr = Box::new(WritePipe::new(LimitedBuffer::new(
    stderr_limit.try_into().unwrap(),
  )));

  let mut store = create_store(
    &engine,
    memory_limit,
    tick_limit,
    stdin,
    stdout.clone(),
    stderr.clone(),
    preopened_dir,
  )?;

  let main_module = create_main_module(&engine, wasm)?;

  let start_func = setup_instance(&mut linker, &mut store, &main_module)?;

  let run_result = execute_and_get_results(store, start_func, tick_limit)?;

  let stdout_bytes = stdout
    .try_into_inner()
    .map_err(|_err| anyhow::Error::msg("sole remaining reference to stdout pipe"))?
    .to_vec();

  let stderr_bytes = stderr
    .try_into_inner()
    .map_err(|_err| anyhow::Error::msg("sole remaining reference to stderr pipe"))?
    .to_vec();

  Ok((run_result, stdout_bytes, stderr_bytes))
}

fn create_engine(memory_limit: u64) -> Result<Engine> {
  Engine::new(
    &Config::new()
      .consume_fuel(true)
      .wasm_bulk_memory(false)
      .wasm_custom_page_sizes(false)
      .wasm_extended_const(false)
      .wasm_memory64(false)
      .wasm_multi_memory(false)
      .wasm_multi_value(false)
      .wasm_relaxed_simd(false)
      .wasm_shared_everything_threads(false)
      .wasm_simd(false)
      .wasm_stack_switching(false)
      .wasm_tail_call(false)
      .wasm_wide_arithmetic(false)
      .max_wasm_stack(memory_limit.try_into().unwrap())
      .strategy(wasmtime::Strategy::Cranelift)
      .profiler(wasmtime::ProfilingStrategy::None)
      .cranelift_opt_level(wasmtime::OptLevel::Speed),
  )
}

fn setup_linker(engine: &Engine) -> Result<Linker<ApplicationState>> {
  let mut linker = Linker::new(engine);
  wasi_common::sync::add_to_linker(&mut linker, |state: &mut ApplicationState| {
    &mut state.wasi_ctx
  })?;
  Ok(linker)
}

fn create_store(
  engine: &Engine,
  memory_limit: u64,
  tick_limit: u64,
  stdin: Box<dyn WasiFile>,
  stdout: Box<dyn WasiFile>,
  stderr: Box<dyn WasiFile>,
  preopened_dir: Option<Box<dyn WasiDir>>,
) -> Result<Store<ApplicationState>> {
  let random = Box::new(rand::rngs::StdRng::seed_from_u64(0));
  let clocks = WasiClocks::new().with_system(&NULL_SYSTEM_CLOCK);
  let wasi_ctx = WasiCtx::new(random, clocks, Box::new(SyncSched::new()), Table::new());
  wasi_ctx.set_stdin(stdin);
  wasi_ctx.set_stdout(stdout);
  wasi_ctx.set_stderr(stderr);
  if let Some(dir) = preopened_dir {
    wasi_ctx.push_preopened_dir(dir, "/")?;
  };

  let state = ApplicationState {
    memory_limiter: MemoryLimiter::new(memory_limit.try_into().unwrap()),
    wasi_ctx,
  };
  let mut store = Store::new(engine, state);
  store.limiter(|state| &mut state.memory_limiter);
  store.set_fuel(tick_limit)?;
  Ok(store)
}

fn create_main_module(engine: &Engine, wasm: &[u8]) -> Result<Module> {
  let main_module = if let Some(..) = Engine::detect_precompiled(wasm) {
    unsafe { Module::deserialize(engine, wasm)? }
  } else {
    Module::new(engine, wasm)?
  };

  Ok(main_module)
}

fn setup_instance(
  linker: &mut Linker<ApplicationState>,
  store: &mut Store<ApplicationState>,
  main_module: &Module,
) -> Result<wasmtime::TypedFunc<(), ()>> {
  let instance = linker.instantiate(&mut *store, main_module)?;
  linker.instance(&mut *store, "", instance)?;
  linker.get_default(&mut *store, "")?.typed(store)
}

fn execute_and_get_results(
  mut store: Store<ApplicationState>,
  start_func: wasmtime::TypedFunc<(), ()>,
  tick_limit: u64,
) -> Result<RunResult> {
  let main_call_result = start_func.call(&mut store, ());

  let tick = tick_limit - store.get_fuel()?;

  let memory_limiter = store.data().memory_limiter.clone();
  let memory = memory_limiter.memory_max_used_bytes.try_into().unwrap();
  let mut exit_code: i32 = 0;

  let status = if main_call_result.is_ok() {
    RunStatus::Accepted
  } else if memory_limiter.memory_limit_exceeded {
    RunStatus::MemoryLimitExceeded
  } else {
    // Check if the error is due to out of fuel.
    let err = main_call_result.unwrap_err();
    if let Some(trap) = err.downcast_ref::<Trap>() {
      if *trap == Trap::OutOfFuel {
        RunStatus::TimeLimitExceeded
      } else {
        // If it's another type of trap, return the error.
        return Err(err);
      }
    } else if let Some(exit) = err.downcast_ref::<I32Exit>() {
      exit_code = exit.0;
      RunStatus::RuntimeError
    } else {
      // If it's not a trap, return the error.
      return Err(err);
    }
  };

  drop(store); // Drop the store to ensure all resources are released before getting buffer contents.

  Ok(RunResult {
    status,
    tick,
    memory,
    exit_code,
    error_message: String::new(),
  })
}
