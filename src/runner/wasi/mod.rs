#![allow(clippy::too_many_arguments)]

use std::{
  collections::{BTreeMap, VecDeque},
  fmt,
  future::poll_fn,
  io::{Read, Seek, SeekFrom, Write},
  path::{Component, Path, PathBuf},
  sync::{Arc, Mutex},
  task::{Poll, Waker},
};

use anyhow::{Context, Result, anyhow};
use cap_std::{ambient_authority, fs::Dir};
use rand::{SeedableRng, TryRng, rngs::Xoshiro256PlusPlus};
use wasmtime::{Linker, ResourceLimiter};
use wiggle::{GuestMemory, GuestPtr};

use super::request::{DirectoryPermissions, FilePermissions};
use super::{File, ProgramRequest, ProgramResult, RunStatus, SessionRequest};

wiggle::from_witx!({
  witx: ["src/runner/wasi/witx/wasi_snapshot_preview1.witx"],
  async: *,
  errors: { errno => trappable Error },
});

impl wiggle::GuestErrorType for types::Errno {
  fn success() -> Self {
    Self::Success
  }
}

impl From<wiggle::GuestError> for types::Error {
  fn from(error: wiggle::GuestError) -> Self {
    use wiggle::GuestError::{InvalidEnumValue, InvalidFlagValue, InvalidUtf8, TryFromIntError};
    match error {
      InvalidEnumValue { .. } | InvalidFlagValue { .. } => types::Errno::Inval.into(),
      InvalidUtf8 { .. } => types::Errno::Ilseq.into(),
      TryFromIntError { .. } => types::Errno::Overflow.into(),
      error => types::Error::trap(error.into()),
    }
  }
}

type WasiResult<T> = std::result::Result<T, types::Error>;

const COPY_BUFFER_SIZE: usize = 64 * 1024;
const FILE_PAGE_SIZE: usize = 64 * 1024;

fn errno(errno: types::Errno) -> types::Error {
  errno.into()
}

/// Tracks the linear-memory ceiling and peak growth request.
#[derive(Clone, Debug)]
pub struct MemoryLimiter {
  limit: usize,
  /// Largest requested linear-memory size.
  pub peak: usize,
  /// Whether a growth request crossed the ceiling.
  pub exceeded: bool,
}

impl ResourceLimiter for MemoryLimiter {
  fn memory_growing(
    &mut self,
    _current: usize,
    desired: usize,
    _maximum: Option<usize>,
  ) -> wasmtime::Result<bool> {
    self.peak = self.peak.max(desired);
    self.exceeded |= desired > self.limit;
    Ok(!self.exceeded)
  }

  fn table_growing(
    &mut self,
    _current: usize,
    desired: usize,
    maximum: Option<usize>,
  ) -> wasmtime::Result<bool> {
    Ok(maximum.is_none_or(|maximum| desired <= maximum))
  }
}

#[derive(Debug)]
enum SharedFile {
  Regular(RegularFile),
  Pipe(Pipe),
}

#[derive(Debug)]
struct RegularFile {
  destination: Option<PathBuf>,
  commit_enabled: bool,
  backing: Option<std::fs::File>,
  backing_visible_length: u64,
  length: u64,
  size_limit: u64,
  exceeded: bool,
  initial_exceeded: bool,
  pages: BTreeMap<u64, FilePage>,
}

#[derive(Debug)]
struct FilePage {
  bytes: Box<[u8; FILE_PAGE_SIZE]>,
  dirty: bool,
}

impl RegularFile {
  fn empty(destination: Option<PathBuf>, size_limit: u64) -> Self {
    Self {
      destination,
      commit_enabled: true,
      backing: None,
      backing_visible_length: 0,
      length: 0,
      size_limit,
      exceeded: false,
      initial_exceeded: false,
      pages: BTreeMap::new(),
    }
  }

  fn snapshot(source: &Path, destination: Option<PathBuf>, size_limit: u64) -> Result<Self> {
    // Validate and snapshot the same opened object. Path metadata followed by a separate open
    // would let a host-side replacement bypass the regular-file and size checks.
    let source_file = std::fs::File::open(source)?;
    let metadata = source_file.metadata()?;
    if !metadata.file_type().is_file() {
      return Err(anyhow!(
        "regular file must be backed by a regular host file: {}",
        source.display()
      ));
    }
    if metadata.len() > size_limit {
      return Ok(Self {
        destination,
        commit_enabled: true,
        backing: None,
        backing_visible_length: 0,
        length: metadata.len(),
        size_limit,
        exceeded: true,
        initial_exceeded: true,
        pages: BTreeMap::new(),
      });
    }
    let mut backing = tempfile::tempfile()?;
    // The private copy makes every guest alias observe one session-start snapshot even if the
    // host source changes while programs run. Copying at most size_limit + 1 bytes also prevents a
    // concurrently growing host file from consuming unbounded temporary storage before FE.
    let length = std::io::copy(
      &mut source_file.take(size_limit.saturating_add(1)),
      &mut backing,
    )?;
    Ok(Self {
      destination,
      commit_enabled: true,
      backing: Some(backing),
      backing_visible_length: length,
      length,
      size_limit,
      exceeded: length > size_limit,
      initial_exceeded: length > size_limit,
      pages: BTreeMap::new(),
    })
  }

  fn page(&mut self, index: u64) -> std::io::Result<&mut FilePage> {
    if !self.pages.contains_key(&index) {
      let mut page = Box::new([0; FILE_PAGE_SIZE]);
      let offset = index.saturating_mul(FILE_PAGE_SIZE as u64);
      if offset < self.backing_visible_length
        && let Some(backing) = &mut self.backing
      {
        backing.seek(SeekFrom::Start(offset))?;
        let visible = usize::try_from(self.backing_visible_length - offset)
          .unwrap_or(usize::MAX)
          .min(FILE_PAGE_SIZE);
        backing.read_exact(&mut page[..visible])?;
      }
      self.pages.insert(
        index,
        FilePage {
          bytes: page,
          dirty: false,
        },
      );
    }
    Ok(self.pages.get_mut(&index).unwrap())
  }

  fn read(&mut self, offset: u64, capacity: usize) -> std::io::Result<Vec<u8>> {
    if offset >= self.length || capacity == 0 {
      return Ok(Vec::new());
    }
    let count = usize::try_from(self.length - offset)
      .unwrap_or(usize::MAX)
      .min(capacity);
    let mut bytes = vec![0; count];
    let mut copied = 0;
    while copied < count {
      let position = offset + copied as u64;
      let index = position / FILE_PAGE_SIZE as u64;
      let within = position as usize % FILE_PAGE_SIZE;
      let amount = (FILE_PAGE_SIZE - within).min(count - copied);
      bytes[copied..copied + amount]
        .copy_from_slice(&self.page(index)?.bytes[within..within + amount]);
      copied += amount;
    }
    Ok(bytes)
  }

  fn write(&mut self, offset: u64, bytes: &[u8]) -> WasiResult<usize> {
    let requested = u64::try_from(bytes.len()).map_err(|_| errno(types::Errno::Overflow))?;
    let Some(end) = offset.checked_add(requested) else {
      self.exceeded = true;
      return Err(errno(types::Errno::Fbig));
    };
    if end > self.size_limit {
      self.exceeded = true;
      return Err(errno(types::Errno::Fbig));
    }
    let mut copied = 0;
    while copied < bytes.len() {
      let position = offset + copied as u64;
      let index = position / FILE_PAGE_SIZE as u64;
      let within = position as usize % FILE_PAGE_SIZE;
      let amount = (FILE_PAGE_SIZE - within).min(bytes.len() - copied);
      if within == 0 && amount == FILE_PAGE_SIZE {
        let mut page = Box::new([0; FILE_PAGE_SIZE]);
        page.copy_from_slice(&bytes[copied..copied + amount]);
        self.pages.insert(
          index,
          FilePage {
            bytes: page,
            dirty: true,
          },
        );
      } else {
        let page = self.page(index).map_err(|_| errno(types::Errno::Io))?;
        page.bytes[within..within + amount].copy_from_slice(&bytes[copied..copied + amount]);
        page.dirty = true;
      }
      copied += amount;
    }
    self.length = self.length.max(end);
    Ok(bytes.len())
  }

  fn resize(&mut self, size: u64) -> WasiResult<()> {
    if size > self.size_limit {
      self.exceeded = true;
      return Err(errno(types::Errno::Fbig));
    }
    if size < self.length {
      let first_removed = size.div_ceil(FILE_PAGE_SIZE as u64);
      self.pages.split_off(&first_removed);
      let within = size as usize % FILE_PAGE_SIZE;
      if within != 0 {
        let index = size / FILE_PAGE_SIZE as u64;
        let page = self.page(index).map_err(|_| errno(types::Errno::Io))?;
        page.bytes[within..].fill(0);
        page.dirty = true;
      }
      // Bytes discarded by truncate must stay hidden if a later truncate grows the file again.
      self.backing_visible_length = self.backing_visible_length.min(size);
    }
    self.length = size;
    Ok(())
  }

  fn materialize(mut self) -> Result<Option<(PathBuf, tempfile::NamedTempFile)>> {
    if self.initial_exceeded || !self.commit_enabled {
      return Ok(None);
    }
    let Some(destination) = self.destination.take() else {
      return Ok(None);
    };
    let parent = destination.parent().unwrap_or_else(|| Path::new("."));
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary.as_file_mut().set_len(self.length)?;
    if let Some(backing) = &mut self.backing {
      backing.seek(SeekFrom::Start(0))?;
      let mut remaining = self.backing_visible_length.min(self.length);
      let mut buffer = vec![0; COPY_BUFFER_SIZE];
      while remaining != 0 {
        let count = usize::try_from(remaining)
          .unwrap_or(usize::MAX)
          .min(buffer.len());
        backing.read_exact(&mut buffer[..count])?;
        temporary.as_file_mut().write_all(&buffer[..count])?;
        remaining -= count as u64;
      }
    }
    for (index, page) in self.pages.into_iter().filter(|(_, page)| page.dirty) {
      let offset = index * FILE_PAGE_SIZE as u64;
      if offset >= self.length {
        continue;
      }
      let count = usize::try_from(self.length - offset)
        .unwrap_or(usize::MAX)
        .min(FILE_PAGE_SIZE);
      temporary.as_file_mut().seek(SeekFrom::Start(offset))?;
      temporary.as_file_mut().write_all(&page.bytes[..count])?;
    }
    temporary.as_file_mut().set_len(self.length)?;
    Ok(Some((destination, temporary)))
  }
}

#[derive(Debug)]
struct Pipe {
  bytes: VecDeque<u8>,
  capacity: usize,
  stream_length: u64,
  size_limit: u64,
  exceeded: bool,
  readers: usize,
  writers: usize,
  read_waiters: Vec<Waker>,
  write_waiters: Vec<Waker>,
}

/// Shared snapshotted files for one session.
#[derive(Debug)]
pub struct Files {
  names: Vec<String>,
  entries: Vec<Arc<Mutex<SharedFile>>>,
}

impl Files {
  /// Creates snapshotted files and bounded pipes for one session.
  pub fn new(request: &SessionRequest) -> Result<Self> {
    let mut names = Vec::with_capacity(request.files.len());
    let mut entries = Vec::with_capacity(request.files.len());
    for file in &request.files {
      names.push(file.name().to_owned());
      let entry = match file {
        File::Regular {
          host_path,
          max_permissions,
          size_limit,
          ..
        } => {
          let size_limit = u64::try_from(size_limit.resolve()?).unwrap_or(u64::MAX);
          let destination = permissions_allow_write(*max_permissions)
            .then(|| host_path.clone())
            .flatten();
          if permissions_allow_read(*max_permissions)
            && let Some(host_path) = host_path
          {
            SharedFile::Regular(RegularFile::snapshot(host_path, destination, size_limit)?)
          } else {
            // A write-only mapping deliberately ignores an existing destination: the guest's
            // working file starts empty and commit atomically replaces the old host contents.
            SharedFile::Regular(RegularFile::empty(destination, size_limit))
          }
        }
        File::Pipe {
          capacity,
          size_limit,
          ..
        } => SharedFile::Pipe(Pipe {
          bytes: VecDeque::new(),
          capacity: usize::try_from(*capacity).context("pipe capacity does not fit host")?,
          stream_length: 0,
          size_limit: u64::try_from(size_limit.resolve()?).unwrap_or(u64::MAX),
          exceeded: false,
          readers: 0,
          writers: 0,
          read_waiters: Vec::new(),
          write_waiters: Vec::new(),
        }),
      };
      entries.push(Arc::new(Mutex::new(entry)));
    }
    Ok(Self { names, entries })
  }

  fn index(&self, name: &str) -> Option<usize> {
    self.names.iter().position(|candidate| candidate == name)
  }

  fn entry(&self, name: &str) -> Result<(usize, Arc<Mutex<SharedFile>>)> {
    let index = self
      .index(name)
      .ok_or_else(|| anyhow!("unknown file `{name}`"))?;
    Ok((index, Arc::clone(&self.entries[index])))
  }

  /// Publishes host-backed files and restores prior destinations on failure.
  pub fn commit(self) -> Result<()> {
    let mut files = Vec::new();
    for entry in self.entries {
      let mutex = Arc::try_unwrap(entry).map_err(|_| anyhow!("file is still open"))?;
      if let SharedFile::Regular(file) = mutex.into_inner().unwrap()
        && let Some(materialized) = file.materialize()?
      {
        files.push(materialized);
      }
    }
    let mut backups = Vec::with_capacity(files.len());
    for (destination, _) in &files {
      let backup = if destination.exists() {
        if !destination.is_file() {
          restore_backups(&files, &backups);
          return Err(anyhow!(
            "file destination is not a regular file: {}",
            destination.display()
          ));
        }
        let backup = match tempfile::NamedTempFile::new_in(
          destination.parent().unwrap_or_else(|| Path::new(".")),
        ) {
          Ok(backup) => backup.into_temp_path(),
          Err(error) => {
            restore_backups(&files, &backups);
            return Err(error.into());
          }
        };
        if let Err(error) =
          std::fs::remove_file(&backup).and_then(|()| std::fs::rename(destination, &backup))
        {
          restore_backups(&files, &backups);
          return Err(error.into());
        }
        Some(backup)
      } else {
        None
      };
      backups.push(backup);
    }
    let destinations = files
      .iter()
      .map(|(destination, _)| destination.clone())
      .collect::<Vec<_>>();
    for (index, (destination, temporary)) in files.into_iter().enumerate() {
      if let Err(error) = temporary.persist(&destination) {
        for published in &destinations[..=index] {
          let _ = std::fs::remove_file(published);
        }
        for (rollback_destination, backup) in destinations.iter().zip(backups) {
          if let Some(backup) = backup {
            let _ = std::fs::rename(&backup, rollback_destination);
          }
        }
        return Err(error.error.into());
      }
    }
    Ok(())
  }

  /// Prevents host publication for files owned by a program that failed before guest execution.
  pub fn disable_file_commits(&self, program: &ProgramRequest) {
    for (index, name) in self.names.iter().enumerate() {
      if !program.writes_file(name) {
        continue;
      }
      if let SharedFile::Regular(file) = &mut *self.entries[index].lock().unwrap() {
        file.commit_enabled = false;
      }
    }
  }

  /// Returns whether a named file or pipe exceeded its size limit.
  pub fn exceeded(&self, index: usize) -> bool {
    match &*self.entries[index].lock().unwrap() {
      SharedFile::Regular(file) => file.exceeded,
      SharedFile::Pipe(pipe) => pipe.exceeded,
    }
  }

  fn initial_exceeded(&self, index: usize) -> bool {
    matches!(
      &*self.entries[index].lock().unwrap(),
      SharedFile::Regular(RegularFile {
        initial_exceeded: true,
        ..
      })
    )
  }
}

fn restore_backups(
  files: &[(PathBuf, tempfile::NamedTempFile)],
  backups: &[Option<tempfile::TempPath>],
) {
  for ((destination, _), backup) in files.iter().zip(backups) {
    if let Some(backup) = backup {
      let _ = std::fs::rename(backup, destination);
    }
  }
}

#[derive(Clone, Debug)]
enum DescriptorKind {
  File {
    file: Arc<Mutex<SharedFile>>,
  },
  Directory {
    path: String,
  },
  Null,
  HostStdin,
  HostOutput {
    stderr: bool,
    stream_length: u64,
    size_limit: u64,
    exceeded: bool,
  },
  AmbientDirectory {
    root: Arc<HostDirectory>,
    path: PathBuf,
  },
  AmbientFile {
    file: Arc<Mutex<cap_std::fs::File>>,
    path: PathBuf,
  },
}

struct HostDirectory(Dir);

impl fmt::Debug for HostDirectory {
  fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
    formatter.write_str("HostDirectory(..)")
  }
}

#[derive(Clone, Debug)]
struct Descriptor {
  kind: DescriptorKind,
  pipe_roles: Option<PipeRoles>,
  position: u64,
  rights: types::Rights,
  inheriting: types::Rights,
  flags: types::Fdflags,
  preopen: Option<String>,
}

#[derive(Clone, Copy, Debug, Default)]
struct PipeRoles {
  reader: bool,
  writer: bool,
}

#[derive(Clone, Debug)]
struct Node {
  kind: NodeKind,
  permissions: FilePermissions,
  path_access: bool,
  inode: u64,
}

#[derive(Clone, Debug)]
enum NodeKind {
  Directory,
  Regular { file: Arc<Mutex<SharedFile>> },
}

/// Store-local deterministic Preview1 state.
#[derive(Debug)]
pub struct State {
  /// Linear-memory limiter used by the Wasmtime store.
  pub memory: MemoryLimiter,
  arguments: Vec<Vec<u8>>,
  random: Xoshiro256PlusPlus,
  descriptors: BTreeMap<u32, Descriptor>,
  nodes: BTreeMap<String, Node>,
  writable_files: Vec<usize>,
  initial_files: Vec<usize>,
  hostcall_fuel: usize,
}

impl State {
  /// Creates deterministic state after request validation.
  pub fn new(program: &ProgramRequest, files: &Files) -> Result<Self> {
    let limit = usize::try_from(program.memory_limit).context("memory_limit does not fit host")?;
    let mut arguments = vec![b"arg0\0".to_vec()];
    for argument in &program.arguments {
      if argument.as_bytes().contains(&0) {
        return Err(anyhow!("argument contains NUL"));
      }
      let mut bytes = argument.as_bytes().to_vec();
      bytes.push(0);
      arguments.push(bytes);
    }
    let mut descriptors = BTreeMap::new();
    let mut writable_files = Vec::new();
    let mut initial_files = Vec::new();
    for (index, initial) in program.initial_descriptors.iter().enumerate() {
      let fd = if index < 3 { index } else { index + 1 };
      let fd = u32::try_from(fd).context("initial descriptor fd does not fit u32")?;
      if let Some(name) = initial.file.as_deref() {
        let (index, file) = files.entry(name)?;
        let (rights, pipe_roles) = match &mut *file.lock().unwrap() {
          SharedFile::Pipe(pipe) => {
            let roles = PipeRoles {
              reader: permissions_allow_read(initial.permissions),
              writer: permissions_allow_write(initial.permissions),
            };
            if roles.reader {
              pipe.readers += 1;
            }
            if roles.writer {
              pipe.writers += 1;
              writable_files.push(index);
            }
            (stream_rights(initial.permissions), Some(roles))
          }
          SharedFile::Regular(_) => {
            initial_files.push(index);
            if permissions_allow_write(initial.permissions) {
              writable_files.push(index);
            }
            (file_rights(initial.permissions), None)
          }
        };
        descriptors.insert(
          fd,
          Descriptor {
            kind: DescriptorKind::File { file },
            pipe_roles,
            position: 0,
            rights,
            inheriting: types::Rights::empty(),
            flags: types::Fdflags::empty(),
            preopen: None,
          },
        );
      } else {
        let rights = stream_rights(initial.permissions);
        descriptors.insert(
          fd,
          Descriptor {
            kind: DescriptorKind::Null,
            pipe_roles: None,
            position: 0,
            rights,
            inheriting: types::Rights::empty(),
            flags: types::Fdflags::empty(),
            preopen: None,
          },
        );
      }
    }
    let mut nodes = BTreeMap::new();
    for (inode, directory) in program.file_system.directories.iter().enumerate() {
      nodes.insert(
        directory.path.clone(),
        Node {
          kind: NodeKind::Directory,
          permissions: match directory.permissions {
            DirectoryPermissions::None | DirectoryPermissions::Execute => FilePermissions::None,
            DirectoryPermissions::Read | DirectoryPermissions::ReadExecute => FilePermissions::Read,
          },
          path_access: matches!(
            directory.permissions,
            DirectoryPermissions::Execute | DirectoryPermissions::ReadExecute
          ),
          inode: u64::try_from(inode + 1).unwrap(),
        },
      );
    }
    for binding in &program.file_system.bindings {
      let (index, file) = files.entry(&binding.file)?;
      initial_files.push(index);
      if permissions_allow_write(binding.permissions) {
        writable_files.push(index);
      }
      nodes.insert(
        binding.path.clone(),
        Node {
          kind: NodeKind::Regular { file },
          permissions: binding.permissions,
          path_access: false,
          inode: stable_inode(&binding.path),
        },
      );
    }
    let root_rights = nodes
      .get(".")
      .map_or_else(types::Rights::empty, node_rights);
    let mut inheriting = nodes.values().fold(types::Rights::empty(), |rights, node| {
      rights | node_rights(node)
    });
    if nodes
      .values()
      .any(|node| matches!(node.kind, NodeKind::Regular { .. }))
    {
      // wasi-libc intersects open-mode rights with the preopen's inheriting rights before calling
      // path_open. Advertise the complete regular-file ABI here so O_RDWR reaches path_open
      // intact; the selected node's permissions remain the authoritative capability check.
      inheriting |= file_rights(FilePermissions::ReadWrite);
    }
    // wasi-libc scans preopens from fd 3 and stops at the first BADF. Keeping the root at fd 3
    // prevents extra initial descriptors from hiding the filesystem preopen.
    descriptors.insert(
      3,
      Descriptor {
        kind: DescriptorKind::Directory { path: ".".into() },
        pipe_roles: None,
        position: 0,
        rights: root_rights,
        inheriting,
        flags: types::Fdflags::empty(),
        preopen: Some(".".into()),
      },
    );
    Ok(Self {
      memory: MemoryLimiter {
        limit,
        peak: 0,
        exceeded: false,
      },
      arguments,
      random: Xoshiro256PlusPlus::seed_from_u64(0),
      descriptors,
      nodes,
      writable_files,
      initial_files,
      hostcall_fuel: 0,
    })
  }

  /// Closes every live descriptor so connected peers observe EOF or broken pipes.
  pub fn close_descriptors(&mut self) {
    for descriptor in std::mem::take(&mut self.descriptors).into_values() {
      close_descriptor(descriptor);
    }
    self.nodes.clear();
  }

  /// Creates host-only state with live inherited streams and an optional ambient directory.
  pub fn new_local(
    arguments: &[String],
    memory_limit: u64,
    file_size_limit: usize,
    cwd: Option<&Path>,
  ) -> Result<Self> {
    let limit = usize::try_from(memory_limit).context("memory_limit does not fit host")?;
    let mut encoded_arguments = vec![b"arg0\0".to_vec()];
    for argument in arguments {
      if argument.as_bytes().contains(&0) {
        return Err(anyhow!("argument contains NUL"));
      }
      let mut bytes = argument.as_bytes().to_vec();
      bytes.push(0);
      encoded_arguments.push(bytes);
    }
    let file_size_limit =
      u64::try_from(file_size_limit).context("file size limit does not fit u64")?;
    let mut descriptors = BTreeMap::from([
      (
        0,
        host_descriptor(DescriptorKind::HostStdin, types::Rights::FD_READ),
      ),
      (
        1,
        host_descriptor(
          DescriptorKind::HostOutput {
            stderr: false,
            stream_length: 0,
            size_limit: file_size_limit,
            exceeded: false,
          },
          types::Rights::FD_WRITE,
        ),
      ),
      (
        2,
        host_descriptor(
          DescriptorKind::HostOutput {
            stderr: true,
            stream_length: 0,
            size_limit: file_size_limit,
            exceeded: false,
          },
          types::Rights::FD_WRITE,
        ),
      ),
    ]);
    if let Some(cwd) = cwd {
      let canonical = std::fs::canonicalize(cwd)
        .with_context(|| format!("failed to open ambient cwd {}", cwd.display()))?;
      if !canonical.is_dir() {
        return Err(anyhow!("ambient cwd is not a directory: {}", cwd.display()));
      }
      let root = Arc::new(HostDirectory(
        Dir::open_ambient_dir(&canonical, ambient_authority())
          .with_context(|| format!("failed to open ambient cwd {}", cwd.display()))?,
      ));
      let rights = ambient_directory_rights();
      descriptors.insert(
        3,
        Descriptor {
          kind: DescriptorKind::AmbientDirectory {
            root,
            path: PathBuf::new(),
          },
          pipe_roles: None,
          position: 0,
          rights,
          inheriting: rights | ambient_file_rights(),
          flags: types::Fdflags::empty(),
          preopen: Some(".".into()),
        },
      );
    }
    Ok(Self {
      memory: MemoryLimiter {
        limit,
        peak: 0,
        exceeded: false,
      },
      arguments: encoded_arguments,
      random: Xoshiro256PlusPlus::seed_from_u64(0),
      descriptors,
      nodes: BTreeMap::new(),
      writable_files: Vec::new(),
      initial_files: Vec::new(),
      hostcall_fuel: 0,
    })
  }

  /// Reports whether inherited stdout or stderr crossed its byte ceiling.
  pub fn local_file_error_exceeded(&self) -> bool {
    self.descriptors.values().any(|descriptor| {
      matches!(
        descriptor.kind,
        DescriptorKind::HostOutput { exceeded: true, .. }
      )
    })
  }

  /// Reports whether this program owns a latched file error.
  pub fn file_error_exceeded(&self, files: &Files) -> bool {
    self
      .initial_files
      .iter()
      .any(|index| files.initial_exceeded(*index))
      || self
        .writable_files
        .iter()
        .any(|index| files.exceeded(*index))
  }

  fn descriptor(&self, fd: u32) -> WasiResult<&Descriptor> {
    self
      .descriptors
      .get(&fd)
      .ok_or_else(|| errno(types::Errno::Badf))
  }

  fn descriptor_mut(&mut self, fd: u32) -> WasiResult<&mut Descriptor> {
    self
      .descriptors
      .get_mut(&fd)
      .ok_or_else(|| errno(types::Errno::Badf))
  }

  fn next_fd(&self) -> u32 {
    (4..).find(|fd| !self.descriptors.contains_key(fd)).unwrap()
  }

  fn read_path(&self, memory: &GuestMemory<'_>, path: GuestPtr<str>) -> WasiResult<String> {
    let path = memory.as_cow_str(path)?.into_owned();
    normalize(&path).ok_or_else(|| errno(types::Errno::Notcapable))
  }

  fn directory_path(&self, fd: u32, required: types::Rights) -> WasiResult<&str> {
    let descriptor = self.descriptor(fd)?;
    if !descriptor.rights.contains(required) {
      return Err(errno(types::Errno::Notcapable));
    }
    match &descriptor.kind {
      DescriptorKind::Directory { path } => Ok(path),
      DescriptorKind::File { .. }
      | DescriptorKind::Null
      | DescriptorKind::HostStdin
      | DescriptorKind::HostOutput { .. }
      | DescriptorKind::AmbientFile { .. } => Err(errno(types::Errno::Notdir)),
      DescriptorKind::AmbientDirectory { .. } => Err(errno(types::Errno::Notsup)),
    }
  }

  fn resolve_ambient_path(
    &self,
    memory: &GuestMemory<'_>,
    fd: u32,
    path: GuestPtr<str>,
    required: types::Rights,
  ) -> WasiResult<Option<(Arc<HostDirectory>, PathBuf)>> {
    let descriptor = self.descriptor(fd)?;
    if !descriptor.rights.contains(required) {
      return Err(errno(types::Errno::Notcapable));
    }
    let DescriptorKind::AmbientDirectory { root, path: base } = &descriptor.kind else {
      return Ok(None);
    };
    let relative = self.read_path(memory, path)?;
    Ok(Some((Arc::clone(root), base.join(relative))))
  }

  fn resolve_path(
    &self,
    memory: &GuestMemory<'_>,
    fd: u32,
    path: GuestPtr<str>,
    required: types::Rights,
  ) -> WasiResult<String> {
    let path = self.read_path(memory, path)?;
    let base = self.directory_path(fd, required)?;
    let joined = if base == "." {
      path
    } else {
      format!("{base}/{path}")
    };
    normalize(&joined).ok_or_else(|| errno(types::Errno::Notcapable))
  }

  async fn read_file(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: u32,
    iovs: types::IovecArray,
    offset: u64,
    advance: bool,
  ) -> WasiResult<u32> {
    let descriptor = self.descriptor(fd)?.clone();
    if !descriptor.rights.contains(types::Rights::FD_READ) {
      return Err(errno(types::Errno::Notcapable));
    }
    if !advance
      && matches!(
        &descriptor.kind,
        DescriptorKind::File { file }
          if matches!(&*file.lock().unwrap(), SharedFile::Pipe(_))
      )
    {
      return Err(errno(types::Errno::Spipe));
    }
    let capacity = iov_capacity(memory, iovs)?.min(COPY_BUFFER_SIZE);
    if capacity == 0 {
      return match descriptor.kind {
        DescriptorKind::Directory { .. } | DescriptorKind::AmbientDirectory { .. } => {
          Err(errno(types::Errno::Isdir))
        }
        _ => Ok(0),
      };
    }
    if matches!(descriptor.kind, DescriptorKind::HostStdin) {
      let mut bytes = vec![0; capacity];
      let count = std::io::stdin()
        .read(&mut bytes)
        .map_err(|_| errno(types::Errno::Io))?;
      bytes.truncate(count);
      return write_iov(memory, iovs, &bytes);
    }
    if matches!(descriptor.kind, DescriptorKind::Null) {
      return Ok(0);
    }
    if let DescriptorKind::AmbientFile { file, .. } = &descriptor.kind {
      let mut bytes = vec![0; capacity];
      let mut file = file.lock().unwrap();
      file
        .seek(SeekFrom::Start(offset))
        .map_err(|_| errno(types::Errno::Io))?;
      let count = file.read(&mut bytes).map_err(|_| errno(types::Errno::Io))?;
      bytes.truncate(count);
      let count = write_iov(memory, iovs, &bytes)?;
      if advance {
        self.descriptor_mut(fd)?.position = offset.saturating_add(u64::from(count));
      }
      return Ok(count);
    }
    let DescriptorKind::File { file, .. } = descriptor.kind else {
      return Err(errno(types::Errno::Isdir));
    };
    let bytes = poll_fn(|context| {
      let mut guard = file.lock().unwrap();
      match &mut *guard {
        SharedFile::Regular(file) => Poll::Ready(
          file
            .read(offset, capacity)
            .map_err(|_| errno(types::Errno::Io)),
        ),
        SharedFile::Pipe(_) if !advance => Poll::Ready(Err(errno(types::Errno::Spipe))),
        SharedFile::Pipe(pipe) if !pipe.bytes.is_empty() => {
          let count = capacity.min(pipe.bytes.len());
          let bytes = pipe.bytes.drain(..count).collect();
          wake_all(&mut pipe.write_waiters);
          Poll::Ready(Ok(bytes))
        }
        SharedFile::Pipe(pipe) if pipe.writers == 0 => Poll::Ready(Ok(Vec::new())),
        SharedFile::Pipe(_) if descriptor.flags.contains(types::Fdflags::NONBLOCK) => {
          Poll::Ready(Err(errno(types::Errno::Again)))
        }
        SharedFile::Pipe(pipe) => {
          remember_waker(&mut pipe.read_waiters, context.waker());
          Poll::Pending
        }
      }
    })
    .await?;
    let count = write_iov(memory, iovs, &bytes)?;
    if advance {
      self.descriptor_mut(fd)?.position = offset
        .checked_add(u64::from(count))
        .ok_or_else(|| errno(types::Errno::Overflow))?;
    }
    Ok(count)
  }

  async fn write_file(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: u32,
    iovs: types::CiovecArray,
    offset: Option<u64>,
  ) -> WasiResult<u32> {
    let descriptor = self.descriptor(fd)?.clone();
    if !descriptor.rights.contains(types::Rights::FD_WRITE) {
      return Err(errno(types::Errno::Notcapable));
    }
    if offset.is_some()
      && matches!(
        &descriptor.kind,
        DescriptorKind::File { file }
          if matches!(&*file.lock().unwrap(), SharedFile::Pipe(_))
      )
    {
      return Err(errno(types::Errno::Spipe));
    }
    let bytes = read_ciov(memory, iovs)?;
    if bytes.is_empty() {
      return match descriptor.kind {
        DescriptorKind::Directory { .. } | DescriptorKind::AmbientDirectory { .. } => {
          Err(errno(types::Errno::Isdir))
        }
        _ => Ok(0),
      };
    }
    if let DescriptorKind::HostOutput {
      stderr,
      stream_length,
      size_limit,
      ..
    } = descriptor.kind
    {
      let requested = u64::try_from(bytes.len()).map_err(|_| errno(types::Errno::Overflow))?;
      let Some(total) = stream_length.checked_add(requested) else {
        if let DescriptorKind::HostOutput { exceeded, .. } = &mut self.descriptor_mut(fd)?.kind {
          *exceeded = true;
        }
        return Err(errno(types::Errno::Fbig));
      };
      if total > size_limit {
        if let DescriptorKind::HostOutput { exceeded, .. } = &mut self.descriptor_mut(fd)?.kind {
          *exceeded = true;
        }
        return Err(errno(types::Errno::Fbig));
      }
      if stderr {
        std::io::stderr().write_all(&bytes)
      } else {
        std::io::stdout().write_all(&bytes)
      }
      .map_err(|_| errno(types::Errno::Io))?;
      if let DescriptorKind::HostOutput { stream_length, .. } = &mut self.descriptor_mut(fd)?.kind {
        *stream_length = total;
      }
      return u32::try_from(bytes.len()).map_err(|_| errno(types::Errno::Overflow));
    }
    if matches!(descriptor.kind, DescriptorKind::Null) {
      return u32::try_from(bytes.len()).map_err(|_| errno(types::Errno::Overflow));
    }
    if let DescriptorKind::AmbientFile { file, .. } = &descriptor.kind {
      let position = if offset.is_none() && descriptor.flags.contains(types::Fdflags::APPEND) {
        file.lock().unwrap().metadata().map_err(io_errno)?.len()
      } else {
        offset.unwrap_or(descriptor.position)
      };
      let mut file = file.lock().unwrap();
      file
        .seek(SeekFrom::Start(position))
        .and_then(|_| file.write_all(&bytes))
        .map_err(|_| errno(types::Errno::Io))?;
      if offset.is_none() {
        self.descriptor_mut(fd)?.position = position.saturating_add(bytes.len() as u64);
      }
      return u32::try_from(bytes.len()).map_err(|_| errno(types::Errno::Overflow));
    }
    let DescriptorKind::File { file, .. } = descriptor.kind else {
      return Err(errno(types::Errno::Isdir));
    };
    let position = offset.unwrap_or(descriptor.position);
    let mut effective_position = position;
    let count = poll_fn(|context| {
      let mut guard = file.lock().unwrap();
      match &mut *guard {
        SharedFile::Regular(file) => {
          let position = if offset.is_none() && descriptor.flags.contains(types::Fdflags::APPEND) {
            file.length
          } else {
            position
          };
          effective_position = position;
          Poll::Ready(
            file
              .write(position, &bytes)
              .and_then(|count| u32::try_from(count).map_err(|_| errno(types::Errno::Overflow))),
          )
        }
        SharedFile::Pipe(_) if offset.is_some() => Poll::Ready(Err(errno(types::Errno::Spipe))),
        SharedFile::Pipe(pipe) if pipe.readers == 0 => Poll::Ready(Err(errno(types::Errno::Pipe))),
        SharedFile::Pipe(pipe) => {
          let remaining = pipe.size_limit.saturating_sub(pipe.stream_length);
          if remaining == 0 {
            pipe.exceeded = true;
            return Poll::Ready(Err(errno(types::Errno::Fbig)));
          }
          let available = pipe.capacity.saturating_sub(pipe.bytes.len());
          if available == 0 {
            if descriptor.flags.contains(types::Fdflags::NONBLOCK) {
              return Poll::Ready(Err(errno(types::Errno::Again)));
            }
            remember_waker(&mut pipe.write_waiters, context.waker());
            return Poll::Pending;
          }
          let count = available.min(bytes.len()).min(remaining as usize);
          pipe.bytes.extend(&bytes[..count]);
          pipe.stream_length += count as u64;
          if count < bytes.len() && pipe.stream_length == pipe.size_limit {
            pipe.exceeded = true;
          }
          wake_all(&mut pipe.read_waiters);
          Poll::Ready(Ok(count as u32))
        }
      }
    })
    .await?;
    if offset.is_none() {
      self.descriptor_mut(fd)?.position = effective_position
        .checked_add(u64::from(count))
        .ok_or_else(|| errno(types::Errno::Overflow))?;
    }
    Ok(count)
  }
}

impl Drop for State {
  fn drop(&mut self) {
    self.close_descriptors();
  }
}

fn permissions_allow_read(permissions: FilePermissions) -> bool {
  matches!(
    permissions,
    FilePermissions::Read | FilePermissions::ReadWrite
  )
}

fn permissions_allow_write(permissions: FilePermissions) -> bool {
  matches!(
    permissions,
    FilePermissions::Write | FilePermissions::ReadWrite
  )
}

fn permissions_rights(permissions: FilePermissions, directory: bool) -> types::Rights {
  let mut rights = types::Rights::FD_FILESTAT_GET | types::Rights::POLL_FD_READWRITE;
  if permissions_allow_read(permissions) {
    rights |= types::Rights::FD_READ;
    if directory {
      rights |=
        types::Rights::FD_READDIR | types::Rights::PATH_FILESTAT_GET | types::Rights::PATH_OPEN;
    }
  }
  if permissions_allow_write(permissions) {
    rights |= types::Rights::FD_WRITE
      | types::Rights::FD_DATASYNC
      | types::Rights::FD_SYNC
      | types::Rights::FD_FILESTAT_SET_SIZE
      | types::Rights::FD_ALLOCATE
      | types::Rights::FD_FDSTAT_SET_FLAGS;
  }
  if !directory {
    rights |= types::Rights::FD_SEEK | types::Rights::FD_TELL | types::Rights::FD_ADVISE;
  }
  rights
}

fn file_rights(permissions: FilePermissions) -> types::Rights {
  // wasi-libc requests sync and mutable descriptor flags for every regular-file open mode.
  // These operations do not grant content access, so the node's read/write capability remains
  // authoritative while read-only opens retain their POSIX descriptor behavior.
  permissions_rights(permissions, false)
    | types::Rights::FD_DATASYNC
    | types::Rights::FD_SYNC
    | types::Rights::FD_FDSTAT_SET_FLAGS
}

fn stream_rights(permissions: FilePermissions) -> types::Rights {
  let mut rights = types::Rights::FD_FILESTAT_GET | types::Rights::POLL_FD_READWRITE;
  if permissions_allow_read(permissions) {
    rights |= types::Rights::FD_READ;
  }
  if permissions_allow_write(permissions) {
    rights |= types::Rights::FD_WRITE | types::Rights::FD_FDSTAT_SET_FLAGS;
  }
  rights
}

fn node_rights(node: &Node) -> types::Rights {
  let directory = matches!(node.kind, NodeKind::Directory);
  let mut rights = if directory {
    permissions_rights(node.permissions, true)
  } else {
    file_rights(node.permissions)
  };
  if node.path_access {
    rights |= types::Rights::PATH_OPEN | types::Rights::PATH_FILESTAT_GET;
  }
  rights
}

fn host_descriptor(kind: DescriptorKind, rights: types::Rights) -> Descriptor {
  Descriptor {
    kind,
    pipe_roles: None,
    position: 0,
    rights: rights | types::Rights::FD_FILESTAT_GET | types::Rights::POLL_FD_READWRITE,
    inheriting: types::Rights::empty(),
    flags: types::Fdflags::empty(),
    preopen: None,
  }
}

fn ambient_file_rights() -> types::Rights {
  types::Rights::FD_READ
    | types::Rights::FD_WRITE
    | types::Rights::FD_SEEK
    | types::Rights::FD_TELL
    | types::Rights::FD_ADVISE
    | types::Rights::FD_FILESTAT_GET
    | types::Rights::FD_FILESTAT_SET_SIZE
    | types::Rights::FD_DATASYNC
    | types::Rights::FD_SYNC
    | types::Rights::POLL_FD_READWRITE
}

fn ambient_directory_rights() -> types::Rights {
  types::Rights::PATH_OPEN
    | types::Rights::PATH_FILESTAT_GET
    | types::Rights::FD_FILESTAT_GET
    | types::Rights::FD_READDIR
}

fn file_size(file: &Arc<Mutex<SharedFile>>) -> WasiResult<u64> {
  let mut file = file.lock().unwrap();
  match &mut *file {
    SharedFile::Regular(file) => Ok(file.length),
    SharedFile::Pipe(pipe) => Ok(pipe.bytes.len() as u64),
  }
}

fn iov_capacity(memory: &GuestMemory<'_>, iovs: types::IovecArray) -> WasiResult<usize> {
  let mut total = 0_usize;
  for pointer in iovs.iter() {
    let iov = memory.read(pointer?)?;
    total = total
      .saturating_add(iov.buf_len as usize)
      .min(COPY_BUFFER_SIZE);
    if total == COPY_BUFFER_SIZE {
      break;
    }
  }
  Ok(total)
}

fn wake_all(waiters: &mut Vec<Waker>) {
  for waiter in waiters.drain(..) {
    waiter.wake();
  }
}

fn remember_waker(waiters: &mut Vec<Waker>, waker: &Waker) {
  if !waiters.iter().any(|candidate| candidate.will_wake(waker)) {
    waiters.push(waker.clone());
  }
}

fn validate_time_flags(flags: types::Fstflags) -> WasiResult<()> {
  if flags.contains(types::Fstflags::ATIM) && flags.contains(types::Fstflags::ATIM_NOW)
    || flags.contains(types::Fstflags::MTIM) && flags.contains(types::Fstflags::MTIM_NOW)
  {
    Err(errno(types::Errno::Inval))
  } else {
    Ok(())
  }
}

fn close_descriptor(descriptor: Descriptor) {
  let DescriptorKind::File { file, .. } = descriptor.kind else {
    return;
  };
  let mut file = file.lock().unwrap();
  if let SharedFile::Pipe(pipe) = &mut *file {
    if descriptor
      .pipe_roles
      .is_some_and(|endpoint| endpoint.reader)
    {
      debug_assert!(pipe.readers > 0);
      pipe.readers -= 1;
      wake_all(&mut pipe.write_waiters);
    }
    if descriptor
      .pipe_roles
      .is_some_and(|endpoint| endpoint.writer)
    {
      debug_assert!(pipe.writers > 0);
      pipe.writers -= 1;
      wake_all(&mut pipe.read_waiters);
    }
  }
}

fn poll_subscription(
  descriptors: &BTreeMap<u32, Descriptor>,
  subscription: &types::Subscription,
  waker: &Waker,
) -> Option<types::Event> {
  let (type_, error, nbytes, flags, pending) = match &subscription.u {
    types::SubscriptionU::Clock(clock) => {
      let valid = matches!(
        clock.id,
        types::Clockid::Realtime | types::Clockid::Monotonic
      );
      (
        types::Eventtype::Clock,
        if valid {
          types::Errno::Success
        } else {
          types::Errno::Inval
        },
        0,
        types::Eventrwflags::empty(),
        // Deterministic judging has no advancing clock. Zero-time waits are ready immediately;
        // every nonzero timeout remains pending and can only be bypassed by another ready event.
        valid && clock.timeout != 0,
      )
    }
    types::SubscriptionU::FdRead(read) => match descriptors.get(&u32::from(read.file_descriptor)) {
      None => (
        types::Eventtype::FdRead,
        types::Errno::Badf,
        0,
        types::Eventrwflags::empty(),
        false,
      ),
      Some(descriptor)
        if !descriptor
          .rights
          .contains(types::Rights::FD_READ | types::Rights::POLL_FD_READWRITE) =>
      {
        (
          types::Eventtype::FdRead,
          types::Errno::Notcapable,
          0,
          types::Eventrwflags::empty(),
          false,
        )
      }
      Some(Descriptor {
        kind: DescriptorKind::Directory { .. } | DescriptorKind::AmbientDirectory { .. },
        ..
      }) => (
        types::Eventtype::FdRead,
        types::Errno::Badf,
        0,
        types::Eventrwflags::empty(),
        false,
      ),
      Some(Descriptor {
        kind: DescriptorKind::File { file, .. },
        position,
        ..
      }) => {
        let mut file = file.lock().unwrap();
        match &mut *file {
          SharedFile::Regular(file) => (
            types::Eventtype::FdRead,
            types::Errno::Success,
            file.length.saturating_sub(*position),
            types::Eventrwflags::empty(),
            false,
          ),
          SharedFile::Pipe(pipe) if !pipe.bytes.is_empty() || pipe.writers == 0 => (
            types::Eventtype::FdRead,
            types::Errno::Success,
            pipe.bytes.len() as u64,
            if pipe.writers == 0 {
              types::Eventrwflags::FD_READWRITE_HANGUP
            } else {
              types::Eventrwflags::empty()
            },
            false,
          ),
          SharedFile::Pipe(pipe) => {
            remember_waker(&mut pipe.read_waiters, waker);
            (
              types::Eventtype::FdRead,
              types::Errno::Success,
              0,
              types::Eventrwflags::empty(),
              true,
            )
          }
        }
      }
      Some(Descriptor {
        kind: DescriptorKind::HostStdin,
        ..
      }) => (
        types::Eventtype::FdRead,
        types::Errno::Success,
        1,
        types::Eventrwflags::empty(),
        false,
      ),
      Some(Descriptor {
        kind: DescriptorKind::Null,
        ..
      }) => (
        types::Eventtype::FdRead,
        types::Errno::Success,
        0,
        types::Eventrwflags::empty(),
        false,
      ),
      Some(Descriptor {
        kind: DescriptorKind::AmbientFile { .. },
        ..
      }) => (
        types::Eventtype::FdRead,
        types::Errno::Success,
        1,
        types::Eventrwflags::empty(),
        false,
      ),
      Some(Descriptor {
        kind: DescriptorKind::HostOutput { .. },
        ..
      }) => (
        types::Eventtype::FdRead,
        types::Errno::Badf,
        0,
        types::Eventrwflags::empty(),
        false,
      ),
    },
    types::SubscriptionU::FdWrite(write) => {
      match descriptors.get(&u32::from(write.file_descriptor)) {
        None => (
          types::Eventtype::FdWrite,
          types::Errno::Badf,
          0,
          types::Eventrwflags::empty(),
          false,
        ),
        Some(descriptor)
          if !descriptor
            .rights
            .contains(types::Rights::FD_WRITE | types::Rights::POLL_FD_READWRITE) =>
        {
          (
            types::Eventtype::FdWrite,
            types::Errno::Notcapable,
            0,
            types::Eventrwflags::empty(),
            false,
          )
        }
        Some(Descriptor {
          kind: DescriptorKind::Directory { .. } | DescriptorKind::AmbientDirectory { .. },
          ..
        }) => (
          types::Eventtype::FdWrite,
          types::Errno::Badf,
          0,
          types::Eventrwflags::empty(),
          false,
        ),
        Some(Descriptor {
          kind: DescriptorKind::File { file, .. },
          ..
        }) => {
          let mut file = file.lock().unwrap();
          match &mut *file {
            SharedFile::Regular(_) => (
              types::Eventtype::FdWrite,
              types::Errno::Success,
              u64::MAX,
              types::Eventrwflags::empty(),
              false,
            ),
            SharedFile::Pipe(pipe) if pipe.readers == 0 => (
              types::Eventtype::FdWrite,
              types::Errno::Pipe,
              0,
              types::Eventrwflags::FD_READWRITE_HANGUP,
              false,
            ),
            SharedFile::Pipe(pipe)
              if pipe.bytes.len() < pipe.capacity && pipe.stream_length < pipe.size_limit =>
            {
              (
                types::Eventtype::FdWrite,
                types::Errno::Success,
                ((pipe.capacity - pipe.bytes.len()) as u64)
                  .min(pipe.size_limit - pipe.stream_length),
                types::Eventrwflags::empty(),
                false,
              )
            }
            SharedFile::Pipe(pipe) if pipe.stream_length == pipe.size_limit => (
              types::Eventtype::FdWrite,
              types::Errno::Fbig,
              0,
              types::Eventrwflags::empty(),
              false,
            ),
            SharedFile::Pipe(pipe) => {
              remember_waker(&mut pipe.write_waiters, waker);
              (
                types::Eventtype::FdWrite,
                types::Errno::Success,
                0,
                types::Eventrwflags::empty(),
                true,
              )
            }
          }
        }
        Some(Descriptor {
          kind:
            DescriptorKind::HostOutput {
              stream_length,
              size_limit,
              ..
            },
          ..
        }) => (
          types::Eventtype::FdWrite,
          types::Errno::Success,
          size_limit.saturating_sub(*stream_length),
          types::Eventrwflags::empty(),
          false,
        ),
        Some(Descriptor {
          kind: DescriptorKind::AmbientFile { .. },
          ..
        }) => (
          types::Eventtype::FdWrite,
          types::Errno::Success,
          u64::MAX,
          types::Eventrwflags::empty(),
          false,
        ),
        Some(Descriptor {
          kind: DescriptorKind::HostStdin,
          ..
        }) => (
          types::Eventtype::FdWrite,
          types::Errno::Badf,
          0,
          types::Eventrwflags::empty(),
          false,
        ),
        Some(Descriptor {
          kind: DescriptorKind::Null,
          ..
        }) => (
          types::Eventtype::FdWrite,
          types::Errno::Success,
          u64::MAX,
          types::Eventrwflags::empty(),
          false,
        ),
      }
    }
  };
  (!pending).then_some(types::Event {
    userdata: subscription.userdata,
    error,
    type_,
    fd_readwrite: types::EventFdReadwrite { nbytes, flags },
  })
}

fn normalize(path: &str) -> Option<String> {
  let mut parts = Vec::new();
  for component in Path::new(path).components() {
    match component {
      Component::CurDir => {}
      Component::Normal(part) => parts.push(part.to_str()?.to_owned()),
      _ => return None,
    }
  }
  Some(if parts.is_empty() {
    ".".into()
  } else {
    parts.join("/")
  })
}

fn stable_inode(path: &str) -> u64 {
  path.bytes().fold(14_695_981_039_346_656_037, |hash, byte| {
    (hash ^ u64::from(byte)).wrapping_mul(1_099_511_628_211)
  })
}

#[derive(Debug)]
struct ProcessExit(i32);

impl fmt::Display for ProcessExit {
  fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
    write!(formatter, "process exited with {}", self.0)
  }
}

impl std::error::Error for ProcessExit {}

/// Registers the one canonical typed Preview1 ABI.
pub fn add_to_linker(linker: &mut Linker<State>) -> Result<()> {
  wasi_snapshot_preview1::add_to_linker(linker, |state| state)?;
  Ok(())
}

fn write_bytes(
  memory: &mut GuestMemory<'_>,
  pointer: GuestPtr<u8>,
  bytes: &[u8],
) -> WasiResult<()> {
  memory.copy_from_slice(
    bytes,
    pointer.as_array(u32::try_from(bytes.len()).map_err(|_| errno(types::Errno::Overflow))?),
  )?;
  Ok(())
}

fn read_ciov(memory: &GuestMemory<'_>, iovs: types::CiovecArray) -> WasiResult<Vec<u8>> {
  // WASI permits short writes, so one hostcall copies only a bounded prefix. A guest controls the
  // aggregate iovec length, and allocating that length on the host would bypass its memory limit.
  let mut bytes = Vec::with_capacity(COPY_BUFFER_SIZE);
  for pointer in iovs.iter() {
    let iov = memory.read(pointer?)?;
    let length = (iov.buf_len as usize).min(COPY_BUFFER_SIZE - bytes.len());
    let chunk = memory.to_vec(iov.buf.as_array(length as u32))?;
    bytes.extend_from_slice(&chunk);
    if bytes.len() == COPY_BUFFER_SIZE {
      break;
    }
  }
  Ok(bytes)
}

fn write_iov(
  memory: &mut GuestMemory<'_>,
  iovs: types::IovecArray,
  bytes: &[u8],
) -> WasiResult<u32> {
  let mut position = 0;
  for pointer in iovs.iter() {
    let iov = memory.read(pointer?)?;
    let amount = usize::try_from(iov.buf_len)
      .unwrap()
      .min(bytes.len() - position);
    memory.copy_from_slice(
      &bytes[position..position + amount],
      iov.buf.as_array(u32::try_from(amount).unwrap()),
    )?;
    position += amount;
    if position == bytes.len() {
      break;
    }
  }
  u32::try_from(position).map_err(|_| errno(types::Errno::Overflow))
}

fn filestat(node: &Node, size: u64) -> types::Filestat {
  types::Filestat {
    dev: 0,
    ino: node.inode,
    filetype: match node.kind {
      NodeKind::Directory => types::Filetype::Directory,
      NodeKind::Regular { .. } => types::Filetype::RegularFile,
    },
    nlink: 1,
    size,
    atim: 0,
    mtim: 0,
    ctim: 0,
  }
}

fn io_errno(error: std::io::Error) -> types::Error {
  match error.kind() {
    std::io::ErrorKind::NotFound => errno(types::Errno::Noent),
    std::io::ErrorKind::PermissionDenied => errno(types::Errno::Acces),
    std::io::ErrorKind::AlreadyExists => errno(types::Errno::Exist),
    _ => errno(types::Errno::Io),
  }
}

fn host_filestat(metadata: cap_std::fs::Metadata, path: &Path) -> types::Filestat {
  types::Filestat {
    dev: 0,
    ino: stable_inode(path.to_string_lossy().as_ref()),
    filetype: if metadata.is_dir() {
      types::Filetype::Directory
    } else {
      types::Filetype::RegularFile
    },
    nlink: 1,
    size: metadata.len(),
    atim: 0,
    mtim: 0,
    ctim: 0,
  }
}

fn encode_directory_entries(
  entries: Vec<(String, u64, types::Filetype)>,
  cookie: u64,
  buffer_len: u32,
) -> WasiResult<Vec<u8>> {
  let skip = usize::try_from(cookie).map_err(|_| errno(types::Errno::Overflow))?;
  let mut encoded = Vec::new();
  for (index, (name, inode, filetype)) in entries.into_iter().enumerate().skip(skip) {
    encoded.extend_from_slice(&(index as u64 + 1).to_le_bytes());
    encoded.extend_from_slice(&inode.to_le_bytes());
    encoded.extend_from_slice(
      &u32::try_from(name.len())
        .map_err(|_| errno(types::Errno::Overflow))?
        .to_le_bytes(),
    );
    encoded.push(filetype.into());
    encoded.extend_from_slice(&[0; 3]);
    encoded.extend_from_slice(name.as_bytes());
  }
  encoded.truncate(buffer_len as usize);
  Ok(encoded)
}

/// Classifies execution with MLE then FE precedence before TLE and RE.
pub fn classify(
  result: &wasmtime::Result<()>,
  state: &State,
  file_error: bool,
  tick: u64,
  memory: u64,
  program: &str,
) -> ProgramResult {
  let (status, exit_code, error_message) = match result {
    _ if state.memory.exceeded => (
      RunStatus::MemoryLimitExceeded,
      None,
      Some("Memory limit exceeded".into()),
    ),
    _ if file_error => (
      RunStatus::FileError,
      None,
      Some("File size limit exceeded".into()),
    ),
    Ok(()) => (RunStatus::Accepted, Some(0), None),
    Err(error) if error.downcast_ref::<wasmtime::Trap>() == Some(&wasmtime::Trap::OutOfFuel) => (
      RunStatus::TimeLimitExceeded,
      None,
      Some("Tick limit exceeded".into()),
    ),
    Err(error)
      if error
        .downcast_ref::<ProcessExit>()
        .is_some_and(|exit| exit.0 == 0) =>
    {
      (RunStatus::Accepted, Some(0), None)
    }
    Err(error) if let Some(exit) = error.downcast_ref::<ProcessExit>() => (
      RunStatus::RuntimeError,
      Some(exit.0),
      Some(format!("Nonzero exit code: {}", exit.0)),
    ),
    Err(error) => (RunStatus::RuntimeError, None, Some(error.to_string())),
  };
  ProgramResult {
    program: program.into(),
    status,
    tick,
    memory,
    exit_code,
    error_message,
  }
}

impl wasi_snapshot_preview1::WasiSnapshotPreview1 for State {
  fn set_hostcall_fuel(&mut self, fuel: usize) {
    self.hostcall_fuel = fuel;
  }

  async fn args_get(
    &mut self,
    memory: &mut GuestMemory<'_>,
    mut argv: GuestPtr<GuestPtr<u8>>,
    mut buffer: GuestPtr<u8>,
  ) -> WasiResult<()> {
    for argument in &self.arguments {
      memory.write(argv, buffer)?;
      argv = argv.add(1)?;
      write_bytes(memory, buffer, argument)?;
      buffer =
        buffer.add(u32::try_from(argument.len()).map_err(|_| errno(types::Errno::Overflow))?)?;
    }
    Ok(())
  }

  async fn args_sizes_get(&mut self, _memory: &mut GuestMemory<'_>) -> WasiResult<(u32, u32)> {
    let count = self
      .arguments
      .len()
      .try_into()
      .map_err(|_| errno(types::Errno::Overflow))?;
    let bytes = self
      .arguments
      .iter()
      .try_fold(0_u32, |sum, argument| {
        sum.checked_add(argument.len().try_into().ok()?)
      })
      .ok_or_else(|| errno(types::Errno::Overflow))?;
    Ok((count, bytes))
  }

  async fn environ_get(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    _environ: GuestPtr<GuestPtr<u8>>,
    _buffer: GuestPtr<u8>,
  ) -> WasiResult<()> {
    Ok(())
  }
  async fn environ_sizes_get(&mut self, _memory: &mut GuestMemory<'_>) -> WasiResult<(u32, u32)> {
    Ok((0, 0))
  }

  async fn clock_res_get(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    id: types::Clockid,
  ) -> WasiResult<u64> {
    match id {
      types::Clockid::Realtime | types::Clockid::Monotonic => Ok(1),
      _ => Err(errno(types::Errno::Badf)),
    }
  }

  async fn clock_time_get(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    id: types::Clockid,
    _precision: u64,
  ) -> WasiResult<u64> {
    match id {
      types::Clockid::Realtime | types::Clockid::Monotonic => Ok(0),
      _ => Err(errno(types::Errno::Badf)),
    }
  }

  async fn fd_advise(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    _offset: u64,
    _len: u64,
    _advice: types::Advice,
  ) -> WasiResult<()> {
    let descriptor = self.descriptor(fd.into())?;
    if !descriptor.rights.contains(types::Rights::FD_ADVISE) {
      return Err(errno(types::Errno::Notcapable));
    }
    if matches!(descriptor.kind, DescriptorKind::Directory { .. }) {
      return Err(errno(types::Errno::Isdir));
    }
    Ok(())
  }

  async fn fd_allocate(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    offset: u64,
    len: u64,
  ) -> WasiResult<()> {
    let descriptor = self.descriptor(fd.into())?.clone();
    if !descriptor.rights.contains(types::Rights::FD_ALLOCATE) {
      return Err(errno(types::Errno::Notcapable));
    }
    let file = match &descriptor.kind {
      DescriptorKind::File { file } => file,
      _ => return Err(errno(types::Errno::Badf)),
    };
    let Some(end) = offset.checked_add(len) else {
      if let SharedFile::Regular(file) = &mut *file.lock().unwrap() {
        file.exceeded = true;
      }
      return Err(errno(types::Errno::Fbig));
    };
    let size = file_size(file)?.max(end);
    let mut file = file.lock().unwrap();
    let SharedFile::Regular(file) = &mut *file else {
      return Err(errno(types::Errno::Badf));
    };
    file.resize(size)
  }

  async fn fd_close(&mut self, _memory: &mut GuestMemory<'_>, fd: types::Fd) -> WasiResult<()> {
    let descriptor = self
      .descriptors
      .remove(&fd.into())
      .ok_or_else(|| errno(types::Errno::Badf))?;
    close_descriptor(descriptor);
    Ok(())
  }

  async fn fd_datasync(&mut self, _memory: &mut GuestMemory<'_>, fd: types::Fd) -> WasiResult<()> {
    if !self
      .descriptor(fd.into())?
      .rights
      .contains(types::Rights::FD_DATASYNC)
    {
      return Err(errno(types::Errno::Notcapable));
    }
    Ok(())
  }

  async fn fd_fdstat_get(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
  ) -> WasiResult<types::Fdstat> {
    let descriptor = self.descriptor(fd.into())?;
    let fs_filetype = match &descriptor.kind {
      DescriptorKind::Directory { .. } | DescriptorKind::AmbientDirectory { .. } => {
        types::Filetype::Directory
      }
      DescriptorKind::File { file, .. } => match &*file.lock().unwrap() {
        SharedFile::Pipe(_) => types::Filetype::Unknown,
        _ => types::Filetype::RegularFile,
      },
      DescriptorKind::Null | DescriptorKind::HostStdin | DescriptorKind::HostOutput { .. } => {
        types::Filetype::CharacterDevice
      }
      DescriptorKind::AmbientFile { .. } => types::Filetype::RegularFile,
    };
    Ok(types::Fdstat {
      fs_filetype,
      fs_flags: descriptor.flags,
      fs_rights_base: descriptor.rights,
      fs_rights_inheriting: descriptor.inheriting,
    })
  }

  async fn fd_fdstat_set_flags(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    flags: types::Fdflags,
  ) -> WasiResult<()> {
    if flags.intersects(types::Fdflags::DSYNC | types::Fdflags::RSYNC | types::Fdflags::SYNC) {
      return Err(errno(types::Errno::Inval));
    }
    let descriptor = self.descriptor_mut(fd.into())?;
    if !descriptor
      .rights
      .contains(types::Rights::FD_FDSTAT_SET_FLAGS)
    {
      return Err(errno(types::Errno::Notcapable));
    }
    descriptor.flags = flags;
    Ok(())
  }

  async fn fd_fdstat_set_rights(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    base: types::Rights,
    inheriting: types::Rights,
  ) -> WasiResult<()> {
    let raw = u32::from(fd);
    let descriptor = self.descriptor(raw)?.clone();
    if !descriptor.rights.contains(base) || !descriptor.inheriting.contains(inheriting) {
      return Err(errno(types::Errno::Notcapable));
    }
    let release_reader = descriptor
      .pipe_roles
      .is_some_and(|endpoint| endpoint.reader)
      && !base.contains(types::Rights::FD_READ);
    let release_writer = descriptor
      .pipe_roles
      .is_some_and(|endpoint| endpoint.writer)
      && !base.contains(types::Rights::FD_WRITE);
    if let DescriptorKind::File { file } = &descriptor.kind
      && (release_reader || release_writer)
      && let SharedFile::Pipe(pipe) = &mut *file.lock().unwrap()
    {
      if release_reader {
        debug_assert!(pipe.readers > 0);
        pipe.readers -= 1;
        wake_all(&mut pipe.write_waiters);
      }
      if release_writer {
        debug_assert!(pipe.writers > 0);
        pipe.writers -= 1;
        wake_all(&mut pipe.read_waiters);
      }
    }
    let descriptor = self.descriptor_mut(raw)?;
    if let Some(roles) = &mut descriptor.pipe_roles {
      roles.reader &= !release_reader;
      roles.writer &= !release_writer;
    }
    descriptor.rights = base;
    descriptor.inheriting = inheriting;
    Ok(())
  }

  async fn fd_filestat_get(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
  ) -> WasiResult<types::Filestat> {
    let descriptor = self.descriptor(fd.into())?;
    if !descriptor.rights.contains(types::Rights::FD_FILESTAT_GET) {
      return Err(errno(types::Errno::Notcapable));
    }
    match &descriptor.kind {
      DescriptorKind::Directory { path } => Ok(filestat(
        self
          .nodes
          .get(path)
          .ok_or_else(|| errno(types::Errno::Noent))?,
        0,
      )),
      DescriptorKind::File { file, .. } => {
        let (filetype, size) = match &*file.lock().unwrap() {
          SharedFile::Regular(file) => (types::Filetype::RegularFile, file.length),
          SharedFile::Pipe(pipe) => (types::Filetype::Unknown, pipe.bytes.len() as u64),
        };
        Ok(types::Filestat {
          dev: 0,
          ino: 0,
          filetype,
          nlink: 1,
          size,
          atim: 0,
          mtim: 0,
          ctim: 0,
        })
      }
      DescriptorKind::Null | DescriptorKind::HostStdin | DescriptorKind::HostOutput { .. } => {
        Ok(types::Filestat {
          dev: 0,
          ino: 0,
          filetype: types::Filetype::CharacterDevice,
          nlink: 1,
          size: 0,
          atim: 0,
          mtim: 0,
          ctim: 0,
        })
      }
      DescriptorKind::AmbientDirectory { root, path } => {
        let metadata = if path.as_os_str().is_empty() {
          root.0.dir_metadata()
        } else {
          root.0.metadata(path)
        }
        .map_err(io_errno)?;
        Ok(host_filestat(metadata, path))
      }
      DescriptorKind::AmbientFile { file, path } => {
        let metadata = file.lock().unwrap().metadata().map_err(io_errno)?;
        Ok(host_filestat(metadata, path))
      }
    }
  }

  async fn fd_filestat_set_size(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    size: u64,
  ) -> WasiResult<()> {
    let descriptor = self.descriptor(fd.into())?.clone();
    if !descriptor
      .rights
      .contains(types::Rights::FD_FILESTAT_SET_SIZE)
    {
      return Err(errno(types::Errno::Notcapable));
    }
    let DescriptorKind::File { file, .. } = descriptor.kind else {
      return Err(errno(types::Errno::Isdir));
    };
    let mut guard = file.lock().unwrap();
    let SharedFile::Regular(file) = &mut *guard else {
      return Err(errno(types::Errno::Perm));
    };
    file.resize(size)
  }

  async fn fd_filestat_set_times(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    _atim: u64,
    _mtim: u64,
    _flags: types::Fstflags,
  ) -> WasiResult<()> {
    let descriptor = self.descriptor(fd.into())?;
    if !descriptor
      .rights
      .contains(types::Rights::FD_FILESTAT_SET_TIMES)
    {
      return Err(errno(types::Errno::Notcapable));
    }
    Err(errno(types::Errno::Rofs))
  }

  async fn fd_pread(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    iovs: types::IovecArray,
    offset: u64,
  ) -> WasiResult<u32> {
    self.read_file(memory, fd.into(), iovs, offset, false).await
  }

  async fn fd_prestat_get(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
  ) -> WasiResult<types::Prestat> {
    let name = self
      .descriptor(fd.into())?
      .preopen
      .as_ref()
      .ok_or_else(|| errno(types::Errno::Badf))?;
    Ok(types::Prestat::Dir(types::PrestatDir {
      pr_name_len: name
        .len()
        .try_into()
        .map_err(|_| errno(types::Errno::Overflow))?,
    }))
  }

  async fn fd_prestat_dir_name(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    path: GuestPtr<u8>,
    path_len: u32,
  ) -> WasiResult<()> {
    let name = self
      .descriptor(fd.into())?
      .preopen
      .as_ref()
      .ok_or_else(|| errno(types::Errno::Badf))?;
    if path_len < name.len() as u32 {
      return Err(errno(types::Errno::Nametoolong));
    }
    write_bytes(memory, path, name.as_bytes())
  }

  async fn fd_pwrite(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    iovs: types::CiovecArray,
    offset: u64,
  ) -> WasiResult<u32> {
    self.write_file(memory, fd.into(), iovs, Some(offset)).await
  }

  async fn fd_read(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    iovs: types::IovecArray,
  ) -> WasiResult<u32> {
    let raw = fd.into();
    let offset = self.descriptor(raw)?.position;
    self.read_file(memory, raw, iovs, offset, true).await
  }

  async fn fd_readdir(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    buffer: GuestPtr<u8>,
    buffer_len: u32,
    cookie: u64,
  ) -> WasiResult<u32> {
    if let DescriptorKind::AmbientDirectory { root, path } = &self.descriptor(fd.into())?.kind {
      let mut entries = vec![
        (
          ".".to_owned(),
          stable_inode(path.to_string_lossy().as_ref()),
          types::Filetype::Directory,
        ),
        (
          "..".to_owned(),
          stable_inode(path.to_string_lossy().as_ref()),
          types::Filetype::Directory,
        ),
      ];
      let directory = if path.as_os_str().is_empty() {
        root.0.entries()
      } else {
        root.0.read_dir(path)
      }
      .map_err(io_errno)?;
      let mut children = directory
        .map(|entry| {
          let entry = entry.map_err(|_| errno(types::Errno::Io))?;
          let name = entry
            .file_name()
            .into_string()
            .map_err(|_| errno(types::Errno::Ilseq))?;
          let metadata = entry.metadata().map_err(|_| errno(types::Errno::Io))?;
          let inode = stable_inode(path.join(&name).to_string_lossy().as_ref());
          Ok((
            name,
            inode,
            if metadata.is_dir() {
              types::Filetype::Directory
            } else {
              types::Filetype::RegularFile
            },
          ))
        })
        .collect::<WasiResult<Vec<_>>>()?;
      children.sort_by(|left, right| left.0.cmp(&right.0));
      entries.extend(children);
      let encoded = encode_directory_entries(entries, cookie, buffer_len)?;
      write_bytes(memory, buffer, &encoded)?;
      return Ok(encoded.len() as u32);
    }
    let DescriptorKind::Directory { path } = &self.descriptor(fd.into())?.kind else {
      return Err(errno(types::Errno::Notdir));
    };
    let prefix = if path == "." {
      String::new()
    } else {
      format!("{path}/")
    };
    let mut entries = BTreeMap::from([
      (
        ".".to_owned(),
        (stable_inode(path), types::Filetype::Directory),
      ),
      (
        "..".to_owned(),
        (stable_inode(path), types::Filetype::Directory),
      ),
    ]);
    for (candidate, node) in &self.nodes {
      let Some(rest) = candidate.strip_prefix(&prefix) else {
        continue;
      };
      if rest.is_empty() || rest.contains('/') {
        continue;
      }
      entries.insert(
        rest.to_owned(),
        (
          node.inode,
          match node.kind {
            NodeKind::Directory => types::Filetype::Directory,
            NodeKind::Regular { .. } => types::Filetype::RegularFile,
          },
        ),
      );
    }
    let mut encoded = Vec::new();
    for (index, (name, (inode, filetype))) in entries.into_iter().enumerate().skip(cookie as usize)
    {
      encoded.extend_from_slice(&(index as u64 + 1).to_le_bytes());
      encoded.extend_from_slice(&inode.to_le_bytes());
      encoded.extend_from_slice(&(name.len() as u32).to_le_bytes());
      encoded.push(filetype.into());
      encoded.extend_from_slice(&[0; 3]);
      encoded.extend_from_slice(name.as_bytes());
    }
    encoded.truncate(buffer_len as usize);
    write_bytes(memory, buffer, &encoded)?;
    Ok(encoded.len() as u32)
  }

  async fn fd_renumber(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    to: types::Fd,
  ) -> WasiResult<()> {
    let from = u32::from(fd);
    let to = u32::from(to);
    if from == to {
      return self.descriptor(from).map(|_| ());
    }
    let descriptor = self
      .descriptors
      .remove(&from)
      .ok_or_else(|| errno(types::Errno::Badf))?;
    if let Some(replaced) = self.descriptors.insert(to, descriptor) {
      close_descriptor(replaced);
    }
    Ok(())
  }

  async fn fd_seek(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    offset: i64,
    whence: types::Whence,
  ) -> WasiResult<u64> {
    let raw = fd.into();
    let descriptor = self.descriptor(raw)?.clone();
    if !descriptor.rights.contains(types::Rights::FD_SEEK) {
      return Err(errno(types::Errno::Notcapable));
    }
    let size = match &descriptor.kind {
      DescriptorKind::Directory { .. }
      | DescriptorKind::AmbientDirectory { .. }
      | DescriptorKind::Null
      | DescriptorKind::HostStdin
      | DescriptorKind::HostOutput { .. } => return Err(errno(types::Errno::Spipe)),
      DescriptorKind::File { file, .. } => match &*file.lock().unwrap() {
        SharedFile::Regular(file) => file.length,
        SharedFile::Pipe(_) => return Err(errno(types::Errno::Spipe)),
      },
      DescriptorKind::AmbientFile { file, .. } => {
        file.lock().unwrap().metadata().map_err(io_errno)?.len()
      }
    };
    let base = match whence {
      types::Whence::Set => 0,
      types::Whence::Cur => descriptor.position,
      types::Whence::End => size,
    };
    let position = if offset < 0 {
      base.checked_sub(offset.unsigned_abs())
    } else {
      base.checked_add(offset as u64)
    }
    .ok_or_else(|| errno(types::Errno::Inval))?;
    self.descriptor_mut(raw)?.position = position;
    Ok(position)
  }

  async fn fd_sync(&mut self, _memory: &mut GuestMemory<'_>, fd: types::Fd) -> WasiResult<()> {
    if !self
      .descriptor(fd.into())?
      .rights
      .contains(types::Rights::FD_SYNC)
    {
      return Err(errno(types::Errno::Notcapable));
    }
    Ok(())
  }
  async fn fd_tell(&mut self, _memory: &mut GuestMemory<'_>, fd: types::Fd) -> WasiResult<u64> {
    let descriptor = self.descriptor(fd.into())?;
    if !descriptor.rights.contains(types::Rights::FD_TELL) {
      return Err(errno(types::Errno::Notcapable));
    }
    Ok(descriptor.position)
  }
  async fn fd_write(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    iovs: types::CiovecArray,
  ) -> WasiResult<u32> {
    self.write_file(memory, fd.into(), iovs, None).await
  }

  async fn path_create_directory(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    path: GuestPtr<str>,
  ) -> WasiResult<()> {
    self.resolve_path(
      memory,
      fd.into(),
      path,
      types::Rights::PATH_CREATE_DIRECTORY,
    )?;
    Err(errno(types::Errno::Rofs))
  }

  async fn path_filestat_get(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    _flags: types::Lookupflags,
    path: GuestPtr<str>,
  ) -> WasiResult<types::Filestat> {
    if let Some((root, path)) =
      self.resolve_ambient_path(memory, fd.into(), path, types::Rights::PATH_FILESTAT_GET)?
    {
      let metadata = root.0.metadata(&path).map_err(io_errno)?;
      return Ok(host_filestat(metadata, &path));
    }
    let path = self.resolve_path(memory, fd.into(), path, types::Rights::PATH_FILESTAT_GET)?;
    let node = self
      .nodes
      .get(&path)
      .ok_or_else(|| errno(types::Errno::Noent))?;
    let size = match &node.kind {
      NodeKind::Directory => 0,
      NodeKind::Regular { file, .. } => file_size(file)?,
    };
    Ok(filestat(node, size))
  }

  async fn path_filestat_set_times(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    _flags: types::Lookupflags,
    path: GuestPtr<str>,
    _atim: u64,
    _mtim: u64,
    fst_flags: types::Fstflags,
  ) -> WasiResult<()> {
    validate_time_flags(fst_flags)?;
    let path = self.resolve_path(
      memory,
      fd.into(),
      path,
      types::Rights::PATH_FILESTAT_SET_TIMES,
    )?;
    if !self.nodes.contains_key(&path) {
      return Err(errno(types::Errno::Noent));
    }
    Err(errno(types::Errno::Rofs))
  }

  async fn path_link(
    &mut self,
    memory: &mut GuestMemory<'_>,
    old_fd: types::Fd,
    _old_flags: types::Lookupflags,
    old_path: GuestPtr<str>,
    new_fd: types::Fd,
    new_path: GuestPtr<str>,
  ) -> WasiResult<()> {
    let old_path = self.resolve_path(
      memory,
      old_fd.into(),
      old_path,
      types::Rights::PATH_LINK_SOURCE,
    )?;
    self.resolve_path(
      memory,
      new_fd.into(),
      new_path,
      types::Rights::PATH_LINK_TARGET,
    )?;
    if !self.nodes.contains_key(&old_path) {
      return Err(errno(types::Errno::Noent));
    }
    Err(errno(types::Errno::Rofs))
  }

  async fn path_open(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    _dirflags: types::Lookupflags,
    path: GuestPtr<str>,
    oflags: types::Oflags,
    requested: types::Rights,
    requested_inheriting: types::Rights,
    fdflags: types::Fdflags,
  ) -> WasiResult<types::Fd> {
    let parent = self.descriptor(fd.into())?.clone();
    if !parent.rights.contains(types::Rights::PATH_OPEN)
      || !parent.inheriting.contains(requested)
      || !parent.inheriting.contains(requested_inheriting)
    {
      return Err(errno(types::Errno::Notcapable));
    }
    if matches!(parent.kind, DescriptorKind::AmbientDirectory { .. }) {
      let (root, path) = self
        .resolve_ambient_path(memory, fd.into(), path, types::Rights::PATH_OPEN)?
        .ok_or_else(|| errno(types::Errno::Notdir))?;
      if root
        .0
        .metadata(&path)
        .is_ok_and(|metadata| metadata.is_dir())
      {
        if requested.intersects(ambient_file_rights()) {
          return Err(errno(types::Errno::Isdir));
        }
        let new_fd = self.next_fd();
        self.descriptors.insert(
          new_fd,
          Descriptor {
            kind: DescriptorKind::AmbientDirectory { root, path },
            pipe_roles: None,
            position: 0,
            rights: requested,
            inheriting: requested_inheriting,
            flags: fdflags,
            preopen: None,
          },
        );
        return Ok(new_fd.into());
      }
      if oflags.contains(types::Oflags::DIRECTORY) {
        return Err(errno(types::Errno::Notdir));
      }
      let mut options = cap_std::fs::OpenOptions::new();
      options
        .read(requested.contains(types::Rights::FD_READ))
        .write(requested.contains(types::Rights::FD_WRITE))
        .truncate(oflags.contains(types::Oflags::TRUNC))
        .create(oflags.contains(types::Oflags::CREAT))
        .create_new(oflags.contains(types::Oflags::EXCL));
      let file = root.0.open_with(&path, &options).map_err(io_errno)?;
      let new_fd = self.next_fd();
      self.descriptors.insert(
        new_fd,
        Descriptor {
          kind: DescriptorKind::AmbientFile {
            file: Arc::new(Mutex::new(file)),
            path,
          },
          pipe_roles: None,
          position: 0,
          rights: requested,
          inheriting: types::Rights::empty(),
          flags: fdflags,
          preopen: None,
        },
      );
      return Ok(new_fd.into());
    }
    let path = self.resolve_path(memory, fd.into(), path, types::Rights::PATH_OPEN)?;
    let Some(node) = self.nodes.get(&path).cloned() else {
      return Err(errno(if oflags.contains(types::Oflags::CREAT) {
        types::Errno::Rofs
      } else {
        types::Errno::Noent
      }));
    };
    if oflags.contains(types::Oflags::CREAT | types::Oflags::EXCL) {
      return Err(errno(types::Errno::Exist));
    }
    let directory = matches!(node.kind, NodeKind::Directory);
    let mut available = node_rights(&node);
    if !directory {
      // wasi-libc requests these inherited directory rights when opening a regular file. They are
      // inert on the resulting descriptor because path and readdir operations still require a
      // directory descriptor.
      available |=
        types::Rights::PATH_OPEN | types::Rights::PATH_FILESTAT_GET | types::Rights::FD_READDIR;
    }
    if !available.contains(requested) {
      return Err(errno(types::Errno::Notcapable));
    }
    if oflags.contains(types::Oflags::DIRECTORY) && !matches!(node.kind, NodeKind::Directory) {
      return Err(errno(types::Errno::Notdir));
    }
    if oflags.contains(types::Oflags::TRUNC) {
      if !requested.contains(types::Rights::FD_WRITE) {
        return Err(errno(types::Errno::Notcapable));
      }
      let NodeKind::Regular { file, .. } = &node.kind else {
        return Err(errno(types::Errno::Isdir));
      };
      let mut file = file.lock().unwrap();
      let SharedFile::Regular(file) = &mut *file else {
        return Err(errno(types::Errno::Isdir));
      };
      file.resize(0)?;
    }
    let kind = match node.kind {
      NodeKind::Directory => DescriptorKind::Directory { path },
      NodeKind::Regular { file, .. } => DescriptorKind::File { file },
    };
    let new_fd = self.next_fd();
    self.descriptors.insert(
      new_fd,
      Descriptor {
        kind,
        pipe_roles: None,
        position: 0,
        rights: requested,
        inheriting: requested_inheriting,
        flags: fdflags,
        preopen: None,
      },
    );
    Ok(new_fd.into())
  }

  async fn path_readlink(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    path: GuestPtr<str>,
    _buf: GuestPtr<u8>,
    _buf_len: u32,
  ) -> WasiResult<u32> {
    let path = self.resolve_path(memory, fd.into(), path, types::Rights::PATH_READLINK)?;
    if !self.nodes.contains_key(&path) {
      return Err(errno(types::Errno::Noent));
    }
    Err(errno(types::Errno::Inval))
  }

  async fn path_remove_directory(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    path: GuestPtr<str>,
  ) -> WasiResult<()> {
    let path = self.resolve_path(
      memory,
      fd.into(),
      path,
      types::Rights::PATH_REMOVE_DIRECTORY,
    )?;
    match self.nodes.get(&path).map(|node| &node.kind) {
      None => Err(errno(types::Errno::Noent)),
      Some(NodeKind::Regular { .. }) => Err(errno(types::Errno::Notdir)),
      Some(NodeKind::Directory) => Err(errno(types::Errno::Rofs)),
    }
  }

  async fn path_rename(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    old_path: GuestPtr<str>,
    new_fd: types::Fd,
    new_path: GuestPtr<str>,
  ) -> WasiResult<()> {
    let old_path = self.resolve_path(
      memory,
      fd.into(),
      old_path,
      types::Rights::PATH_RENAME_SOURCE,
    )?;
    self.resolve_path(
      memory,
      new_fd.into(),
      new_path,
      types::Rights::PATH_RENAME_TARGET,
    )?;
    if !self.nodes.contains_key(&old_path) {
      return Err(errno(types::Errno::Noent));
    }
    Err(errno(types::Errno::Rofs))
  }

  async fn path_symlink(
    &mut self,
    memory: &mut GuestMemory<'_>,
    old_path: GuestPtr<str>,
    fd: types::Fd,
    new_path: GuestPtr<str>,
  ) -> WasiResult<()> {
    self.read_path(memory, old_path)?;
    self.resolve_path(memory, fd.into(), new_path, types::Rights::PATH_SYMLINK)?;
    Err(errno(types::Errno::Rofs))
  }

  async fn path_unlink_file(
    &mut self,
    memory: &mut GuestMemory<'_>,
    fd: types::Fd,
    path: GuestPtr<str>,
  ) -> WasiResult<()> {
    let path = self.resolve_path(memory, fd.into(), path, types::Rights::PATH_UNLINK_FILE)?;
    match self.nodes.get(&path).map(|node| &node.kind) {
      None => Err(errno(types::Errno::Noent)),
      Some(NodeKind::Directory) => Err(errno(types::Errno::Isdir)),
      Some(NodeKind::Regular { .. }) => Err(errno(types::Errno::Rofs)),
    }
  }

  async fn poll_oneoff(
    &mut self,
    memory: &mut GuestMemory<'_>,
    subscriptions: GuestPtr<types::Subscription>,
    events: GuestPtr<types::Event>,
    count: u32,
  ) -> WasiResult<u32> {
    if count == 0 {
      return Err(errno(types::Errno::Inval));
    }
    // Scan guest subscriptions in place instead of mirroring guest-controlled arrays in host
    // Vecs. The guest cannot mutate linear memory while this async hostcall is suspended.
    poll_fn(|context| {
      let result = (|| {
        let mut ready_count = 0_u32;
        for index in 0..count {
          let subscription = memory.read(subscriptions.add(index)?)?;
          if let Some(event) = poll_subscription(&self.descriptors, &subscription, context.waker())
          {
            memory.write(events.add(ready_count)?, event)?;
            ready_count += 1;
          }
        }
        Ok(ready_count)
      })();
      match result {
        Ok(0) => Poll::Pending,
        Ok(ready_count) => Poll::Ready(Ok(ready_count)),
        Err(error) => Poll::Ready(Err(error)),
      }
    })
    .await
  }

  async fn proc_exit(&mut self, _memory: &mut GuestMemory<'_>, code: u32) -> wiggle::error::Error {
    ProcessExit(code as i32).into()
  }
  async fn proc_raise(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    _signal: types::Signal,
  ) -> WasiResult<()> {
    Err(errno(types::Errno::Notsup))
  }
  async fn sched_yield(&mut self, _memory: &mut GuestMemory<'_>) -> WasiResult<()> {
    Ok(())
  }

  async fn random_get(
    &mut self,
    memory: &mut GuestMemory<'_>,
    buffer: GuestPtr<u8>,
    length: u32,
  ) -> WasiResult<()> {
    let mut remaining = length;
    let mut buffer = buffer;
    let mut bytes = vec![0; COPY_BUFFER_SIZE];
    while remaining != 0 {
      let count = remaining.min(COPY_BUFFER_SIZE as u32);
      let chunk = &mut bytes[..count as usize];
      self
        .random
        .try_fill_bytes(chunk)
        .map_err(|error| types::Error::trap(error.into()))?;
      write_bytes(memory, buffer, chunk)?;
      buffer = buffer.add(count)?;
      remaining -= count;
    }
    Ok(())
  }

  async fn sock_accept(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    _fd: types::Fd,
    _flags: types::Fdflags,
  ) -> WasiResult<types::Fd> {
    Err(errno(types::Errno::Notsup))
  }
  async fn sock_recv(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    _fd: types::Fd,
    _data: types::IovecArray,
    _flags: types::Riflags,
  ) -> WasiResult<(u32, types::Roflags)> {
    Err(errno(types::Errno::Notsup))
  }
  async fn sock_send(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    _fd: types::Fd,
    _data: types::CiovecArray,
    _flags: types::Siflags,
  ) -> WasiResult<u32> {
    Err(errno(types::Errno::Notsup))
  }
  async fn sock_shutdown(
    &mut self,
    _memory: &mut GuestMemory<'_>,
    _fd: types::Fd,
    _how: types::Sdflags,
  ) -> WasiResult<()> {
    Err(errno(types::Errno::Notsup))
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn truncate_hides_discarded_snapshot_bytes_after_growth() {
    let mut source = tempfile::NamedTempFile::new().unwrap();
    source.write_all(b"abcdef").unwrap();
    let mut file = RegularFile::snapshot(source.path(), None, 16).unwrap();

    assert_eq!(file.read(0, 6).unwrap(), b"abcdef");
    file.resize(3).unwrap();
    file.resize(6).unwrap();

    assert_eq!(file.read(0, 6).unwrap(), b"abc\0\0\0");
  }

  #[test]
  fn file_limit_failure_preserves_successful_contents() {
    let mut file = RegularFile::empty(None, 4);
    file.write(0, b"abcd").unwrap();

    assert!(file.write(4, b"e").is_err());
    assert!(file.resize(5).is_err());

    assert!(file.exceeded);
    assert_eq!(file.length, 4);
    assert_eq!(file.read(0, 8).unwrap(), b"abcd");
  }

  #[test]
  fn rw_commit_preserves_snapshot_outside_dirty_range() {
    let destination = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(destination.path(), b"abcdef").unwrap();
    let path = destination.path().to_owned();
    let mut file = RegularFile::snapshot(&path, Some(path.clone()), 16).unwrap();
    file.write(2, b"XY").unwrap();

    let (destination, temporary) = file.materialize().unwrap().unwrap();
    temporary.persist(destination).unwrap();

    assert_eq!(std::fs::read(path).unwrap(), b"abXYef");
  }

  #[test]
  fn write_only_commit_replaces_old_destination_with_sparse_file() {
    let destination = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(destination.path(), b"old contents").unwrap();
    let path = destination.path().to_owned();
    let mut file = RegularFile::empty(Some(path.clone()), 16);
    file.write(3, b"z").unwrap();

    let (destination, temporary) = file.materialize().unwrap().unwrap();
    temporary.persist(destination).unwrap();

    assert_eq!(std::fs::read(path).unwrap(), b"\0\0\0z");
  }
}
