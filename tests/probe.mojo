"""Emit numeric data for comparison with the independent Python SDK API."""
from std.sys import argv
from usd_mojo import Stage, TimeCode


def main() raises:
    var stage = Stage(argv()[1])
    var path = String("/World/Robot/Triangle")
    var paths = stage.prim_paths()
    for item in paths:
        print("PATH", item, stage.prim_type(item))
    for frame in range(3):
        var time = TimeCode.at(Float64(frame))
        var mesh = stage.mesh(path, time)
        print("GAIN", frame, stage.read_float(path, "gain", time))
        for i in range(len(mesh.points)):
            print("POINT", frame, i, mesh.points[i])
        for i in range(len(mesh.face_vertex_counts)):
            print("COUNT", frame, i, mesh.face_vertex_counts[i])
        for i in range(len(mesh.face_vertex_indices)):
            print("INDEX", frame, i, mesh.face_vertex_indices[i])
        var matrix = stage.world_transform(path, time)
        for i in range(16):
            print("MATRIX", frame, i, matrix[i])
