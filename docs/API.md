# API reference

`Stage` is a move-only SDK owner; public throwing operations raise `UsdError`.
Returned lists, values and information snapshots own their storage and outlive the stage.
No stage may be accessed concurrently, including editing while taking snapshots.
Stages can share SDK layers: do not edit a shared layer concurrently with readers
on another stage. Raw bridge handles are private implementation details,
not a public API or a validation boundary for arbitrary
pointers. OpenUSD's installed resolver and plugins control file access.

| Access | Public methods |
| --- | --- |
| Lifecycle | `Stage(filename, create=False, load_payloads=True)`, `save`, `export` |
| Traversal | `prim_paths`, `instance_paths`, `all_prim_paths`, `prototype_paths`, `prim_info`, `prim_type` |
| Composition | `layer_identifiers`, `composition_errors`, `add_reference`, `add_sublayer`, `variant_sets`, `variant_names`, `variant_selection`, `select_variant`, `edit_variant`, `edit_root` |
| Payloads | `loadable_paths`, `loaded_paths`, `set_payload_loaded`, `add_payload`, `set_instanceable` |
| Values | `attribute_names`, `attribute_type`, `has_attribute`, `has_authored_value`, `read_value`, `set_value`, typed readers/writers |
| Assets | `asset_path(path, name, time=.default, index=0)` returns authored, evaluated, resolved paths |
| Time | `stage_info`, `set_time_range`, `time_samples`, `TimeCode.default`, `TimeCode.at(value)` |
| Metadata | `metadata_names`, `metadata_dictionary_keys`, `read_metadata` |
| Connections | `connections`, relationship names/targets and authoring |
| Geometry | `mesh`, `world_transform`, `transform`, `read_primvar`, `read_normals`, `read_camera`, `material_path` |
| Schemas | `applied_schemas`, `has_schema`, `closest_schema`, `apply_schema`, USD physics helpers |

`prim_paths` uses default SDK traversal without instance proxies; `instance_paths`
expands proxies under that predicate. `all_prim_paths` uses SDK `TraverseAll`,
including inactive, abstract and undefined prims. These are composed prims, not
raw layer specs. Prototype paths and anonymous layer identifiers are transient
SDK identities. An unloaded payload can omit descendants and affect traversal.

`asset_path` resolves in the composed attribute's layer context. Empty evaluated
or resolved strings are preserved: they do not mean the authored string was empty.
Unresolved composition arcs are available through `composition_errors`; resolver
warnings do not necessarily make stage opening fail.

Metadata uses an empty path for stage metadata and an empty attribute for prim
metadata. `dictionary="nested:key"` follows SDK dictionary-key semantics.
`read_metadata` returns a supported base-type leaf; whole dictionaries and
list-op/path metadata outside that value model raise explicit errors. Enumerate
keys, then read leaves. This is intentionally an explicit subset of SDK metadata.

`read_primvar` retains values, indices, interpolation, element size and the
unauthored value index; it does not flatten or apply inheritance. SDK interpolation
fallbacks are respected. Mesh snapshots validate polygon topology and finite
points. They do not evaluate subdivision, triangulate, convert units, or create
renderer/solver buffers. Applications can access additional USD properties via
`read_value`, including orientation and subdivision metadata authored as attributes.

Floats can retain NaN/Inf in general values; mesh points and time codes reject
non-finite inputs. Signed/unsigned 64-bit integers never pass through floating
storage. UTF8 text containing embedded NUL raises an error rather than truncating.
Matrices use USD row-vector conventions, with translation at offsets 12–14.

`save` persists the root layer; `save_layers` uses the SDK's contributing-layer
save operation, with session layers explicitly selected. `export` flattens the
composed stage. Physics execution and subdivision evaluation are application concerns.
Flattened exports and frozen snapshots reject unregistered metadata that the SDK
would discard. Register its schema plugin before opening, or use `Layer.export`
to retain the original opinions. A population mask may exclude unrelated objects.

### Authoring and numeric streaming

`ArraySnapshot(stage, path, name, time).view[dtype]()` lends immutable packed
numeric components directly from owned SDK array storage. Integers retain their
width; vectors/matrices retain their component layout. Unsupported layouts fail
explicitly. Boolean views use UInt8 components containing 0/1. `set_array` copies
a compatible host span into SDK-owned storage once, without Float64 promotion.
Caller storage can be reused after return. SDK decoding,
small-array materialization and GPU uploads can still allocate or copy.

## Native mesh snapshots

`Stage.mesh_snapshot(path, time)` or `MeshSnapshot(stage, path, time)` captures
validated Float32 xyz points and Int32 polygon topology. It owns SDK array
references independently of the stage; subsequent stage edits do not change
the captured arrays. It is move-only and is not shared concurrently.

`points()`, `face_vertex_counts()` and `face_vertex_indices()` return immutable,
contiguous `ImmSpan` values with compiler-tracked snapshot origins. They do not
allocate or copy element storage. Empty meshes retain zero-length views.
Closing or moving the owner while using its old views is rejected by the compiler.

`materialize()` returns independent mutable `MeshData`. `copy_into(points,
counts, indices)` writes to exact-sized `MutSpan` buffers. Length, address extent,
destination overlap and overlap with snapshot storage are checked before writes,
including for foreign pointers. As with any unsafe span construction, the caller
must provide valid memory for its declared element type and extent.

Mesh points remain in local coordinates and stage units; these APIs do not change
precision, evaluate subdivision or transfer storage to a GPU. Stage opening,
snapshot validation and SDK array ownership still use OpenUSD. Native Mojo views
and caller buffers avoid the extra owned-output copy where a consumer permits it.

## File access

Local USDC roots receive bounded bootstrap/section-directory checks before SDK
opening. This avoids malformed directory counts reaching SDK allocation. It
does not validate compressed payloads, referenced files or virtual resolver
assets, and it is not a sandbox or a complete untrusted-file validator.

## Combining libraries

The archive compiler accepts repeated `-I DIRECTORY` arguments for precompiled
dependencies built with the same compiler. Pixi packages in `lib/mojo` are found
automatically. `examples/tensor_cache.mojo` combines USD mesh views, Axisweave
coordinate layouts and FileLock atomic writes; `check-integration` compares its
output with independently authored SDK geometry.
