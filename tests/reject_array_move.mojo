from usd_mojo import Stage, ArraySnapshot


def main() raises:
    var stage = Stage("scene.usda")
    var snapshot = ArraySnapshot(stage, "/World/Mesh", "points")
    var span = snapshot.view[DType.float32]()
    var moved = snapshot^
    print(span[0], moved.element_count)
