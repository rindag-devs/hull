use std::{
  collections::hash_map::DefaultHasher,
  fmt::Write as _,
  fs,
  hash::{Hash, Hasher},
  path::Path,
};

use anyhow::{Result, anyhow, bail};
use sha2::{Digest, Sha256};
use wasmtime::{Engine, Module};

/// Loads authoritative source Wasm, transparently reusing Hull's private native cache.
pub fn load_module(engine: &Engine, source: &[u8]) -> Result<Module> {
  if Engine::detect_precompiled(source).is_some() {
    bail!("authoritative module input must be source Wasm");
  }
  let Some(cache) = super::module_cache_directory() else {
    return compile_module(engine, source);
  };
  load_module_in_cache(engine, source, &cache)
}

fn compile_module(engine: &Engine, source: &[u8]) -> Result<Module> {
  Module::new(engine, source)
    .map_err(|error| anyhow!("failed to compile authoritative Wasm source: {error}"))
}

fn load_module_in_cache(engine: &Engine, source: &[u8], cache: &Path) -> Result<Module> {
  let path = cache.join(format!("{}.cwasm", cache_key(engine, source)));
  if let Ok(bytes) = fs::read(&path) {
    // SAFETY: This private cache contains only the direct output of `Module::serialize` below.
    // Reading into owned memory also prevents later file replacement from changing live code.
    if let Ok(module) = unsafe { Module::deserialize(engine, &bytes) } {
      return Ok(module);
    }
  }

  let module = compile_module(engine, source)?;
  let Ok(serialized) = module.serialize() else {
    return Ok(module);
  };
  if fs::create_dir_all(cache).is_err() {
    return Ok(module);
  }
  let Ok(mut temporary) = tempfile::NamedTempFile::new_in(cache) else {
    return Ok(module);
  };
  if std::io::Write::write_all(&mut temporary, &serialized).is_ok() {
    let _ = temporary.persist(path);
  }
  Ok(module)
}

fn cache_key(engine: &Engine, source: &[u8]) -> String {
  let mut compatibility = DefaultHasher::new();
  engine
    .precompile_compatibility_hash()
    .hash(&mut compatibility);
  let mut digest = Sha256::new();
  digest.update(compatibility.finish().to_le_bytes());
  digest.update(source);
  digest
    .finalize()
    .iter()
    .fold(String::with_capacity(64), |mut output, byte| {
      write!(output, "{byte:02x}").unwrap();
      output
    })
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::runner::engine_config;

  const EMPTY_WASM: &[u8] = b"\0asm\x01\0\0\0";

  #[test]
  fn source_loads() {
    let engine = Engine::new(&engine_config(1024).unwrap()).unwrap();
    load_module(&engine, EMPTY_WASM).unwrap();
  }

  #[test]
  fn native_artifact_is_rejected() {
    let engine = Engine::new(&engine_config(1024).unwrap()).unwrap();
    let native = engine.precompile_module(EMPTY_WASM).unwrap();
    assert!(load_module(&engine, &native).is_err());
  }

  #[test]
  fn cache_never_hides_invalid_source_without_cache() {
    let engine = Engine::new(&engine_config(1024).unwrap()).unwrap();
    assert!(load_module(&engine, b"invalid").is_err());
  }

  #[test]
  fn cached_module_is_shared_across_stack_limits() {
    let cache = tempfile::tempdir().unwrap();
    let small = Engine::new(&engine_config(64 * 1024).unwrap()).unwrap();
    let large = Engine::new(&engine_config(16 * 1024 * 1024).unwrap()).unwrap();

    load_module_in_cache(&small, EMPTY_WASM, cache.path()).unwrap();
    let path = cache
      .path()
      .join(format!("{}.cwasm", cache_key(&small, EMPTY_WASM)));
    let cached = std::fs::read(&path).unwrap();
    unsafe { Module::deserialize(&large, &cached) }.unwrap();
    assert_eq!(cache_key(&small, EMPTY_WASM), cache_key(&large, EMPTY_WASM));
  }

  #[test]
  fn invalid_cache_falls_back_to_source() {
    let cache = tempfile::tempdir().unwrap();
    let engine = Engine::new(&engine_config(1024).unwrap()).unwrap();
    let path = cache
      .path()
      .join(format!("{}.cwasm", cache_key(&engine, EMPTY_WASM)));
    std::fs::write(&path, b"invalid cache entry").unwrap();

    load_module_in_cache(&engine, EMPTY_WASM, cache.path()).unwrap();
    let repaired = std::fs::read(path).unwrap();
    unsafe { Module::deserialize(&engine, repaired) }.unwrap();
  }
}
