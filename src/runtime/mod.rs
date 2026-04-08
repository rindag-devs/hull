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

/// Runtime analysis and judger execution primitives.
pub mod analysis;
/// Artifact realization, store import, and native-module cache helpers.
pub mod artifact;
/// High-level problem and contest build entry points.
pub mod build;
/// Exported bundle judge helpers shared by judge adapters.
pub mod bundle_judge;
/// Runtime metadata loading from flakes and exported bundles.
pub mod metadata;
/// WASM sandbox execution.
pub mod sandbox;
/// Runtime data models shared by analysis and packaging.
pub mod types;
/// Ephemeral filesystem workspace management for runtime jobs.
pub mod workspace;
