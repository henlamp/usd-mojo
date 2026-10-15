from usd_mojo import Stage


def main() raises:
    var stage = Stage("scene.usda")
    var snapshot = stage.mesh_snapshot("/World/Mesh")
    var copied = snapshot
    print(snapshot.point_count(), copied.point_count())
