# Host mesh-access measurements

`pixi run -e default benchmark-native` compares three different ownership
contracts: an owned mutable copy, an immutable borrowed snapshot, and copying
into reusable caller buffers. It uses warm SDK/filesystem caches, five rotated
rounds and a complete-data checksum for every mode. The timed region excludes
destruction and the final checksum. `pixi run -e default benchmark` separately
compares SDK and Mojo scene queries with matching operation contracts.

Results, source identities and executable checksums are retained in the
[CI artifacts](https://github.com/henlamp/usd-mojo/actions/workflows/checks.yml).
These host measurements do not establish end-to-end importer throughput,
simulator/GPU performance or training quality. Borrowing avoids output copying;
reusing storage does not imply that every workload runs faster. Timings depend
on CPU scheduling and background load and are not performance guarantees.
