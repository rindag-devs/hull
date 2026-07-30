use std::{
  collections::{BTreeMap, BTreeSet, VecDeque},
  future::Future,
  pin::Pin,
  sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
  },
  task::{Context, Poll, Wake, Waker},
};

use futures::future::LocalBoxFuture;

use super::{Deadlock, File, ProgramRequest, SessionRequest};

struct WakeFlag(AtomicBool);

impl Wake for WakeFlag {
  fn wake(self: Arc<Self>) {
    self.0.store(true, Ordering::Release);
  }

  fn wake_by_ref(self: &Arc<Self>) {
    self.0.store(true, Ordering::Release);
  }
}

struct Task<T> {
  future: LocalBoxFuture<'static, T>,
  wake: Arc<WakeFlag>,
}

/// Outcome of deterministic cooperative scheduling.
pub struct Schedule<T> {
  /// Completed values indexed by request order.
  pub completed: Vec<Option<T>>,
  /// Request indices whose futures stopped making observable progress.
  pub waiting: Vec<usize>,
}

/// Polls every runnable future once per round in stable request order.
pub fn round_robin<T>(futures: Vec<Option<LocalBoxFuture<'static, T>>>) -> Schedule<T> {
  let mut tasks = futures
    .into_iter()
    .map(|future| {
      future.map(|future| Task {
        future,
        wake: Arc::new(WakeFlag(AtomicBool::new(true))),
      })
    })
    .collect::<Vec<_>>();
  let mut completed = (0..tasks.len()).map(|_| None).collect::<Vec<_>>();

  loop {
    let mut pending = 0;
    let mut runnable = false;
    for (index, slot) in tasks.iter_mut().enumerate() {
      let Some(task) = slot else { continue };
      pending += 1;
      if !task.wake.0.swap(false, Ordering::AcqRel) {
        continue;
      }
      runnable = true;
      let waker = Waker::from(Arc::clone(&task.wake));
      let mut context = Context::from_waker(&waker);
      if let Poll::Ready(value) = Pin::new(&mut task.future).poll(&mut context) {
        completed[index] = Some(value);
        *slot = None;
      }
    }

    if pending == 0 {
      return Schedule {
        completed,
        waiting: Vec::new(),
      };
    }
    if !runnable {
      return Schedule {
        completed,
        waiting: tasks
          .iter()
          .enumerate()
          .filter_map(|(index, task)| task.is_some().then_some(index))
          .collect(),
      };
    }
  }
}

/// Builds stable connected wait components from pending programs and their pipe endpoints.
pub fn deadlocks(request: &SessionRequest, waiting: &[usize]) -> Vec<Deadlock> {
  let waiting = waiting.iter().copied().collect::<BTreeSet<_>>();
  let pipes = request
    .files
    .iter()
    .filter(|file| matches!(file, File::Pipe { .. }))
    .map(File::name)
    .collect::<BTreeSet<_>>();
  let mut program_pipes = BTreeMap::<usize, Vec<&str>>::new();
  let mut pipe_programs = BTreeMap::<&str, Vec<usize>>::new();
  for &index in &waiting {
    let program = &request.programs[index];
    for pipe in endpoints(program).filter(|name| pipes.contains(name)) {
      program_pipes.entry(index).or_default().push(pipe);
      pipe_programs.entry(pipe).or_default().push(index);
    }
  }

  let mut unseen = waiting;
  let mut components = Vec::new();
  while let Some(&first) = unseen.first() {
    let mut queue = VecDeque::from([first]);
    let mut programs = BTreeSet::new();
    let mut component_pipes = BTreeSet::new();
    unseen.remove(&first);
    while let Some(program) = queue.pop_front() {
      programs.insert(program);
      for &pipe in program_pipes.get(&program).into_iter().flatten() {
        if component_pipes.insert(pipe) {
          for &peer in pipe_programs.get(pipe).into_iter().flatten() {
            if unseen.remove(&peer) {
              queue.push_back(peer);
            }
          }
        }
      }
    }
    components.push(Deadlock {
      programs: programs
        .into_iter()
        .map(|index| request.programs[index].name.clone())
        .collect(),
      pipes: request
        .files
        .iter()
        .filter(|file| component_pipes.contains(file.name()))
        .map(|file| file.name().to_owned())
        .collect(),
    });
  }
  components
}

fn endpoints(program: &ProgramRequest) -> impl Iterator<Item = &str> {
  program
    .initial_descriptors
    .iter()
    .filter(|descriptor| {
      !matches!(
        descriptor.permissions,
        super::request::FilePermissions::None
      )
    })
    .filter_map(|descriptor| descriptor.file.as_deref())
}

#[cfg(test)]
mod tests {
  use super::super::request::{FilePermissions, InitialDescriptor};
  use super::*;
  use crate::runner::{FileSizeLimit, FileSystem};
  use futures::{FutureExt, future};

  fn program(name: &str, endpoints: &[(&str, FilePermissions)]) -> ProgramRequest {
    let mut initial_descriptors = (0..3)
      .map(|_| InitialDescriptor {
        file: None,
        permissions: FilePermissions::None,
      })
      .collect::<Vec<_>>();
    initial_descriptors.extend(
      endpoints
        .iter()
        .map(|(file, permissions)| InitialDescriptor {
          file: Some((*file).into()),
          permissions: *permissions,
        }),
    );
    ProgramRequest {
      name: name.into(),
      wasm_path: "program.wasm".into(),
      arguments: Vec::new(),
      tick_limit: 1,
      memory_limit: 1,
      required_accepted: false,
      file_system: FileSystem {
        directories: Vec::new(),
        bindings: Vec::new(),
      },
      initial_descriptors,
    }
  }

  #[test]
  fn request_order_is_stable() {
    let schedule = round_robin(vec![
      Some(future::ready(1).boxed_local()),
      Some(future::ready(2).boxed_local()),
    ]);
    assert_eq!(schedule.completed, vec![Some(1), Some(2)]);
    assert!(schedule.waiting.is_empty());
  }

  #[test]
  fn unwoken_future_is_waiting() {
    let schedule = round_robin(vec![Some(future::pending::<()>().boxed_local())]);
    assert_eq!(schedule.waiting, vec![0]);
  }

  #[test]
  fn deadlock_components_follow_request_order() {
    let request = SessionRequest {
      report_path: "report.json".into(),
      files: vec![
        File::pipe("right", 1, FileSizeLimit::Bytes(1)),
        File::pipe("left", 1, FileSizeLimit::Bytes(1)),
      ],
      programs: vec![
        program(
          "first",
          &[
            ("left", FilePermissions::Read),
            ("right", FilePermissions::Write),
          ],
        ),
        program(
          "second",
          &[
            ("right", FilePermissions::Read),
            ("left", FilePermissions::Write),
          ],
        ),
        program("independent", &[]),
      ],
    };

    assert_eq!(
      deadlocks(&request, &[2, 1, 0]),
      vec![
        Deadlock {
          programs: vec!["first".into(), "second".into()],
          pipes: vec!["right".into(), "left".into()],
        },
        Deadlock {
          programs: vec!["independent".into()],
          pipes: Vec::new(),
        },
      ]
    );
  }

  #[test]
  fn deadlock_ignores_descriptor_without_permissions() {
    let request = SessionRequest {
      report_path: "report.json".into(),
      files: vec![File::pipe("pipe", 1, FileSizeLimit::Bytes(1))],
      programs: vec![program("waiting", &[("pipe", FilePermissions::None)])],
    };

    assert_eq!(
      deadlocks(&request, &[0]),
      vec![Deadlock {
        programs: vec!["waiting".into()],
        pipes: Vec::new(),
      }]
    );
  }
}
