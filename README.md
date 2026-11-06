# usd-mojo

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
The 0.2.0 community package update is pending.
Pixi installs the SDK and CPython library; the Mojo API makes no Python
calls. Version 0.2.0 uses Mojo 1.2.0; the pinned 1.2.0.dev2026100905
snapshot remains an additional compatibility target.
Version 0.2.0 adds Linux x86-64 alongside macOS ARM64, layer/edit-target APIs,
metadata/schema snapshots, working-set controls, splines, skeleton evaluation,
USDZ export and optional Hydra/MaterialX rendering.
[Validation](docs/VALIDATION.md) records tested sources, platforms and packages.

Stages are move-only and cannot be accessed concurrently. Units, matrices and
time codes retain USD conventions. Physics execution and subdivision evaluation
belong to the application's backends. Referenced assets and plugins
use the SDK resolver; scenes are not sandboxed.

[API](docs/API.md) · [Compatibility](docs/COMPATIBILITY.md) ·
[Checks](docs/VALIDATION.md) · [Benchmarks](docs/BENCHMARKS.md).
From source: `pixi install --locked`, then `pixi run -e default check`;
see [development](CONTRIBUTING.md).

Library and bridge: [MIT](LICENSE). OpenUSD: TOST 1.0, with unchanged
[license](licenses/OpenUSD-LICENSE.txt) and [notices](licenses/OpenUSD-NOTICE.txt).
See [dependencies](THIRD_PARTY_NOTICES.md).
