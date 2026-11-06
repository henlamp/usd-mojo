from usd_mojo import Stage, SceneSnapshot


def main() raises:
    var stage = Stage("scene.usda")
    var snapshot = SceneSnapshot(stage)
    var values = snapshot.transforms()
    var moved = snapshot^
    print(values[0], moved.generation)
