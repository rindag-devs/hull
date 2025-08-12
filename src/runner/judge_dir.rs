use std::{any::Any, path::PathBuf};

use anyhow::Result;
use wasi_common::{
  Error, ErrorExt, SystemTimeSpec, WasiDir,
  dir::{OpenResult as WasiOpenResult, ReaddirCursor, ReaddirEntity},
  file::{FdFlags, FileType, Filestat, OFlags},
  sync::file::File,
};

pub struct JudgeDir {
  pub input_file_name: Option<String>,
  pub output_file_name: Option<String>,
  pub input_file: Option<cap_std::fs::File>,
  pub output_file: Option<cap_std::fs::File>,
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

    // Check if the requested path is the designated input file.
    if self.input_file_name.as_deref() == Some(path) {
      // Ensure the input file exists.
      let std_file = self.input_file.as_ref().ok_or_else(Error::not_found)?;

      // The input file is strictly read-only.
      // Disallow any write, create, or truncate flags.
      if write
        || oflags.contains(OFlags::CREATE)
        || oflags.contains(OFlags::TRUNCATE)
        || oflags.contains(OFlags::EXCLUSIVE)
      {
        return Err(Error::perm().context("input file is read-only"));
      }

      // Clone the file handle to create a new file descriptor.
      let cap_file = std_file
        .try_clone()
        .map_err(|e| Error::io().context(e.to_string()))?;
      // Wrap it in the standard WasiFile implementation.
      let wasi_file = File::from_cap_std(cap_file);
      Ok(WasiOpenResult::File(Box::new(wasi_file)))

    // Check if the requested path is the designated output file.
    } else if self.output_file_name.as_deref() == Some(path) {
      // Ensure the output file exists.
      let std_file = self.output_file.as_ref().ok_or_else(Error::not_found)?;

      // The output file is strictly write-only.
      if read {
        return Err(Error::perm().context("output file is write-only"));
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
    Err(Error::not_supported().context("create_dir is not supported in LemonFakeDir"))
  }

  // Lists the contents of the fake directory.
  async fn readdir(
    &self,
    cursor: ReaddirCursor,
  ) -> Result<Box<dyn Iterator<Item = Result<ReaddirEntity, Error>> + Send>, Error> {
    let mut entries = Vec::new();

    // All directories must contain '.' and '..'.
    // We use constant inode numbers for simplicity.
    const DIR_INODE: u64 = 1;
    const INPUT_FILE_INODE: u64 = 2;
    const OUTPUT_FILE_INODE: u64 = 3;

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

    // Add the input file if it exists.
    if let Some(name) = &self.input_file_name {
      entries.push(Ok(ReaddirEntity {
        next: ReaddirCursor::from(entries.len() as u64 + 1),
        filetype: FileType::RegularFile,
        inode: INPUT_FILE_INODE,
        name: name.clone(),
      }));
    }

    // Add the output file if it exists.
    if let Some(name) = &self.output_file_name {
      entries.push(Ok(ReaddirEntity {
        next: ReaddirCursor::from(entries.len() as u64 + 1),
        filetype: FileType::RegularFile,
        inode: OUTPUT_FILE_INODE,
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
    Err(Error::not_supported().context("symlink is not supported in LemonFakeDir"))
  }

  // Removing directories is not supported.
  async fn remove_dir(&self, _path: &str) -> Result<(), Error> {
    Err(Error::not_supported().context("remove_dir is not supported in LemonFakeDir"))
  }

  // Unlinking files is not supported.
  async fn unlink_file(&self, _path: &str) -> Result<(), Error> {
    Err(Error::not_supported().context("unlink_file is not supported in LemonFakeDir"))
  }

  // Reading links is not supported as symlinks don't exist.
  async fn read_link(&self, _path: &str) -> Result<PathBuf, Error> {
    Err(Error::not_supported().context("read_link is not supported in LemonFakeDir"))
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
    if path == "." {
      // For '.', return the directory's own stat.
      self.get_filestat().await
    } else if self.input_file_name.as_deref() == Some(path) {
      // For the input file, get metadata from the underlying file handle.
      let file = self.input_file.as_ref().ok_or(Error::not_found())?;
      let meta = file
        .metadata()
        .map_err(|e| Error::io().context(e.to_string()))?;
      Ok(Filestat {
        device_id: 0,
        inode: 2, // Constant inode for the input file.
        filetype: FileType::RegularFile,
        nlink: 1,
        size: meta.len(),
        atim: meta.accessed().ok().map(|x| x.into_std()),
        mtim: meta.modified().ok().map(|x| x.into_std()),
        ctim: meta.created().ok().map(|x| x.into_std()),
      })
    } else if self.output_file_name.as_deref() == Some(path) {
      // For the output file, do the same.
      let file = self.output_file.as_ref().ok_or(Error::not_found())?;
      let meta = file
        .metadata()
        .map_err(|e| Error::io().context(e.to_string()))?;
      Ok(Filestat {
        device_id: 0,
        inode: 3, // Constant inode for the output file.
        filetype: FileType::RegularFile,
        nlink: 1,
        size: meta.len(),
        atim: meta.accessed().ok().map(|x| x.into_std()),
        mtim: meta.modified().ok().map(|x| x.into_std()),
        ctim: meta.created().ok().map(|x| x.into_std()),
      })
    } else {
      // Any other path does not exist.
      Err(Error::not_found())
    }
  }

  // Renaming is not supported.
  async fn rename(
    &self,
    _src_path: &str,
    _dest_dir: &dyn WasiDir,
    _dest_path: &str,
  ) -> Result<(), Error> {
    Err(Error::not_supported().context("rename is not supported in LemonFakeDir"))
  }

  // Hard links are not supported.
  async fn hard_link(
    &self,
    _src_path: &str,
    _target_dir: &dyn WasiDir,
    _target_path: &str,
  ) -> Result<(), Error> {
    Err(Error::not_supported().context("hard_link is not supported in LemonFakeDir"))
  }

  // Setting file times is not supported.
  async fn set_times(
    &self,
    _path: &str,
    _atime: Option<SystemTimeSpec>,
    _mtime: Option<SystemTimeSpec>,
    _follow_symlinks: bool,
  ) -> Result<(), Error> {
    Err(Error::not_supported().context("set_times is not supported in LemonFakeDir"))
  }
}

impl JudgeDir {
  pub fn new(input_file_name: Option<String>, output_file_name: Option<String>) -> Self {
    let input_file = input_file_name.as_ref().and_then(|x| {
      Some(cap_std::fs::File::from_std(
        std::fs::File::open(&x).unwrap(),
      ))
    });
    let output_file = output_file_name.as_ref().and_then(|x| {
      Some(cap_std::fs::File::from_std(
        std::fs::File::create(x).unwrap(),
      ))
    });

    JudgeDir {
      input_file_name,
      output_file_name,
      input_file,
      output_file,
    }
  }
}
