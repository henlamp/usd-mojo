from usd_mojo import Stage
from usd_mojo.imaging import RenderSession


def main() raises:
    var stage = Stage("scene.usda")
    var session = RenderSession(stage, 16, 16)
    var duplicate = session.copy()
    print(duplicate.width)
