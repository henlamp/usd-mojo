# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Export composed polygon meshes in world coordinates, meters and Z-up.

Includes instance proxies and invisible meshes. Preserves polygon faces and
hole masks; does not evaluate subdivision, normals, UVs, shaders or animation
between frames. stdout is OBJ geometry; callers publish it only after success.
"""
from std.collections import List
from std.math import isfinite
from std.sys import argv
from usd_mojo import Stage, TimeCode


def main() raises:
    var args = argv()
    if len(args) != 2 and len(args) != 3:
        raise Error("export_obj INPUT [FRAME]")
    var time = TimeCode.default
    if len(args) == 3:
        time = TimeCode.at(Float64(args[2]))
    var stage = Stage(args[1])
    var units = stage.meters_per_unit()
    var up = stage.up_axis()
    if units <= 0 or not isfinite(units) or (up != "Y" and up != "Z"):
        raise Error("Unsupported stage units or up axis")
    var offset = 1
    var meshes = 0
    print("# Composed USD polygon geometry; world coordinates in meters, Z-up")
    for path in stage.instance_paths():
        if stage.prim_type(path) != "Mesh":
            continue
        var mesh = stage.mesh_snapshot(path, time)
        var points = mesh.points()
        var counts = mesh.face_vertex_counts()
        var indices = mesh.face_vertex_indices()
        var matrix = stage.world_transform(path, time)
        for value in matrix:
            if not isfinite(value):
                raise Error("Non-finite mesh transform")
        if (
            abs(matrix[3]) > 1e-12
            or abs(matrix[7]) > 1e-12
            or abs(matrix[11]) > 1e-12
            or abs(matrix[15] - 1) > 1e-12
        ):
            raise Error("OBJ export requires an affine transform")
        var determinant = (
            matrix[0] * (matrix[5] * matrix[10] - matrix[6] * matrix[9])
            - matrix[1] * (matrix[4] * matrix[10] - matrix[6] * matrix[8])
            + matrix[2] * (matrix[4] * matrix[9] - matrix[5] * matrix[8])
        )
        var flip = (
            stage.read_text(path, "orientation", time) == "leftHanded"
        ) != (determinant < 0)
        var holes = stage.read_int_array(path, "holeIndices", time)
        var hole_mask = List[Bool](length=mesh.face_count(), fill=False)
        for hole in holes:
            if hole < 0 or Int(hole) >= mesh.face_count():
                raise Error("Invalid mesh hole index")
            hole_mask[Int(hole)] = True
        print(String("o mesh_", meshes))
        print(String("# USD prim ", path))
        meshes += 1
        for i in range(mesh.point_count()):
            var x = Float64(points[3 * i])
            var y = Float64(points[3 * i + 1])
            var z = Float64(points[3 * i + 2])
            var wx = (
                x * matrix[0] + y * matrix[4] + z * matrix[8] + matrix[12]
            ) * units
            var wy = (
                x * matrix[1] + y * matrix[5] + z * matrix[9] + matrix[13]
            ) * units
            var wz = (
                x * matrix[2] + y * matrix[6] + z * matrix[10] + matrix[14]
            ) * units
            if not isfinite(wx) or not isfinite(wy) or not isfinite(wz):
                raise Error("Non-finite transformed mesh point")
            if up == "Y":
                print(String("v ", wx, " ", -wz, " ", wy))
            else:
                print(String("v ", wx, " ", wy, " ", wz))
        var cursor = 0
        for face in range(mesh.face_count()):
            var count = Int(counts[face])
            if not hole_mask[face]:
                if count < 3:
                    raise Error(
                        "OBJ export requires polygon faces of at least three"
                        " vertices"
                    )
                var line = String("f")
                for corner in range(count):
                    var index = cursor + (
                        count - 1 - corner if flip else corner
                    )
                    line += String(" ", offset + Int(indices[index]))
                print(line)
            cursor += count
        offset += mesh.point_count()
