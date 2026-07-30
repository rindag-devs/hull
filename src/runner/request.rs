use std::{
  collections::{HashMap, HashSet},
  fmt,
  path::{Path, PathBuf},
};

use anyhow::{Result, anyhow, bail};
use serde::{
  Deserialize, Deserializer, Serialize, Serializer,
  de::{self, Visitor},
};

/// A strict deterministic execution request.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionRequest {
  /// Destination for the metadata report.
  pub report_path: PathBuf,
  /// Named session files.
  pub files: Vec<File>,
  /// Programs in deterministic request order.
  pub programs: Vec<ProgramRequest>,
}

/// Permissions granted to a file or stream descriptor.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum FilePermissions {
  /// Grants neither reads nor writes.
  None = 0,
  /// Grants writes only.
  Write = 2,
  /// Grants reads only.
  Read = 4,
  /// Grants both reads and writes.
  ReadWrite = 6,
}

impl FilePermissions {
  fn can_read(self) -> bool {
    self as u8 & Self::Read as u8 != 0
  }

  fn can_write(self) -> bool {
    self as u8 & Self::Write as u8 != 0
  }

  fn is_subset_of(self, maximum: Self) -> bool {
    self as u8 & !(maximum as u8) == 0
  }
}

impl Serialize for FilePermissions {
  fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
  where
    S: Serializer,
  {
    serializer.serialize_u8(*self as u8)
  }
}

struct FilePermissionsVisitor;

impl Visitor<'_> for FilePermissionsVisitor {
  type Value = FilePermissions;

  fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
    formatter.write_str("one of the numeric file permission values 0, 2, 4, or 6")
  }

  fn visit_u64<E>(self, value: u64) -> std::result::Result<Self::Value, E>
  where
    E: de::Error,
  {
    match value {
      0 => Ok(FilePermissions::None),
      2 => Ok(FilePermissions::Write),
      4 => Ok(FilePermissions::Read),
      6 => Ok(FilePermissions::ReadWrite),
      _ => Err(E::invalid_value(de::Unexpected::Unsigned(value), &self)),
    }
  }
}

impl<'de> Deserialize<'de> for FilePermissions {
  fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
  where
    D: Deserializer<'de>,
  {
    deserializer.deserialize_u64(FilePermissionsVisitor)
  }
}

/// Permissions granted to a guest directory.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum DirectoryPermissions {
  /// Grants neither reads nor traversal.
  None = 0,
  /// Grants traversal only.
  Execute = 1,
  /// Grants reads only.
  Read = 4,
  /// Grants both reads and traversal.
  ReadExecute = 5,
}

impl Serialize for DirectoryPermissions {
  fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
  where
    S: Serializer,
  {
    serializer.serialize_u8(*self as u8)
  }
}

struct DirectoryPermissionsVisitor;

impl Visitor<'_> for DirectoryPermissionsVisitor {
  type Value = DirectoryPermissions;

  fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
    formatter.write_str("one of the numeric directory permission values 0, 1, 4, or 5")
  }

  fn visit_u64<E>(self, value: u64) -> std::result::Result<Self::Value, E>
  where
    E: de::Error,
  {
    match value {
      0 => Ok(DirectoryPermissions::None),
      1 => Ok(DirectoryPermissions::Execute),
      4 => Ok(DirectoryPermissions::Read),
      5 => Ok(DirectoryPermissions::ReadExecute),
      _ => Err(E::invalid_value(de::Unexpected::Unsigned(value), &self)),
    }
  }
}

impl<'de> Deserialize<'de> for DirectoryPermissions {
  fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
  where
    D: Deserializer<'de>,
  {
    deserializer.deserialize_u64(DirectoryPermissionsVisitor)
  }
}

/// A named session file.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum File {
  /// A seekable regular file with bounded capabilities and logical size.
  Regular {
    /// Unique file name.
    name: String,
    /// Optional host snapshot source or commit destination.
    host_path: Option<PathBuf>,
    /// Maximum permissions any descriptor or path binding may receive.
    max_permissions: FilePermissions,
    /// Logical file-size ceiling.
    size_limit: FileSizeLimit,
  },
  /// A bounded in-process byte stream.
  Pipe {
    /// Unique file name.
    name: String,
    /// Ring-buffer capacity.
    capacity: u64,
    /// Cumulative stream-length ceiling.
    size_limit: FileSizeLimit,
  },
}

impl File {
  /// Creates a bounded regular file.
  pub fn regular(
    name: impl Into<String>,
    host_path: Option<PathBuf>,
    max_permissions: FilePermissions,
    size_limit: FileSizeLimit,
  ) -> Self {
    Self::Regular {
      name: name.into(),
      host_path,
      max_permissions,
      size_limit,
    }
  }

  /// Creates a bounded pipe.
  pub fn pipe(name: impl Into<String>, capacity: u64, size_limit: FileSizeLimit) -> Self {
    Self::Pipe {
      name: name.into(),
      capacity,
      size_limit,
    }
  }

  /// Returns the file's unique request name.
  pub fn name(&self) -> &str {
    match self {
      Self::Regular { name, .. } | Self::Pipe { name, .. } => name,
    }
  }
}

/// A JSON byte limit or Hull's trusted-tool ceiling.
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(untagged)]
pub enum FileSizeLimit {
  /// An explicit byte count.
  Bytes(u64),
  /// The exact string `tool`.
  Tool(ToolLimit),
}

/// Marker accepted only from the JSON string `tool`.
#[derive(Clone, Copy, Debug, Deserialize)]
pub enum ToolLimit {
  /// Selects the trusted-tool file-size ceiling.
  #[serde(rename = "tool")]
  Tool,
}

impl FileSizeLimit {
  /// Resolves the JSON representation without saturating host-width conversion.
  pub fn resolve(self) -> Result<usize> {
    match self {
      Self::Bytes(value) => usize::try_from(value)
        .map_err(|_| anyhow!("file size limit does not fit the host address width")),
      Self::Tool(_) => Ok(super::TOOL_FILE_SIZE_LIMIT),
    }
  }
}

/// One descriptor installed before a program starts.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InitialDescriptor {
  /// Referenced file, or `None` for `/dev/null`.
  pub file: Option<String>,
  /// Permissions granted to this descriptor.
  pub permissions: FilePermissions,
}

/// One program in a session.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProgramRequest {
  /// Unique program name.
  pub name: String,
  /// Authoritative source Wasm path.
  pub wasm_path: PathBuf,
  /// Arguments after synthetic `argv[0]`.
  pub arguments: Vec<String>,
  /// Guest tick ceiling.
  #[serde(deserialize_with = "deserialize_tick_limit")]
  pub tick_limit: u64,
  /// Linear-memory and execution-stack byte ceiling.
  #[serde(deserialize_with = "deserialize_memory_limit")]
  pub memory_limit: u64,
  /// Whether a non-accepted result fails the command.
  pub required_accepted: bool,
  /// Complete immutable guest filesystem view.
  pub file_system: FileSystem,
  /// Descriptors installed at fd 0, 1, 2, then fd 4 and above.
  pub initial_descriptors: Vec<InitialDescriptor>,
}

impl ProgramRequest {
  /// Returns whether this program has a write-capable descriptor or binding for a file.
  pub fn writes_file(&self, file: &str) -> bool {
    self.initial_descriptors.iter().any(|descriptor| {
      descriptor.file.as_deref() == Some(file) && descriptor.permissions.can_write()
    }) || self
      .file_system
      .bindings
      .iter()
      .any(|binding| binding.file == file && binding.permissions.can_write())
  }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ProgramLimit {
  Value(u64),
  Tool(ToolLimit),
}

fn deserialize_tick_limit<'de, D>(deserializer: D) -> std::result::Result<u64, D::Error>
where
  D: Deserializer<'de>,
{
  deserialize_program_limit(deserializer, super::TOOL_TICK_LIMIT)
}

fn deserialize_memory_limit<'de, D>(deserializer: D) -> std::result::Result<u64, D::Error>
where
  D: Deserializer<'de>,
{
  deserialize_program_limit(deserializer, super::TOOL_MEMORY_LIMIT)
}

fn deserialize_program_limit<'de, D>(
  deserializer: D,
  tool_limit: u64,
) -> std::result::Result<u64, D::Error>
where
  D: Deserializer<'de>,
{
  Ok(match ProgramLimit::deserialize(deserializer)? {
    ProgramLimit::Value(value) => value,
    ProgramLimit::Tool(_) => tool_limit,
  })
}

/// A declared immutable guest entry tree.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileSystem {
  /// Declared directories.
  pub directories: Vec<DirectoryBinding>,
  /// Declared regular files.
  pub bindings: Vec<FileBinding>,
}

/// A guest directory binding.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DirectoryBinding {
  /// Normalized guest path.
  pub path: String,
  /// Permissions granted through this guest path.
  pub permissions: DirectoryPermissions,
}

/// A guest regular file binding.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileBinding {
  /// Normalized guest path.
  pub path: String,
  /// Referenced top-level file.
  pub file: String,
  /// Permissions granted through this guest path.
  pub permissions: FilePermissions,
}

/// Stable runner verdict.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
  /// Successful zero exit.
  Accepted,
  /// Guest trap or nonzero exit.
  RuntimeError,
  /// Tick exhaustion or protocol deadlock.
  TimeLimitExceeded,
  /// Denied linear-memory growth.
  MemoryLimitExceeded,
  /// File or stream length exceeded its declared ceiling.
  FileError,
  /// Invalid module or host setup failure.
  InternalError,
}

/// Metadata for one program execution.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProgramResult {
  /// Program name.
  pub program: String,
  /// Stable verdict.
  pub status: RunStatus,
  /// Consumed guest ticks.
  pub tick: u64,
  /// Peak requested linear memory.
  pub memory: u64,
  /// Normal return or `proc_exit` code.
  pub exit_code: Option<i32>,
  /// Small diagnostic text.
  pub error_message: Option<String>,
}

impl ProgramResult {
  /// Constructs a setup-failure result.
  pub fn internal_error(program: String, message: String) -> Self {
    Self {
      program,
      status: RunStatus::InternalError,
      tick: 0,
      memory: 0,
      exit_code: None,
      error_message: Some(message),
    }
  }
}

/// A detected minimal protocol deadlock component.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Deadlock {
  /// Programs in request order.
  pub programs: Vec<String>,
  /// Pipes in request order.
  pub pipes: Vec<String>,
}

/// Complete small session metadata report.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SessionReport {
  /// One result per program in request order.
  pub results: Vec<ProgramResult>,
  /// Minimal deadlock components.
  pub deadlocks: Vec<Deadlock>,
}

impl SessionReport {
  /// Constructs one setup-failure result for every requested program.
  pub fn internal_errors(programs: &[ProgramRequest], message: impl Into<String>) -> Self {
    let message = message.into();
    Self {
      results: programs
        .iter()
        .map(|program| ProgramResult::internal_error(program.name.clone(), message.clone()))
        .collect(),
      deadlocks: Vec::new(),
    }
  }
}

impl SessionRequest {
  /// Resolves all relative host paths against the request file's parent.
  pub fn resolve_paths(&mut self, request_path: &Path) {
    let parent = request_path.parent().unwrap_or_else(|| Path::new("."));
    resolve_path(&mut self.report_path, parent);
    for file in &mut self.files {
      if let File::Regular {
        host_path: Some(path),
        ..
      } = file
      {
        resolve_path(path, parent);
      }
    }
    for program in &mut self.programs {
      resolve_path(&mut program.wasm_path, parent);
    }
  }

  /// Validates names, references, capabilities, paths, ownership, and endpoints.
  pub fn validate(&self) -> Result<()> {
    if self.programs.is_empty() {
      bail!("programs must not be empty");
    }
    unique(self.files.iter().map(File::name), "file")?;
    unique(
      self.programs.iter().map(|program| program.name.as_str()),
      "program",
    )?;
    validate_host_paths(self)?;
    let files = self
      .files
      .iter()
      .map(|file| (file.name(), file))
      .collect::<HashMap<_, _>>();
    for file in &self.files {
      match file {
        File::Regular {
          host_path,
          max_permissions,
          size_limit,
          ..
        } => {
          size_limit.resolve()?;
          if host_path.is_some() && *max_permissions == FilePermissions::None {
            bail!("regular file with no permissions must not have a host path");
          }
        }
        File::Pipe {
          capacity,
          size_limit,
          ..
        } => {
          size_limit.resolve()?;
          if *capacity == 0 {
            bail!("pipe capacity must be positive");
          }
          usize::try_from(*capacity)
            .map_err(|_| anyhow!("pipe capacity does not fit the host address width"))?;
        }
      }
    }
    for program in &self.programs {
      usize::try_from(program.memory_limit)
        .map_err(|_| anyhow!("memory limit does not fit the host address width"))?;
      validate_initial_descriptors(program, &files)?;
      validate_file_system(&program.file_system, &files)?;
    }
    validate_pipe_endpoints(&self.files, &self.programs)?;
    validate_file_writer_ownership(&self.files, &self.programs)?;
    Ok(())
  }
}

fn validate_host_paths(request: &SessionRequest) -> Result<()> {
  let report = normalize_host_path(&request.report_path)?;
  let mut wasm_paths = Vec::<PathBuf>::new();
  for program in &request.programs {
    let path = normalize_host_path(&program.wasm_path)?;
    if paths_overlap(&path, &report)
      || wasm_paths
        .iter()
        .any(|other| path != *other && paths_overlap(&path, other))
    {
      bail!(
        "Wasm host path `{}` conflicts with another session path",
        path.display()
      );
    }
    if !wasm_paths.contains(&path) {
      wasm_paths.push(path);
    }
  }

  let mut mapped = Vec::<(&str, PathBuf)>::new();
  for file in &request.files {
    let File::Regular {
      name,
      host_path: Some(path),
      max_permissions,
      ..
    } = file
    else {
      continue;
    };
    let path = normalize_host_path(path)?;
    if paths_overlap(&path, &report)
      || wasm_paths.iter().any(|other| paths_overlap(&path, other))
      || mapped
        .iter()
        .any(|(other_name, other)| *other_name != name && paths_overlap(&path, other))
    {
      bail!(
        "file host path `{}` conflicts with another session path",
        path.display()
      );
    }
    validate_host_file_role(&path, *max_permissions)?;
    mapped.push((name, path));
  }
  Ok(())
}

fn validate_host_file_role(path: &Path, permissions: FilePermissions) -> Result<()> {
  if permissions.can_read() {
    let metadata = std::fs::metadata(path).map_err(|error| {
      anyhow!(
        "snapshot source `{}` is unavailable: {error}",
        path.display()
      )
    })?;
    if !metadata.is_file() {
      bail!("snapshot source `{}` is not a regular file", path.display());
    }
  } else if permissions.can_write() && path.exists() && !std::fs::metadata(path)?.is_file() {
    bail!(
      "commit destination `{}` is not a regular file",
      path.display()
    );
  }
  Ok(())
}

fn normalize_host_path(path: &Path) -> Result<PathBuf> {
  if path
    .components()
    .any(|component| matches!(component, std::path::Component::ParentDir))
  {
    bail!("host path `{}` is not normalized", path.display());
  }
  if path.file_name().is_none() {
    bail!("host path `{}` has no file name", path.display());
  }
  let path = if path.is_relative() {
    Path::new(".").join(path)
  } else {
    path.to_owned()
  };
  let mut ancestor = path.as_path();
  let mut suffix = Vec::new();
  while !ancestor.exists() {
    suffix.push(
      ancestor
        .file_name()
        .ok_or_else(|| anyhow!("host path `{}` has no existing ancestor", path.display()))?
        .to_owned(),
    );
    ancestor = ancestor.parent().unwrap_or_else(|| Path::new("."));
  }
  let mut normalized = std::fs::canonicalize(ancestor)?;
  for component in suffix.into_iter().rev() {
    normalized.push(component);
  }
  Ok(normalized)
}

fn paths_overlap(left: &Path, right: &Path) -> bool {
  left.starts_with(right) || right.starts_with(left)
}

fn validate_initial_descriptors(
  program: &ProgramRequest,
  files: &HashMap<&str, &File>,
) -> Result<()> {
  validate_descriptor_count(program.initial_descriptors.len())?;
  for descriptor in &program.initial_descriptors {
    let Some(name) = descriptor.file.as_deref() else {
      continue;
    };
    match files.get(name) {
      Some(File::Regular {
        max_permissions, ..
      }) if descriptor.permissions.is_subset_of(*max_permissions) => {}
      Some(File::Regular { .. }) => {
        bail!("initial descriptor permissions exceed file `{name}` capability")
      }
      Some(File::Pipe { .. }) => {}
      None => bail!("unknown initial descriptor file `{name}`"),
    }
  }
  Ok(())
}

fn validate_descriptor_count(count: usize) -> Result<()> {
  if count < 3 {
    bail!("initial_descriptors must contain at least fd 0, 1, and 2");
  }
  // wasi-libc probes preopens from fd 3 until the first BADF, so the root owns fd 3 and extra
  // descriptors begin at fd 4. The count equals the highest assigned fd and must fit WASI's u32.
  u32::try_from(count).map_err(|_| anyhow!("initial descriptor fd does not fit u32"))?;
  Ok(())
}

fn validate_file_system(file_system: &FileSystem, files: &HashMap<&str, &File>) -> Result<()> {
  let mut paths = HashSet::new();
  let mut directories = HashSet::new();
  for directory in &file_system.directories {
    normalized(&directory.path)?;
    if !paths.insert(directory.path.as_str()) {
      bail!("duplicate file system path `{}`", directory.path);
    }
    directories.insert(directory.path.as_str());
  }
  if !directories.contains(".") {
    bail!("file system must declare the root directory `.`");
  }
  for binding in &file_system.bindings {
    normalized(&binding.path)?;
    if !paths.insert(binding.path.as_str()) {
      bail!("duplicate file system path `{}`", binding.path);
    }
    match files.get(binding.file.as_str()) {
      Some(File::Regular {
        max_permissions, ..
      }) if binding.permissions.is_subset_of(*max_permissions) => {}
      Some(File::Regular { .. }) => {
        bail!(
          "binding permissions exceed file `{}` capability",
          binding.file
        )
      }
      Some(File::Pipe { .. }) => bail!("pipe cannot be a guest-path binding"),
      None => bail!("unknown file `{}`", binding.file),
    }
  }
  for directory in &file_system.directories {
    validate_declared_parent(&directory.path, &directories)?;
  }
  for binding in &file_system.bindings {
    validate_declared_parent(&binding.path, &directories)?;
  }
  Ok(())
}

fn validate_declared_parent(path: &str, directories: &HashSet<&str>) -> Result<()> {
  if path != "." {
    let parent = path.rsplit_once('/').map_or(".", |(parent, _)| parent);
    if !directories.contains(parent) {
      bail!("undeclared parent directory `{parent}` for `{path}`");
    }
  }
  Ok(())
}

fn validate_pipe_endpoints(files: &[File], programs: &[ProgramRequest]) -> Result<()> {
  let mut endpoints = files
    .iter()
    .filter_map(|file| match file {
      File::Pipe { name, .. } => Some((name.as_str(), (0usize, 0usize))),
      File::Regular { .. } => None,
    })
    .collect::<HashMap<_, _>>();
  for program in programs {
    for descriptor in &program.initial_descriptors {
      let Some(counts) = descriptor
        .file
        .as_deref()
        .and_then(|name| endpoints.get_mut(name))
      else {
        continue;
      };
      counts.0 += usize::from(descriptor.permissions.can_read());
      counts.1 += usize::from(descriptor.permissions.can_write());
    }
  }
  for file in files {
    if let File::Pipe { name, .. } = file {
      let (readers, writers) = endpoints[name.as_str()];
      if readers != 1 || writers != 1 {
        bail!("pipe `{name}` must have exactly one reader and one writer");
      }
    }
  }
  Ok(())
}

fn validate_file_writer_ownership(files: &[File], programs: &[ProgramRequest]) -> Result<()> {
  for file in files.iter().filter_map(|file| match file {
    File::Regular { name, .. } => Some(name.as_str()),
    File::Pipe { .. } => None,
  }) {
    let mut writers = programs.iter().filter(|program| program.writes_file(file));
    if writers.next().is_some() && writers.next().is_some() {
      bail!("file `{file}` has multiple writer programs");
    }
  }
  Ok(())
}

fn resolve_path(path: &mut PathBuf, parent: &Path) {
  if path.is_relative() {
    *path = parent.join(&*path);
  }
}

fn unique<'a>(items: impl Iterator<Item = &'a str>, kind: &str) -> Result<()> {
  let mut seen = HashSet::new();
  for item in items {
    if item.is_empty() || !seen.insert(item) {
      return Err(anyhow!("invalid or duplicate {kind} name `{item}`"));
    }
  }
  Ok(())
}

fn normalized(path: &str) -> Result<()> {
  if path != "."
    && (path.is_empty()
      || path.starts_with('/')
      || path.ends_with('/')
      || path
        .split('/')
        .any(|component| component.is_empty() || matches!(component, "." | "..")))
  {
    bail!("guest path `{path}` is not normalized");
  }
  Ok(())
}

#[cfg(test)]
mod tests {
  use super::*;

  fn null_descriptors() -> Vec<InitialDescriptor> {
    (0..3)
      .map(|_| InitialDescriptor {
        file: None,
        permissions: FilePermissions::None,
      })
      .collect()
  }

  fn program(name: &str) -> ProgramRequest {
    ProgramRequest {
      name: name.into(),
      wasm_path: format!("{name}.wasm").into(),
      arguments: Vec::new(),
      tick_limit: 1,
      memory_limit: 1,
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

  fn valid_request() -> SessionRequest {
    SessionRequest {
      report_path: "report.json".into(),
      files: Vec::new(),
      programs: vec![program("main")],
    }
  }

  fn validation_error(request: &SessionRequest, message: &str) {
    let error = request.validate().unwrap_err().to_string();
    assert!(
      error.contains(message),
      "expected `{message}` in validation error `{error}`"
    );
  }

  fn request(file: &str, descriptors: &str) -> String {
    format!(
      r#"{{
        "report_path":"report.json",
        "files":[{file}],
        "programs":[{{
          "name":"main","wasm_path":"main.wasm","arguments":[],
          "tick_limit":1,"memory_limit":1,"required_accepted":true,
          "file_system":{{"directories":[{{"path":".","permissions":5}}],"bindings":[]}},
          "initial_descriptors":{descriptors}
        }}]
      }}"#
    )
  }

  #[test]
  fn permissions_serde_accepts_only_abi_values() {
    for (json, expected) in [
      ("0", FilePermissions::None),
      ("2", FilePermissions::Write),
      ("4", FilePermissions::Read),
      ("6", FilePermissions::ReadWrite),
    ] {
      assert_eq!(
        serde_json::from_str::<FilePermissions>(json).unwrap(),
        expected
      );
      assert_eq!(serde_json::to_string(&expected).unwrap(), json);
    }
    for json in ["1", "3", "5", "7", "-2", "\"4\""] {
      assert!(
        serde_json::from_str::<FilePermissions>(json).is_err(),
        "{json}"
      );
    }
  }

  #[test]
  fn strict_schema_deserializes() {
    let json = request(
      r#"{"kind":"regular","name":"data","host_path":null,"max_permissions":6,"size_limit":8}"#,
      r#"[{"file":"data","permissions":4},{"file":null,"permissions":2},{"file":null,"permissions":0}]"#,
    );
    serde_json::from_str::<SessionRequest>(&json)
      .unwrap()
      .validate()
      .unwrap();
  }

  #[test]
  fn descriptors_require_three_entries_and_known_capabilities() {
    let mut request = valid_request();
    request.programs[0].initial_descriptors.pop();
    validation_error(&request, "at least fd 0, 1, and 2");

    request = valid_request();
    request.programs[0].initial_descriptors[0].file = Some("missing".into());
    validation_error(&request, "unknown initial descriptor file");

    request.files.push(File::regular(
      "data",
      None,
      FilePermissions::Read,
      FileSizeLimit::Bytes(1),
    ));
    request.programs[0].initial_descriptors[0] = InitialDescriptor {
      file: Some("data".into()),
      permissions: FilePermissions::Write,
    };
    validation_error(&request, "permissions exceed file");
  }

  #[test]
  #[cfg(target_pointer_width = "64")]
  fn descriptor_fd_overflow_is_rejected() {
    validation_error_from(
      validate_descriptor_count(u32::MAX as usize + 1),
      "does not fit u32",
    );
  }

  fn validation_error_from(result: Result<()>, message: &str) {
    let error = result.unwrap_err().to_string();
    assert!(error.contains(message), "expected `{message}` in `{error}`");
  }

  #[test]
  fn pipe_requires_exact_permission_derived_endpoints() {
    let mut request = valid_request();
    request
      .files
      .push(File::pipe("pipe", 1, FileSizeLimit::Bytes(8)));
    validation_error(&request, "exactly one reader and one writer");

    request.programs[0].initial_descriptors[0] = InitialDescriptor {
      file: Some("pipe".into()),
      permissions: FilePermissions::ReadWrite,
    };
    request.validate().unwrap();

    request.programs[0].initial_descriptors[1] = InitialDescriptor {
      file: Some("pipe".into()),
      permissions: FilePermissions::None,
    };
    request.validate().unwrap();

    request.programs[0].initial_descriptors[1].permissions = FilePermissions::Read;
    validation_error(&request, "exactly one reader and one writer");
  }

  #[test]
  fn file_write_attribution_follows_permissions() {
    let mut program = program("main");
    program.initial_descriptors[0] = InitialDescriptor {
      file: Some("pipe".into()),
      permissions: FilePermissions::Read,
    };
    program.initial_descriptors[1] = InitialDescriptor {
      file: Some("output".into()),
      permissions: FilePermissions::Write,
    };
    program.file_system.bindings.push(FileBinding {
      path: "input".into(),
      file: "input".into(),
      permissions: FilePermissions::None,
    });

    assert!(!program.writes_file("pipe"));
    assert!(program.writes_file("output"));
    assert!(!program.writes_file("input"));

    program.initial_descriptors[0].permissions = FilePermissions::ReadWrite;
    assert!(program.writes_file("pipe"));
  }

  #[test]
  fn file_bindings_enforce_type_capability_and_tree() {
    let mut request = valid_request();
    request.files.push(File::regular(
      "data",
      None,
      FilePermissions::Read,
      FileSizeLimit::Bytes(1),
    ));
    request.programs[0].file_system.bindings.push(FileBinding {
      path: "data".into(),
      file: "data".into(),
      permissions: FilePermissions::Write,
    });
    validation_error(&request, "binding permissions exceed");

    request.programs[0].file_system.bindings[0].permissions = FilePermissions::Read;
    request.validate().unwrap();

    request.files = vec![File::pipe("pipe", 1, FileSizeLimit::Bytes(1))];
    request.programs[0].file_system.bindings[0].file = "pipe".into();
    request.programs[0].initial_descriptors[0] = InitialDescriptor {
      file: Some("pipe".into()),
      permissions: FilePermissions::ReadWrite,
    };
    validation_error(&request, "pipe cannot be a guest-path binding");
  }

  #[test]
  fn file_allows_aliases_within_one_writer_program() {
    let mut request = valid_request();
    request.files.push(File::regular(
      "data",
      None,
      FilePermissions::ReadWrite,
      FileSizeLimit::Bytes(1),
    ));
    request.programs[0].initial_descriptors[0] = InitialDescriptor {
      file: Some("data".into()),
      permissions: FilePermissions::Write,
    };
    request.programs[0].file_system.bindings.push(FileBinding {
      path: "data".into(),
      file: "data".into(),
      permissions: FilePermissions::ReadWrite,
    });
    request.validate().unwrap();
  }

  #[test]
  fn file_rejects_multiple_writer_programs() {
    let mut request = valid_request();
    request.files.push(File::regular(
      "data",
      None,
      FilePermissions::Write,
      FileSizeLimit::Bytes(1),
    ));
    request.programs[0].initial_descriptors[0] = InitialDescriptor {
      file: Some("data".into()),
      permissions: FilePermissions::Write,
    };
    let mut second = program("second");
    second.initial_descriptors[1] = InitialDescriptor {
      file: Some("data".into()),
      permissions: FilePermissions::Write,
    };
    request.programs.push(second);
    validation_error(&request, "multiple writer programs");
  }

  #[test]
  fn host_paths_follow_permission_roles_and_reject_aliases() {
    let mut request = valid_request();
    request.files.push(File::regular(
      "none",
      Some("unused".into()),
      FilePermissions::None,
      FileSizeLimit::Bytes(1),
    ));
    validation_error(&request, "no permissions must not have a host path");

    request.files[0] = File::regular(
      "source",
      Some("missing-source".into()),
      FilePermissions::Read,
      FileSizeLimit::Bytes(1),
    );
    validation_error(&request, "snapshot source");

    request.files[0] = File::regular(
      "destination",
      Some("report.json".into()),
      FilePermissions::Write,
      FileSizeLimit::Bytes(1),
    );
    validation_error(&request, "conflicts with another session path");

    request.files = vec![
      File::regular(
        "first",
        Some("destination".into()),
        FilePermissions::Write,
        FileSizeLimit::Bytes(1),
      ),
      File::regular(
        "second",
        Some("./destination".into()),
        FilePermissions::Write,
        FileSizeLimit::Bytes(1),
      ),
    ];
    validation_error(&request, "conflicts with another session path");
  }

  #[test]
  fn report_and_wasm_paths_must_not_alias() {
    let mut request = valid_request();
    request.programs[0].wasm_path = request.report_path.clone();
    validation_error(&request, "Wasm host path");
  }

  #[test]
  fn relative_host_paths_follow_request_parent() {
    let json = request(
      r#"{"kind":"regular","name":"data","host_path":"input","max_permissions":2,"size_limit":8}"#,
      r#"[{"file":null,"permissions":0},{"file":null,"permissions":0},{"file":null,"permissions":0}]"#,
    );
    let mut request = serde_json::from_str::<SessionRequest>(&json).unwrap();
    request.resolve_paths(Path::new("work/request.json"));
    assert_eq!(request.report_path, Path::new("work/report.json"));
    assert_eq!(request.programs[0].wasm_path, Path::new("work/main.wasm"));
    assert!(matches!(
      &request.files[0],
      File::Regular { host_path: Some(path), .. } if path == Path::new("work/input")
    ));
  }
}
