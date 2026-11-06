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

## Development 0.2 additions

| Area | API and semantics |
| --- | --- |
| Layers | `Layer(filename, create=True)`, `Layer(stage, session=True)`, `Layer.anonymous()`, content/export/save, sublayer paths and time offsets. Layers share SDK identity. `replace_content` parses separately before replacing content. |
| Editing | `EditTarget(stage, layer, reference_prim=...)` retains the SDK mapping; applying it to another stage fails. Ambiguous reference mappings are rejected. `NamespaceEditor` preflights prim/property edits and accepts explicitly registered dependent stages. Only composed, loaded dependencies are visible. |
| Metadata | `Metadata` owns dictionaries, exact base values and opaque SDK values. Child snapshots are independent. Path/token/string list operations and references/payloads retain explicit/prepend/append/delete/add/order items and layer offsets. `set_metadata` authors composed-object metadata; `set_layer_field` edits raw Sdf opinions. Unsupported base conversions fail without discarding the opaque value. |
| Composition | Masked stage construction, population-mask expansion, `LoadRule`, layer muting, inherits/specializes and `composition_arcs`. `ResolverContext` retains default search paths or delegates context-string parsing to the active SDK resolver. `register_plugins` uses the SDK plugin registry. |
| Schemas | `SchemaSnapshot(stage, path, time)` owns all resolved attributes, missing/blocked-value names, forwarded relationship targets and authored connections. `schema_properties` inspects registered definitions. Applies to geometry, lights, render settings/products/vars, all standard physics schemas and installed plugin schemas. Custom value types outside `Value` raise `unsupported` on conversion. |
| Geometry | `visibility`, `purpose`, aligned `world_bounds`, flattened `inherited_primvar`. `instance_transforms` retains every PointInstancer slot; `instance_mask` supplies 0/1 visibility in the same order. Prototype transforms are optional. Curves, NURBS, subsets and subdivision properties are data access, not tessellation. |
| Shading | `bound_material` supports material purposes and SDK collection/inherited bindings. `shader_graph` captures reachable property connections for a render context, retaining cycles and unresolved sources. Node values come from schema snapshots; shaders are not evaluated by the core. |
| Animation | Joint order, skeleton-space transforms, skinning transforms and `skinned_points` use UsdSkel. Blend shapes, inbetweens and joint-order mapping precede skinning. Clip dictionaries preserve explicit and template definitions; value/time mapping is evaluated by the SDK. |
| Assets | `dependencies` distinguishes layers, assets and unresolved paths in the stage's resolver context. `export_usdz` uses UsdUtils, refuses unsaved edits, unresolved dependencies and existing destinations, and publishes the completed package atomically. Generated clip manifests are SDK caches. |
| Runtime handoff | `SceneSnapshot` freezes composed opinions, including the session and selected working set. `paths`, `types` and `prototypes` align with contiguous borrowed Float64 world matrices. `value` reads the frozen description; external asset bytes are not copied. `poll_changes` consumes bounded SDK notice paths; `all_dirty` requires a full refresh. GPU transfers belong to runtime adapters. |

`skinned_points` treats missing or blocked weights at the requested time as neutral.
Malformed authored arrays raise `invalid_data`.

The C ABI still delegates composition and schema evaluation to OpenUSD. These
additions do not claim feature parity with every SDK class or plugin.

Keep stages open across runtime updates and reuse a frozen snapshot until its
description changes. Capturing a new `SceneSnapshot` performs CPU-side SDK
flattening; it is not an incremental update or an allocation-free operation.

### Authoring and numeric streaming

`override_prim` and `create_class_prim` author `over`/`class` specs in the selected
edit target. `create_attribute`, value blocks, clearing values/samples, property
opinion removal and connection/relationship setters preserve weaker opinions
according to USD composition. Clearing an opinion and authoring an explicit empty
list have different effects. High/low representations are authored as variants
and payloads; the library does not generate simplified meshes.

`set_reference_opinions`, `set_payload_opinions`, `set_inherit_opinions` and
`set_specialize_opinions` author explicit/prepend/append/delete/add/order list
opinions in a `Layer`, creating local overs as needed. They replace the selected
field's list opinion. `clear_arc_opinions` reveals weaker opinions. Layer variant
removal edits local definitions; authored selections remain separate opinions.

`set_values(stage, List[AttributeEdit])` preflights paths, types and mappings before
writing. Root/identity-time batches use Sdf change blocks without calling Usd
inside the deferred-composition region. Mapped timelines and timecode values use
Usd authoring to preserve time conversions and can emit multiple notices. Batches
are not rollback transactions for runtime allocation or SDK failures.
Relationship collisions in composed properties or hidden target-layer specs fail
before any writes.

`ArraySnapshot(stage, path, name, time).view[dtype]()` lends immutable packed
numeric components directly from owned SDK array storage. Integers retain their
width; vectors/matrices retain their component layout. Unsupported layouts fail
explicitly. Boolean views use UInt8 components containing 0/1. `set_array` copies
a compatible host span into SDK-owned storage once, without Float64 promotion.
Caller storage can be reused after return. SDK decoding,
small-array materialization and GPU uploads can still allocate or copy.

`Layer.export("scene.usdc")` preserves layer structure; `Stage.export` flattens it.
USDZ is read as a package. Editing through a stronger saved overlay and repackaging
to a new USDZ preserves the original archive; in-place ZIP editing is not exposed.
Packaging retains empty asset-array slots, including metadata and time samples.

### Catalogs and splines

`value_types()` lists the linked SDK's registered names, roles and array/view
capabilities. `schema_types()` lists registered schemas and their property names.
The generated value dispatch is checked by `tools/generate.py --check`. Opaque
and group markers have no generic component representation; the catalog records
this explicitly. Path expressions retain their SDK expression text, including
relative paths and expression references.

`Spline(type_name="double", curve="bezier")` owns a Ts spline.
`Spline(stage, path, attribute)` captures a resolved spline; `Spline(other)`
makes an independent copy. Knots support held/linear/curve/value-block interpolation,
dual values, tangents and tangent algorithms. Evaluation returns Float64, including
for Float16/32 knot storage. Extrapolation, loop settings and knot metadata are
retained. `author(stage, path, name)` uses the current mapped edit target and USD
unit/time conventions. USDA/USDC output can require a newer crate format for
splines and timecode-valued splines; the SDK chooses that format.

### Validation

`validate_stage` returns owned, sorted findings with identifiers, severity and
sites, plus selected rules, population mask, unloaded payloads and muted layers.
An empty rule list selects available SDK validators and local mesh/mass checks.
The local rules check mesh topology/finite points and MassAPI numeric validity,
retaining zero-derived values and USD's derived-center sentinel. They do not
certify solver behavior or every physical constraint.

`time=None` requests all authored samples; an explicit `TimeCode` narrows the check.
`max_issues` limits returned detail, while total/error counts remain complete.
`is_valid()` concerns those rules on the composed working set; it does not inspect
inactive, masked, unloaded or unselected contents. Validators do not fix/save data.
The SDK can omit an invalid site's raw path; such a site retains an empty path.
Use `examples/validate_scene.mojo` for a failing exit status when errors are found.

## Optional Hydra imaging

`from usd_mojo.imaging import RenderSession, RenderImage, renderer_plugins` uses
an opt-in native library, built with `USD_MOJO_IMAGING=ON`.

`RenderSession(stage, width, height, renderer="")` retains the stage, Hgi and Hydra
engine. `render(camera, time, max_iterations=8, lighting=True)` submits a frame;
`converged` reports the bounded render result. `readback()` creates an independent
`RenderImage`; `read_into(MutSpan[Float32])` copies into exact-sized caller storage
without retaining its pointer. A failed render invalidates readback until the next
successful render. Session size is fixed; viewport fitting preserves vertical
aperture and conforms horizontal framing to the output aspect ratio. Use and
destroy sessions on the main thread; concurrent stage edits or rendering are unsupported.
Additional camera-space clipping planes follow the selected camera and time.
SDK rendering warnings raise an error, including shader fallback and missing textures.

```mojo
var session = RenderSession(stage, 640, 480)
session.render("/Camera", TimeCode.at(1))
print(session.backend(), session.renderer())
var image = session.readback()
var pixels = image.pixels()
```

`RenderImage(stage, camera, width, height, ...)` remains the one-shot convenience
API. Images own linear Float32 RGBA and lend `ImmSpan` views tied to their lifetime.
Later renders do not mutate earlier images. Readback maps/synchronizes the renderer
buffer and copies/converts its data; borrowing an image adds no further copy.
Channels and row order are retained without display color conversion. There is no
window presentation or shared GPU-texture handle. The default core package does
not link Hydra, OpenGL or a platform GPU backend.
Linux applications must supply a current OpenGL 4.5+ context. For local tests,
`USD_MOJO_TEST_GL_CONTEXT=1` builds and preloads the registered SDK shared context.
The helper is not installed or required by the core library.
On the qualified WSLg/Mesa 25 stack, `GALLIUM_DRIVER=d3d12` selects hardware
rendering. The embedding application supplies a registered shared SDK context;
the exact qualification setup is in [Linux evidence](https://github.com/henlamp/usd-mojo/blob/development/docs/evidence/020-linux.json).

Run `pixi run python tools/imaging_check.py` for the one-shot path and
`pixi run python tools/render_session_check.py` for sequences and buffer reuse. To build
an archive with the renderer, run `pixi run python tools/package.py --imaging` and
compile its consumer with `compile.py --imaging`. Plugin availability depends on
the installed SDK; platform results apply to the recorded driver and SDK setup.

See [compatibility](COMPATIBILITY.md) for error categories,
versioning and acceptance requirements.

## Optional MaterialX

`usd_mojo.materialx` is optional. `MaterialXDocument(filename, library_path)` uses
the native MaterialX SDK for XML, standard/custom libraries, validation, typed
input edits and saving. `shader(element, target="msl")` generates MSL; use
`target="glsl"` for GLSL. Shaders own their sources independently of the document.
Texture-space Metal readbacks own Float32 pixels and lend lifetime-bound spans. These are value-output renders;
surface materials are evaluated by the separate MaterialX-enabled Hydra path.
Hydra surface shading is qualified on Metal and NVIDIA/WSLg; see the
[MaterialX evidence](https://github.com/henlamp/usd-mojo/blob/development/docs/evidence/020-materialx.json) for SDK configuration and cases.
The MaterialX platform helper uses a hidden window; rendering requires the main
thread. File access and XML version upgrades follow MaterialX, without an asset
sandbox. The original file changes only when explicitly saved.

Use `python tools/bootstrap_optional.py` inside Pixi to build the checksum-pinned
MaterialX SDK; `--openusd` additionally builds OpenUSD with MaterialX enabled.
Set `USD_MOJO_MATERIALX_PREFIX` for MaterialX archives and `USD_MOJO_SDK_PREFIX`
when selecting that separate OpenUSD build. The core Conda package remains linked
to its pinned external SDK, without an imaging or MaterialX renderer dependency.

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
