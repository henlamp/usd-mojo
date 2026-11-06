from usd_mojo import Spline


def main() raises:
    var s = Spline()
    var invalid = s.copy()
    print(invalid.type_name)
