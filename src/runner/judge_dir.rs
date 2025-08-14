use std::{
  any::Any,
  collections::{HashMap, hash_map::DefaultHasher},
  hash::{Hash, Hasher},
  path::PathBuf,
};

use anyhow::{Context, Result};
use wasi_common::{
  Error, ErrorExt, SystemTimeSpec, WasiDir,
  dir::{OpenResult as WasiOpenResult, ReaddirCursor, ReaddirEntity},
  file::{FdFlags, FileType, Filestat, OFlags},
  sync::file::File,
};

// A helper function to generate a deterministic inode from a path.
// This ensures that readdir and get_path_filestat agree on the inode.
// We add a constant to avoid collisions with special inodes (e.g., 1 for the directory).
fn path_to_inode(path: &str) -> u64 {
  let mut hasher = DefaultHasher::new();
  path.hash(&mut hasher);
  // Start file inodes from a higher number to avoid collision with dir inode.
  hasher.finish().wrapping_add(100)
}

pub struct JudgeDir {
  // Use HashMaps to store an arbitrary number of files.
  // The key is the filename, and the value is the file handle.
  read_only_files: HashMap<String, cap_std::fs::File>,
  write_only_files: HashMap<String, cap_std::fs::File>,
}

#[wiggle::async_trait]
impl WasiDir for JudgeDir {
  // Standard trait method to allow downcasting.
  fn as_any(&self) -> &dyn Any {
    self
  }

  // The core method for opening files within this fake directory.
  async fn open_file(
    &self,
    _symlink_follow: bool, // Symlinks are not supported, so this is ignored.
    path: &str,
    oflags: OFlags,
    read: bool,
    write: bool,
    _fdflags: FdFlags, // FdFlags like NONBLOCK are not meaningfully supported here.
  ) -> Result<WasiOpenResult, Error> {
    // Directories are not supported inside this fake directory.
    if oflags.contains(OFlags::DIRECTORY) {
      return Err(Error::not_dir());
    }

    // Check if the requested path is in the read-only files map.
    if let Some(std_file) = self.read_only_files.get(path) {
      // The file is strictly read-only.
      // Disallow any write, create, or truncate flags.
      if write
        || oflags.contains(OFlags::CREATE)
        || oflags.contains(OFlags::TRUNCATE)
        || oflags.contains(OFlags::EXCLUSIVE)
      {
        return Err(Error::perm().context(format!("file '{}' is read-only", path)));
      }

      // Clone the file handle to create a new file descriptor.
      let cap_file = std_file
        .try_clone()
        .map_err(|e| Error::io().context(e.to_string()))?;
      // Wrap it in the standard WasiFile implementation.
      let wasi_file = File::from_cap_std(cap_file);
      Ok(WasiOpenResult::File(Box::new(wasi_file)))

    // Check if the requested path is in the write-only files map.
    } else if let Some(std_file) = self.write_only_files.get(path) {
      // The file is strictly write-only.
      if read {
        return Err(Error::perm().context(format!("file '{}' is write-only", path)));
      }

      // Clone the file handle to create a new file descriptor.
      let cap_file = std_file
        .try_clone()
        .map_err(|e| Error::io().context(e.to_string()))?;
      // Wrap it in the standard WasiFile implementation.
      let wasi_file = File::from_cap_std(cap_file);
      Ok(WasiOpenResult::File(Box::new(wasi_file)))
    } else {
      // Any other path does not exist in this fake directory.
      Err(Error::not_found())
    }
  }

  // Creating subdirectories is not supported.
  async fn create_dir(&self, _path: &str) -> Result<(), Error> {
    Err(Error::not_supported().context("create_dir is not supported"))
  }

  // Lists the contents of the fake directory.
  async fn readdir(
    &self,
    cursor: ReaddirCursor,
  ) -> Result<Box<dyn Iterator<Item = Result<ReaddirEntity, Error>> + Send>, Error> {
    let mut entries = Vec::new();
    const DIR_INODE: u64 = 1;

    // Add '.' (current directory)
    entries.push(Ok(ReaddirEntity {
      next: ReaddirCursor::from(1),
      filetype: FileType::Directory,
      inode: DIR_INODE,
      name: ".".to_string(),
    }));

    // Add '..' (parent directory)
    entries.push(Ok(ReaddirEntity {
      next: ReaddirCursor::from(2),
      filetype: FileType::Directory,
      inode: DIR_INODE, // In this model, parent is the same as current.
      name: "..".to_string(),
    }));

    // Combine all file names from both maps for listing.
    let all_files = self
      .read_only_files
      .keys()
      .chain(self.write_only_files.keys());

    for name in all_files {
      let next_cursor = ReaddirCursor::from(entries.len() as u64 + 1);
      entries.push(Ok(ReaddirEntity {
        next: next_cursor,
        filetype: FileType::RegularFile,
        inode: path_to_inode(name),
        name: name.clone(),
      }));
    }

    // The readdir operation is stateful via the cursor.
    // We skip the entries that have already been read.
    let iter = entries.into_iter().skip(u64::from(cursor) as usize);

    Ok(Box::new(iter))
  }

  // Symlinks are not supported.
  async fn symlink(&self, _src_path: &str, _dest_path: &str) -> Result<(), Error> {
    Err(Error::not_supported().context("symlink is not supported"))
  }

  // Removing directories is not supported.
  async fn remove_dir(&self, _path: &str) -> Result<(), Error> {
    Err(Error::not_supported().context("remove_dir is not supported"))
  }

  // Unlinking files is not supported.
  async fn unlink_file(&self, _path: &str) -> Result<(), Error> {
    Err(Error::not_supported().context("unlink_file is not supported"))
  }

  // Reading links is not supported as symlinks don't exist.
  async fn read_link(&self, _path: &str) -> Result<PathBuf, Error> {
    Err(Error::not_supported().context("read_link is not supported"))
  }

  // Get metadata for the directory itself.
  async fn get_filestat(&self) -> Result<Filestat, Error> {
    Ok(Filestat {
      device_id: 0,
      inode: 1, // A constant inode for the directory.
      filetype: FileType::Directory,
      nlink: 1,
      size: 0, // Directories have no size in this context.
      atim: None,
      mtim: None,
      ctim: None,
    })
  }

  // Get metadata for a path within the directory.
  async fn get_path_filestat(&self, path: &str, _follow_symlinks: bool) -> Result<Filestat, Error> {
    if path == "." || path == ".." {
      // For '.' or '..', return the directory's own stat.
      return self.get_filestat().await;
    }

    // Look for the file in either map.
    let file = self
      .read_only_files
      .get(path)
      .or_else(|| self.write_only_files.get(path))
      .ok_or_else(Error::not_found)?;

    // Get metadata from the underlying file handle.
    let meta = file
      .metadata()
      .map_err(|e| Error::io().context(e.to_string()))?;

    Ok(Filestat {
      device_id: 0,
      inode: path_to_inode(path), // Use the same inode generation logic as readdir.
      filetype: FileType::RegularFile,
      nlink: 1,
      size: meta.len(),
      atim: meta.accessed().ok().map(|t| t.into_std()),
      mtim: meta.modified().ok().map(|t| t.into_std()),
      ctim: meta.created().ok().map(|t| t.into_std()),
    })
  }

  // Renaming is not supported.
  async fn rename(
    &self,
    _src_path: &str,
    _dest_dir: &dyn WasiDir,
    _dest_path: &str,
  ) -> Result<(), Error> {
    Err(Error::not_supported().context("rename is not supported"))
  }

  // Hard links are not supported.
  async fn hard_link(
    &self,
    _src_path: &str,
    _target_dir: &dyn WasiDir,
    _target_path: &str,
  ) -> Result<(), Error> {
    Err(Error::not_supported().context("hard_link is not supported"))
  }

  // Setting file times is not supported.
  async fn set_times(
    &self,
    _path: &str,
    _atime: Option<SystemTimeSpec>,
    _mtime: Option<SystemTimeSpec>,
    _follow_symlinks: bool,
  ) -> Result<(), Error> {
    Err(Error::not_supported().context("set_times is not supported"))
  }
}

impl JudgeDir {
  /// Creates a new JudgeDir with specified lists of read-only and write-only files.
  ///
  /// This function will attempt to open (for read-only) or create (for write-only)
  /// all specified files. It returns an error if any file operation fails.
  pub fn new(read_only_paths: &[String], write_only_paths: &[String]) -> Result<Self> {
    let mut read_only_files = HashMap::new();
    for path in read_only_paths {
      let file = std::fs::File::open(path)
        .with_context(|| format!("Failed to open read-only file: {}", path))?;
      read_only_files.insert(path.clone(), cap_std::fs::File::from_std(file));
    }

    let mut write_only_files = HashMap::new();
    for path in write_only_paths {
      let file = std::fs::File::create(path)
        .with_context(|| format!("Failed to create write-only file: {}", path))?;
      write_only_files.insert(path.clone(), cap_std::fs::File::from_std(file));
    }

    Ok(JudgeDir {
      read_only_files,
      write_only_files,
    })
  }
}
