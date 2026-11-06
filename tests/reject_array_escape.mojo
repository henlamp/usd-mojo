from std.collections import ImmSpan
from usd_mojo import Stage, ArraySnapshot, UsdError


def escape(stage: Stage) raises UsdError -> ImmSpan[Float32, origin_of(stage)]:
    var snapshot = ArraySnapshot(stage, "/World/Mesh", "points")
    return snapshot.view[DType.float32]()


def main() raises:
    var stage = Stage("scene.usda")
    var span = escape(stage)
    print(span[0])
