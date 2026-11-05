# Validation

The [qualification record](https://github.com/henlamp/usd-mojo/blob/development/docs/evidence/020-candidate.json)
separates `current` from `previous_full_qualification`. The current source passed
macOS acceptance and Metal checks with both pinned compilers. Linux/NVIDIA and
fresh Conda qualification are pending. Historical results retain their original
source hashes. Shared results list every configuration that produced them;
compiler receipts remain separate.

Run CPU acceptance with both pinned compilers and the external corpus:

```sh
pixi install --locked
pixi run --locked python tools/corpus.py .local/corpus --fetch
pixi run --locked -e default acceptance --execution-kind native --corpus .local/corpus
pixi run --locked -e nightly acceptance --execution-kind native --corpus .local/corpus
pixi run --locked python tests/release_cache.py
pixi run --locked python tests/update.py
```

Acceptance checks the 0.1 API, registered value/schema catalogs, typed roundtrips,
SDK and analytic geometry/animation comparisons, composition/edit targets, Ts
splines, native arrays, malformed inputs, ownership/compile-negative tests,
installed consumers, benchmarks and relocation. The release gate checks report,
artifact and log hashes for all four native platform/compiler combinations.
Emulation does not satisfy native qualification.
Catalog checks use non-default values, integer/float bounds and interpolation,
then reopen USDA/USDC/USDZ. Native checks cover mixed storage channels, narrowing
ranges, incomplete elements and quaternion component order.
The combined scene test nests time-offset references,
LOD variants, payloads, inherits and overrides with animated points and indexed
face-varying UVs/normals; weaker files must remain unchanged. Skinning checks
cover rest/joint poses, sparse/animated shapes, missing/blocked weights and invalid
arrays. Absent weights are compared with an equivalent unanimated SDK rig.

Installed consumers use pinned [YAM robot](https://github.com/ARISE-Initiative/yamlab/tree/ec0455d2b4ce35f21fc126418ea5e74ac567133d)
and [RYStorm/Kenney vehicle](https://github.com/usd-wg/assets/tree/091bb5c6f8eb665ad4cf9d6c10025cecc07eda88/full_assets/Vehicles) assets.
The fetcher verifies hashes and retains notices; assets stay outside packages.
Tests author stronger overlays and compare USDA/USDC/USDZ output with the SDK.
YAM retains 36 known SDK findings: five inertia errors, 30 missing shader-registry
types and missing `OmniPBR.mdl`. USDZ rejects unresolved dependencies; flattening
rejects unregistered metadata, while layer export preserves those opinions.

Workloads measure forty open/edit/snapshot/save/close cycles after ten warmups;
`tools/workloads_check.py --corpus .local/corpus --rounds 1000` extends the run.
The [lifetime profile](https://github.com/henlamp/usd-mojo/blob/development/docs/evidence/020-memory-profile.json)
compares six SDK/C ABI paths over 2,000 cycles. These are bounded measurements.
Fresh Pixi checks verify the installed artifact hash. Local dependency caches are
shared; remote-channel retries isolate caches and invalidate stale success receipts.

Optional checks, run after `pixi run --locked python`:

| Script | Coverage |
| --- | --- |
| `tools/imaging_check.py` | Cube silhouette, color/transparency and installed imaging archive. |
| `tools/render_session_check.py` | Camera/time/scene/vertex updates, clipping removal, caller-buffer reuse, failures and retained owners. |
| `tools/materialx_check.py --oracle-python PATH` | GLSL/MSL parity with an independent MaterialX 1.39.5 interpreter; actual Metal gradient/edit pixels and installed archive. |
| `tools/hydra_materialx_check.py` | MaterialX file-format import, USD reference/binding, Storm colors, material-interface edits and installed archive. |
| `tools/surface_pipeline_check.py --oracle-python PATH` | Lit standard surface, color/roughness edits, opacity, image/UV edits, missing-texture rejection, independent GLSL/MSL and installed archive. |

MaterialX checks require `USD_MOJO_MATERIALX_PREFIX`; the Hydra MaterialX check
also requires the separate `USD_MOJO_SDK_PREFIX`. See [SDK setup](API.md#optional-materialx).
[Rendering evidence](https://github.com/henlamp/usd-mojo/blob/development/docs/evidence/020-render-session.json)
and [MaterialX evidence](https://github.com/henlamp/usd-mojo/blob/development/docs/evidence/020-materialx.json)
bind compiler runs to logs, pixels and samples. The pinned unlit-uniform patch
and optional SDK identity are recorded; the unpatched failure remains in diagnostics.

Stored Apple/Metal and NVIDIA/WSLg records cover both compilers and installed
archives at their recorded sources. Linux uses `USD_MOJO_TEST_GL_CONTEXT=1`; on WSLg also set
`GALLIUM_DRIVER=d3d12` and `USD_MOJO_EXPECT_GPU=NVIDIA`. Reports record the active
Hgi API/plugin and compare source with installed backends. Native boundary checks
run outside the Python reference SDK process. Direct MaterialX texture-space
readback requires Metal.

Qualification covers the recorded SDKs, drivers, assets and bounded runs. It does
not establish every BSDF, production workload or unbounded memory stability.
The glibc symbol-floor check is separate from execution on that runtime.
