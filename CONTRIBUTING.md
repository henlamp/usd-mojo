# Development

Develop on `development`; merge tested changes into `main` through focused pull
requests. Publish new versions from `main` and preserve published release files.

Use `pixi install --locked` and a C++ compiler. Keep builds outside synchronized folders.
Run `pixi run -e default acceptance --execution-kind native`; repeat with
`-e nightly` for compiler-sensitive changes.
Run benchmarks for performance changes. USD behavior needs independent SDK comparisons.
Native lifetime and parser workers live in `tests/`; Python authors independent SDK fixtures.
Document ownership, units and unsupported inputs. Retain dependency notices.

Releases use `conda.recipe/recipe.yaml` and `.github/workflows/release.yml`.
The `release` environment publishes through prefix.dev Repository Access.
For changed builds of the same version, increment both recipe build fields.
`python tools/release.py community --output DIR` exports a pinned community recipe.
Community builds start at zero; use `--build-number N` for subsequent rebuilds.
CodeQL runs when the repository is public; private analysis requires GitHub Code Security.
