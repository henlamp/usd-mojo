# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Tab-separated composed-scene inventory, including instance proxy meshes."""
from std.sys import argv
from usd_mojo import Stage, TimeCode, read_camera


def main() raises:
    var args = argv()
    if len(args) != 2 and len(args) != 3:
        raise Error("scene_report INPUT [FRAME]")
    var time = TimeCode.default
    if len(args) == 3:
        time = TimeCode.at(Float64(args[2]))
    var stage = Stage(args[1])
    print(
        String(
            "STAGE\t",
            stage.up_axis(),
            "\t",
            stage.meters_per_unit(),
            "\t",
            stage.time_codes_per_second(),
        )
    )
    for path in stage.instance_paths():
        var kind = stage.prim_type(path)
        print(String("PRIM\t", path, "\t", kind))
        for schema in stage.applied_schemas(path):
            print(String("SCHEMA\t", path, "\t", schema))
        if kind == "Mesh":
            var mesh = stage.mesh_snapshot(path, time)
            print(
                String(
                    "MESH\t",
                    path,
                    "\t",
                    mesh.point_count(),
                    "\t",
                    mesh.face_count(),
                    "\t",
                    stage.material_path(path),
                )
            )
        elif kind == "Camera":
            var camera = read_camera(stage, path, time)
            print(String("CAMERA\t", path, "\t", camera.focal_length))
    for layer in stage.layer_identifiers():
        print(String("LAYER\t", layer))
    for diagnostic in stage.composition_errors():
        print(String("COMPOSITION_ERROR\t", diagnostic))
