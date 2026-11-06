from std.collections import ImmSpan
from usd_mojo import Stage, SceneSnapshot, UsdError


def escape(stage: Stage) raises UsdError -> ImmSpan[Float64, origin_of(stage)]:
    var snapshot = SceneSnapshot(stage)
    return snapshot.transforms()


def main() raises:
    var stage = Stage("scene.usda")
    var values = escape(stage)
    print(values[0])
