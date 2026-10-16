# usd-mojo

[![CodeQL](https://github.com/henlamp/usd-mojo/actions/workflows/codeql.yml/badge.svg)](https://github.com/henlamp/usd-mojo/actions/workflows/codeql.yml)

OpenUSD scene access from Mojo through the official C++ SDK: composition,
typed values, animation, meshes, transforms, materials, cameras and physics
schema data. Returned values own their storage; mesh snapshots offer borrowed views.

## Install

With [Pixi](https://pixi.sh):

```sh
pixi init my-project
cd my-project
pixi workspace channel add https://repo.prefix.dev/modular-community https://conda.modular.com/max
pixi add usd-mojo
```

Save as `example.mojo` and provide a scene containing `/World/Mesh`:

```mojo
from usd_mojo import Stage

def main() raises:
    var stage = Stage("scene.usda")
    var mesh = stage.mesh("/World/Mesh")
    print(mesh.point_count(), mesh.face_count())
```

```sh
pixi run usd-mojo-build example.mojo -o example
pixi run ./example
```

Published 0.1.0 packages target Mojo 1.1.0, OpenUSD 26.08 and macOS ARM64.
Pixi installs the SDK and CPython library; the Mojo API makes no Python
calls. Source checks also cover 1.2.0.dev2026100905 and Linux x86-64.
Development 0.2.0 passes native Linux packaging and fresh Pixi installation
on Ubuntu 22.04 under WSL2; it is not yet published.

Stages are move-only and cannot be accessed concurrently. Units, matrices and
time codes retain USD conventions. Rendering, physics execution, subdivision
evaluation and USDZ packaging are outside the API. Referenced assets and plugins
use the SDK resolver; scenes are not sandboxed.

[API](docs/API.md) · [Compatibility](docs/COMPATIBILITY.md) ·
[Checks](docs/VALIDATION.md) · [Benchmarks](docs/BENCHMARKS.md).
From source: `pixi install --locked`, then `pixi run -e default check`;
see [development](CONTRIBUTING.md).

Library and bridge: [MIT](LICENSE). OpenUSD: TOST 1.0, with unchanged
[license](licenses/OpenUSD-LICENSE.txt) and [notices](licenses/OpenUSD-NOTICE.txt).
See [dependencies](THIRD_PARTY_NOTICES.md).
