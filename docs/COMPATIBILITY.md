# Compatibility

Version 0.1.0 uses the documented API with native macOS ARM64 acceptance.
Linux remains experimental until a native runner executes the current source.

## Supported API

The exports, signatures, error types, public fields and relevant decorators are
recorded in `tests/api/usd_mojo.json`. `tools/check_api.py` compares their tokenized
source declarations. It detects source API drift; semantic behavior is checked
separately against OpenUSD. Recording a changed baseline requires a compatibility
review and is never part of CI.

The contract covers the operations in [API.md](API.md): composed stage access and
editing, supported typed values and arrays, geometry, scene information, visual
and physics schema data. Float16/32 values preserve their USD precision even when
the generic `Value.numbers` channel exposes them as Float64. Int64 and UInt64 do
not pass through floating storage. Matrices and time codes retain USD conventions.

`Stage` is move-only. Owned returned data and `MeshSnapshot` outlive the stage. Immutable mesh views
borrow their snapshot owner and must not outlive or be used after moving it. Independent stages
can be used independently; concurrent access to one stage is unsupported. Raw
bridge handles and underscore-prefixed fields are implementation details.
`save()` persists root edits; `export()` flattens composition. Neither operation
promises rollback after an SDK or filesystem failure.

Public throwing functions raise `UsdError`, with a `kind` and diagnostic `message`:

| Kind | Code | Meaning |
| --- | --- | --- |
| invalid_argument | 1 | Invalid caller path, name, time, extent or operation argument |
| not_found | 2 | Requested prim, property or selected metadata/variant entry is absent |
| type_mismatch | 3 | Requested reader/schema does not match the available value |
| unsupported | 4 | Value or representation is outside the supported subset |
| invalid_data | 5 | Invalid mesh topology, finite geometry or local crate bounds |
| io | 6 | Stage open/create/save/export or a checked local read failed |
| sdk | 7 | OpenUSD reported a diagnostic or an otherwise unclassified SDK exception |
| incompatible | 8 | The loaded bridge does not match this consumer's ABI |
| internal | 9 | A bridge snapshot invariant or unknown internal operation failed |
| resource | 10 | The native boundary caught an allocation failure |

The categories and codes are stable; diagnostic prose is not. An SDK diagnostic
may occur before a more specific condition can be established. Resource errors
do not promise recovery from every runtime allocation failure. Composition
warnings may leave a stage usable; `composition_errors()` exposes unresolved arcs.

The native bridge uses ABI 2. Compile consumers against the matching bridge.

## Compatibility policy

Patch versions correct documented behavior without changing public signatures,
ownership, error categories or accepted inputs. Minor versions can add compatible
operations. Within 0.1.x the reviewed behavior remains compatible. During 0.x development,
breaking changes require a new minor version and migration instructions. Precompiled `.mojoc` files are tied to the exact compiler. Another compiler needs
a new package and its own acceptance run, even when source remains compatible.

The pinned targets are OpenUSD 26.08, Mojo 1.1.0 and the explicitly listed 1.2
nightly; macOS ARM64 and Linux x86-64. SDK dependencies stay external. Package
integrity and relocation checks do not establish support for another SDK build.

## Validation

[Recorded checks](VALIDATION.md) cover SDK semantics, ownership, malformed input,
installed consumers and geometry applications. Native Linux remains pending.
