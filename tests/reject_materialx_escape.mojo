from std.collections import ImmSpan
from usd_mojo.materialx import MaterialXShader, MaterialXDocument


def escape(shader: MaterialXShader) raises -> ImmSpan[Float32, origin_of(shader)]:
    var image = shader.render(8, 8)
    return image.pixels()


def main() raises:
    var document = MaterialXDocument("scene.mtlx", "libraries")
    var shader = document.shader("out")
    var pixels = escape(shader)
    print(pixels[0])
