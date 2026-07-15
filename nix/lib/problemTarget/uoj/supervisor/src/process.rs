use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus};
use std::thread;
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_millis(50);
const TERM_GRACE: Duration = Duration::from_millis(250);
const REAP_GRACE: Duration = Duration::from_secs(1);

/// Nonblocking access to externally delivered termination signals.
pub struct SignalMonitor {
  fd: i32,
  old_mask: libc::sigset_t,
}

impl SignalMonitor {
  /// Blocks INT, TERM, and HUP and creates a nonblocking signal descriptor.
  pub fn new() -> io::Result<Self> {
    let mut mask = unsafe { std::mem::zeroed() };
    let mut old_mask = unsafe { std::mem::zeroed() };
    if unsafe { libc::sigemptyset(&mut mask) } == -1
      || unsafe { libc::sigaddset(&mut mask, libc::SIGINT) } == -1
      || unsafe { libc::sigaddset(&mut mask, libc::SIGTERM) } == -1
      || unsafe { libc::sigaddset(&mut mask, libc::SIGHUP) } == -1
      || unsafe { libc::sigprocmask(libc::SIG_BLOCK, &mask, &mut old_mask) } == -1
    {
      return Err(io::Error::last_os_error());
    }
    let fd = unsafe { libc::signalfd(-1, &mask, libc::SFD_CLOEXEC | libc::SFD_NONBLOCK) };
    if fd == -1 {
      let error = io::Error::last_os_error();
      unsafe {
        libc::sigprocmask(libc::SIG_SETMASK, &old_mask, std::ptr::null_mut());
      }
      return Err(error);
    }
    Ok(Self { fd, old_mask })
  }

  /// Returns one pending external signal without blocking.
  pub fn pending(&self) -> io::Result<Option<i32>> {
    let mut info: libc::signalfd_siginfo = unsafe { std::mem::zeroed() };
    let read = unsafe {
      libc::read(
        self.fd,
        (&mut info as *mut libc::signalfd_siginfo).cast(),
        std::mem::size_of::<libc::signalfd_siginfo>(),
      )
    };
    if read == -1 {
      let error = io::Error::last_os_error();
      if error.kind() == io::ErrorKind::WouldBlock {
        return Ok(None);
      }
      return Err(error);
    }
    if read as usize != std::mem::size_of::<libc::signalfd_siginfo>() {
      return Err(io::Error::new(
        io::ErrorKind::UnexpectedEof,
        "short signalfd read",
      ));
    }
    Ok(Some(info.ssi_signo as i32))
  }
}

impl Drop for SignalMonitor {
  fn drop(&mut self) {
    unsafe {
      libc::close(self.fd);
      libc::sigprocmask(libc::SIG_SETMASK, &self.old_mask, std::ptr::null_mut());
    }
  }
}

/// Children sharing one independently signaled process group.
pub struct ProcessGroup {
  pgid: i32,
  children: Vec<Child>,
}

impl ProcessGroup {
  /// Spawns the process-group leader with inherited termination signals unblocked.
  pub fn spawn(command: &mut Command) -> io::Result<Self> {
    configure(command, 0);
    let child = command.spawn()?;
    Ok(Self {
      pgid: child.id() as i32,
      children: vec![child],
    })
  }

  /// Spawns another direct child in this process group.
  pub fn spawn_member(&mut self, command: &mut Command) -> io::Result<usize> {
    configure(command, self.pgid);
    self.children.push(command.spawn()?);
    Ok(self.children.len() - 1)
  }

  /// Takes stdout from one direct child.
  pub fn take_stdout(&mut self, index: usize) -> Option<std::process::ChildStdout> {
    self.children[index].stdout.take()
  }

  /// Polls one direct child's exit status.
  pub fn status(&mut self, index: usize) -> io::Result<Option<ExitStatus>> {
    self.children[index].try_wait()
  }

  /// Waits by polling completion before exit and once more after observed exit.
  pub fn poll<F>(&mut self, signals: &SignalMonitor, mut complete: F) -> io::Result<RunOutcome>
  where
    F: FnMut() -> io::Result<bool>,
  {
    loop {
      if complete()? {
        return Ok(RunOutcome::Complete);
      }
      if let Some(signal) = signals.pending()? {
        return Ok(RunOutcome::Signal(signal));
      }
      if let Some(status) = self.status(0)? {
        if complete()? {
          return Ok(RunOutcome::Complete);
        }
        return Ok(RunOutcome::Exited(status));
      }
      thread::sleep(POLL);
    }
  }

  /// Sends TERM, escalates to KILL after 250 ms, and reaps for at most one second.
  pub fn terminate(&mut self) -> io::Result<()> {
    signal_group(self.pgid, libc::SIGTERM)?;
    let term_deadline = Instant::now() + TERM_GRACE;
    while Instant::now() < term_deadline {
      self.reap_direct()?;
      reap_adopted(self.pgid, term_deadline)?;
      if !group_exists(self.pgid)? {
        reap_adopted(self.pgid, term_deadline)?;
        return Ok(());
      }
      thread::sleep(Duration::from_millis(10));
    }

    signal_group(self.pgid, libc::SIGKILL)?;
    let reap_deadline = Instant::now() + REAP_GRACE;
    while Instant::now() < reap_deadline {
      self.reap_direct()?;
      reap_adopted(self.pgid, reap_deadline)?;
      if !group_exists(self.pgid)? {
        reap_adopted(self.pgid, reap_deadline)?;
        return Ok(());
      }
      thread::sleep(Duration::from_millis(10));
    }
    Err(io::Error::new(
      io::ErrorKind::TimedOut,
      format!("process group {} did not reap within deadline", self.pgid),
    ))
  }

  fn reap_direct(&mut self) -> io::Result<()> {
    for child in &mut self.children {
      let _ = child.try_wait()?;
    }
    Ok(())
  }
}

/// Result of polling a supervised direct child.
pub enum RunOutcome {
  /// A complete result marker was observed.
  Complete,
  /// The direct child exited before completing a result.
  Exited(ExitStatus),
  /// An external termination signal was observed.
  Signal(i32),
}

/// Enables adoption of orphaned descendants for bounded group cleanup.
pub fn enable_subreaper() -> io::Result<()> {
  if unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1) } == -1 {
    return Err(io::Error::last_os_error());
  }
  Ok(())
}

fn configure(command: &mut Command, pgid: i32) {
  let empty = unsafe { std::mem::zeroed() };

  unsafe {
    command.pre_exec(move || {
      if libc::sigprocmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut()) == -1 {
        return Err(io::Error::last_os_error());
      }
      if libc::setpgid(0, pgid) == -1 {
        return Err(io::Error::last_os_error());
      }
      Ok(())
    });
  }
}

fn signal_group(pgid: i32, signal: i32) -> io::Result<()> {
  if unsafe { libc::kill(-pgid, signal) } == -1 {
    let error = io::Error::last_os_error();
    if error.raw_os_error() != Some(libc::ESRCH) {
      return Err(error);
    }
  }
  Ok(())
}

fn group_exists(pgid: i32) -> io::Result<bool> {
  if unsafe { libc::kill(-pgid, 0) } == 0 {
    return Ok(true);
  }
  let error = io::Error::last_os_error();
  if error.raw_os_error() == Some(libc::ESRCH) {
    return Ok(false);
  }
  Err(error)
}

fn reap_adopted(pgid: i32, deadline: Instant) -> io::Result<bool> {
  loop {
    if Instant::now() >= deadline {
      return Ok(false);
    }
    let mut status = 0;
    let pid = unsafe { libc::waitpid(-pgid, &mut status, libc::WNOHANG) };
    if pid > 0 {
      continue;
    }
    if pid == 0 {
      return Ok(true);
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ECHILD) {
      return Ok(true);
    }
    return Err(error);
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::io::Read;
  use std::os::fd::AsRawFd;
  use std::process::Stdio;
  use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
  };

  fn ready(stdout: &mut std::process::ChildStdout) {
    let mut descriptor = libc::pollfd {
      fd: stdout.as_raw_fd(),
      events: libc::POLLIN,
      revents: 0,
    };
    assert_eq!(unsafe { libc::poll(&mut descriptor, 1, 2_000) }, 1);
    let mut bytes = [0; 5];
    stdout.read_exact(&mut bytes).unwrap();
    assert_eq!(&bytes, b"ready");
  }

  #[test]
  fn pending_before_monitor() {
    let mut hup = unsafe { std::mem::zeroed() };
    let mut original = unsafe { std::mem::zeroed() };
    assert_eq!(unsafe { libc::sigemptyset(&mut hup) }, 0);
    assert_eq!(unsafe { libc::sigaddset(&mut hup, libc::SIGHUP) }, 0);
    assert_eq!(
      unsafe { libc::sigprocmask(libc::SIG_BLOCK, &hup, &mut original) },
      0
    );
    assert_eq!(unsafe { libc::raise(libc::SIGHUP) }, 0);

    let signals = SignalMonitor::new().unwrap();
    assert_eq!(signals.pending().unwrap(), Some(libc::SIGHUP));
    drop(signals);

    assert_eq!(
      unsafe { libc::sigprocmask(libc::SIG_SETMASK, &original, std::ptr::null_mut()) },
      0
    );
  }

  #[test]
  fn completion_first() {
    let signals = SignalMonitor::new().unwrap();
    let mut command = Command::new("sh");
    command.arg("-c").arg("exit 0");
    let mut group = ProcessGroup::spawn(&mut command).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while group.status(0).unwrap().is_none() {
      assert!(
        Instant::now() < deadline,
        "child did not exit before deadline"
      );
      thread::sleep(Duration::from_millis(10));
    }
    let observed = Arc::new(AtomicBool::new(false));
    let complete = observed.clone();
    let outcome = group
      .poll(&signals, || Ok(complete.swap(true, Ordering::Relaxed)))
      .unwrap();
    assert!(matches!(outcome, RunOutcome::Complete));
    assert!(observed.load(Ordering::Relaxed));
    group.terminate().unwrap();
  }

  #[test]
  fn kills_ignorer() {
    let mut command = Command::new("sh");
    command
      .arg("-c")
      .arg("trap '' TERM; printf ready; while :; do sleep 1; done")
      .stdout(Stdio::piped());
    let mut group = ProcessGroup::spawn(&mut command).unwrap();
    let mut stdout = group.take_stdout(0).unwrap();
    ready(&mut stdout);
    let start = Instant::now();
    group.terminate().unwrap();
    assert!(start.elapsed() >= TERM_GRACE);
    assert!(start.elapsed() < Duration::from_secs(2));
  }

  #[test]
  fn reap_deadline() {
    let deadline = Instant::now() - Duration::from_millis(1);
    assert!(!reap_adopted(unsafe { libc::getpgrp() }, deadline).unwrap());
  }

  #[test]
  fn reaps_grandchild() {
    enable_subreaper().unwrap();
    let mut command = Command::new("sh");
    command
      .arg("-c")
      .arg("(trap '' TERM; while :; do sleep 1; done) & printf ready; while :; do sleep 1; done")
      .stdout(Stdio::piped());
    let mut group = ProcessGroup::spawn(&mut command).unwrap();
    let mut stdout = group.take_stdout(0).unwrap();
    ready(&mut stdout);
    group.terminate().unwrap();
  }
}
