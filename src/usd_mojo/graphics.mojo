# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Geometry, primvar and camera snapshots retaining USD conventions and units."""
from .errors import UsdError
from .stage import Stage, TimeCode
from .value import Value


@fieldwise_init
struct PrimvarData(Copyable):
    """Raw owned values plus optional indices; interpolation remains explicit.
    """

    var values: Value
    var indices: List[Int32]
    var interpolation: String
    var element_size: Int
    var unauthored_values_index: Int


@fieldwise_init
struct CameraData(Copyable):
    """USD focal/aperture units are tenths of a world unit; no unit conversion.
    """

    var projection: String
    var focal_length: Float64
    var horizontal_aperture: Float64
    var vertical_aperture: Float64
    var horizontal_aperture_offset: Float64
    var vertical_aperture_offset: Float64
    var clipping_range: List[Float64]
    var focus_distance: Float64
    var f_stop: Float64
    var world_matrix: List[Float64]


def read_primvar(
    stage: Stage, path: String, name: String, time: TimeCode = .default
) raises UsdError -> PrimvarData:
    var property = String("primvars:", name)
    var values = stage.read_value(path, property, time)
    var indices = List[Int32]()
    var index_name = property + ":indices"
    if stage.has_attribute(path, index_name) and stage.has_authored_value(
        path, index_name
    ):
        indices = stage.read_int_array(path, index_name, time)
    var info = stage.primvar_info(path, property)
    return PrimvarData(
        values^,
        indices^,
        info.interpolation.copy(),
        info.element_size,
        info.unauthored_values_index,
    )


def read_normals(
    stage: Stage, path: String, time: TimeCode = .default
) raises UsdError -> PrimvarData:
    if stage.prim_type(path) != "Mesh":
        raise UsdError(.type_mismatch, "Normals snapshot requires a Mesh prim")
    return PrimvarData(
        stage.read_value(path, "normals", time),
        List[Int32](),
        stage.normals_interpolation(path),
        1,
        -1,
    )


def read_camera(
    stage: Stage, path: String, time: TimeCode = .default
) raises UsdError -> CameraData:
    if stage.prim_type(path) != "Camera":
        raise UsdError(
            .invalid_argument, "Camera snapshot requires a Camera prim"
        )
    var clipping = stage.read_value(path, "clippingRange", time)
    return CameraData(
        stage.read_text(path, "projection", time),
        stage.read_float(path, "focalLength", time),
        stage.read_float(path, "horizontalAperture", time),
        stage.read_float(path, "verticalAperture", time),
        stage.read_float(path, "horizontalApertureOffset", time),
        stage.read_float(path, "verticalApertureOffset", time),
        clipping.numbers.copy(),
        stage.read_float(path, "focusDistance", time),
        stage.read_float(path, "fStop", time),
        stage.world_transform(path, time),
    )
