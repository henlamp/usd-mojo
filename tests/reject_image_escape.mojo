from std.collections import ImmSpan
from usd_mojo import Stage, UsdError
from usd_mojo.imaging import RenderImage


def escape(stage: Stage) raises UsdError -> ImmSpan[Float32, origin_of(stage)]:
    var image = RenderImage(stage, "/Camera", 64, 64)
    return image.pixels()


def main() raises:
    var stage = Stage("scene.usda")
    var values = escape(stage)
    print(values[0])
