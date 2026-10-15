from usd_mojo import Stage


def main() raises:
    var stage = Stage("scene.usda")
    var snapshot = stage.mesh_snapshot("/World/Mesh")
    var values = snapshot.points()
    var moved = snapshot^
    print(values[0], moved.point_count())
