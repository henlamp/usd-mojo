from std.sys import argv
from usd_mojo import Stage, sdk_version


def main() raises:
    var stage = Stage(argv()[1])
    print("OpenUSD SDK:", sdk_version())
    print("Units:", stage.meters_per_unit(), "m; up axis:", stage.up_axis())
    var paths = stage.prim_paths()
    for path in paths:
        var kind = stage.prim_type(path)
        print(path, kind)
        if kind == "Mesh":
            var mesh = stage.mesh(path)
            print(
                "  points:", mesh.point_count(), "polygons:", mesh.face_count()
            )
