from std.sys import argv
from usd_mojo import Stage


def main() raises:
    var first = Stage(argv()[1])
    var second = first
    print(first.up_axis(), second.up_axis())
