from std.collections import ImmSpan
from usd_mojo import Stage, UsdError


def escape(stage: Stage) raises UsdError -> ImmSpan[Float32, origin_of(stage)]:
    var snapshot = stage.mesh_snapshot("/World/Mesh")
    return snapshot.points()


def main() raises:
    var stage = Stage("scene.usda")
    var values = escape(stage)
    print(values[0])
