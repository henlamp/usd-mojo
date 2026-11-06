# Changelog

## 0.2.0 — 2026-11-06

- Default compiler and compiled packages use stable Mojo 1.2.0.
- Linux x86-64 packages alongside macOS ARM64; the reviewed 0.1 source API remains.
- Layer/session editing, mapped targets, namespace edits, metadata/list operations,
  composition arcs, variants, masks, load rules and resolver contexts.
- Batched attribute edits, typed numeric array views/writes, owned scene/schema
  snapshots and bounded change notices.
- Registered value/schema catalogs, PathExpression values, splines, skeletons,
  skinning, blend shapes, clips and shader graphs. Missing or blocked weights
  remain neutral; malformed weight arrays are rejected.
- Atomic USDZ packaging preserves empty asset-array slots. Flattening rejects
  metadata that would be discarded; layer export retains the authored opinions.
- Optional persistent Hydra rendering and MaterialX documents, input edits,
  GLSL/MSL generation and Metal texture-space readback. Render sessions expose
  their actual Hgi API and plugin; rendering warnings fail explicitly.
- Shared native error categories and checked MaterialX file writes.

[Validation](docs/VALIDATION.md) records native checks, packages and limits.

## 0.1.0

Initial release: OpenUSD scene access, typed values and owned/borrowed mesh data.
