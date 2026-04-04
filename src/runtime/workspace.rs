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

use std::fs;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;

use anyhow::{Context, Result};

#[derive(Debug)]
pub struct RuntimeWorkspace {
  pub root: PathBuf,
}

impl Drop for RuntimeWorkspace {
  fn drop(&mut self) {
    let _ = fs::remove_dir_all(&self.root);
  }
}

impl RuntimeWorkspace {
  pub fn new(root: impl Into<PathBuf>) -> Result<Self> {
    let root = root.into();
    fs::create_dir_all(&root)
      .with_context(|| format!("Failed to create runtime workspace {}", root.display()))?;
    Ok(Self { root })
  }

  pub fn case_dir(&self, group: &str, name: &str) -> Result<PathBuf> {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    name.hash(&mut hasher);
    let digest = hasher.finish();
    let safe_name: String = name
      .chars()
      .map(|ch| match ch {
        'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '.' => ch,
        _ => '_',
      })
      .collect();
    let path = self
      .root
      .join(group)
      .join(format!("{safe_name}-{digest:x}"));
    fs::create_dir_all(&path)
      .with_context(|| format!("Failed to create workspace directory {}", path.display()))?;
    Ok(path)
  }

  pub fn run_dir(&self, group: &str, name: &str) -> Result<PathBuf> {
    let path = self.case_dir(group, name)?;
    let run_dir = path.join("work");
    if run_dir.exists() {
      fs::remove_dir_all(&run_dir)
        .with_context(|| format!("Failed to reset run directory {}", run_dir.display()))?;
    }
    fs::create_dir_all(&run_dir)
      .with_context(|| format!("Failed to create run directory {}", run_dir.display()))?;
    Ok(run_dir)
  }
}
