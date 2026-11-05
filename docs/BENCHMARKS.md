# Measurements

Run inside the pinned Pixi environment. Timings use warm filesystem/SDK caches;
raw samples, source hashes and executable checksums stay under `.build` and in
[CI artifacts](https://github.com/henlamp/usd-mojo/actions/workflows/checks.yml).
Scheduling affects timings. CPU data-access checks exclude GPU transfer, simulation
and rendering. The separate imaging timings below include readback synchronization.

| Command after `pixi run` | Measures and checks |
| --- | --- |
| `benchmark-native` | Owned copies, borrowed snapshots and reusable output buffers; five rotated rounds with full-data checksums. Destruction and final checksum are outside the timer. |
| `benchmark` | SDK and Mojo scene queries with matching operation contracts. |
| `python benchmarks/scene_handoff.py` | Capture and matrix consumption for 1,000/5,000 shared instances; verifies instance sharing, prim counts and a coordinate checksum. |
| `python benchmarks/mutations_and_arrays.py` | 2,000 scalar edits and 300,000-point reads; first access, variant switching, warm samples and peak RSS. |
| `python tools/workloads_check.py --corpus .local/corpus` | Three fresh-process samples per asset: opening, complete inventory scan and three captures; checks every geometry/topology component against the SDK. |
| `python benchmarks/lifetimes.py SCENE --rounds 2000` | Six fresh SDK/C ABI processes compare opening, flattening and capture with recreated or retained stages. Prim counts and matrix checksums must match. |

Ownership contracts differ: an owned copy is mutable, a borrowed snapshot retains
SDK storage, and reuse copies into caller storage. Capture includes SDK flattening;
consuming an existing view excludes it. Borrowing does not remove SDK decoding or
small-array materialization. YAM capture masks the robot root to exclude unrelated
UI metadata that the SDK cannot flatten losslessly.

Memory reports distinguish current/peak RSS from live allocator storage. macOS
uses its default malloc zone; Linux uses glibc arena/mmap counters where available.
These counters neither count cumulative allocations nor cover every allocator.
Schema layers initialized by flattening stay loaded; lifetime comparisons use each
process's own warmed baseline. They diagnose retention, not Mojo-versus-Python speed.

`pixi run python tools/render_session_check.py` also times moving-camera frames
with retained and newly created sessions. Both render the same camera positions.
Render-call time is CPU wall time; readback includes GPU completion and conversion.
Process/driver caches are warm. These are small-scene latency measurements, not
GPU timestamps or renderer throughput.
