# Development

Develop on `development` and submit focused pull requests. Released tags and
packages are immutable; publishing is maintainer-controlled.

Use `pixi install --locked` and a C++ compiler outside synchronized folders.
[Validation](docs/VALIDATION.md) lists acceptance, corpus and optional rendering
commands; run benchmarks for performance changes. Python provides independent
SDK references. Keep ownership, units, unsupported inputs and notices explicit.

`tools/value_types.json` defines supported C++ types, component widths and storage
channels. Run `python tools/generate.py --check`; the C++ compiler also checks
these layouts against the shared scalar/vector/matrix/quaternion codecs.

## Release checks

Preserve the reviewed source API and require current native acceptance with both
compilers on macOS ARM64 and Linux x86-64, including the external corpus,
installed consumers and fresh Pixi installation.
GPU claims need measurements on each advertised backend.

`conda.recipe/recipe.yaml` and `.github/workflows/release.yml` build the packages.
The workflow collects both compiler runs per platform; the gate and upload command
verify report, artifact and log hashes. Manual uploads require the same
`--acceptance-root` evidence. The `release` environment uses prefix.dev Repository
Access and permits version tags only. Branch dispatches validate packages without
publishing; dispatch from a version tag to upload. Increment both recipe build
fields for changed builds of the same version.

`python tools/release.py community --output DIR` exports a pinned community recipe.
Community builds start at zero; use `--build-number N` for subsequent rebuilds.

`tools/update.py --detect` lists upstream stable releases; `--latest` prepares
exact pins and a matching recipe build increment. Resolve the lockfile and run
the generated/catalog/API checks before accepting an update. The manual
`Toolchain update proposal` workflow opens a draft PR after Linux checks; it has
no schedule or package-publishing step. Mac and optional renderer qualification
remain separate. Unknown SDK types fail the catalog check instead of silently
acquiring generated ownership code.
