from usd_mojo import Stage


def main() raises:
    var stage = Stage("scene.usda")
    var snapshot = stage.mesh_snapshot("/World/Mesh")
    var values = snapshot.points()
    values[0] = Float32(1)
