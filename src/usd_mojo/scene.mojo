# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""SDK-evaluated geometry and skeleton data; transforms retain USD row order."""
from std.ffi import c_int, external_call
from .errors import UsdError
from .stage import Stage, TimeCode, _validate_time
from .value import Value
from ._bridge import (
    _c_bytes,
    _take_text,
    _take_value,
    _take_strings,
    _StringsOwner,
)


def _geom_text(
    stage: Stage, path: String, kind: Int, time: TimeCode
) raises UsdError -> String:
    _validate_time(time)
    var p = _c_bytes(path)
    return _take_text(
        external_call["usdm_geom_text", UInt64](
            stage._handle,
            p.unsafe_ptr(),
            c_int(kind),
            time.value,
            c_int(time.is_default),
        )
    )


def visibility(
    stage: Stage, path: String, time: TimeCode = .default
) raises UsdError -> String:
    return _geom_text(stage, path, 0, time)


def purpose(stage: Stage, path: String) raises UsdError -> String:
    return _geom_text(stage, path, 1, .default)


def world_bounds(
    stage: Stage,
    path: String,
    time: TimeCode = .default,
    *,
    purposes: List[String] = [String("default")],
) raises UsdError -> Value:
    """Aligned world-space min/max float64 triples; empty bounds raise not_found.
    """
    _validate_time(time)
    var p = _c_bytes(path)
    var ps = _StringsOwner(purposes)
    return _take_value(
        external_call["usdm_world_bounds", UInt64](
            stage._handle,
            p.unsafe_ptr(),
            ps.handle,
            time.value,
            c_int(time.is_default),
        )
    )


def inherited_primvar(
    stage: Stage, path: String, name: String, time: TimeCode = .default
) raises UsdError -> Value:
    """Find the SDK-inheritable primvar and expand its indices/elementSize."""
    _validate_time(time)
    var p = _c_bytes(path)
    var n = _c_bytes(name)
    return _take_value(
        external_call["usdm_inherited_primvar", UInt64](
            stage._handle,
            p.unsafe_ptr(),
            n.unsafe_ptr(),
            time.value,
            c_int(time.is_default),
        )
    )


def _instances(
    stage: Stage, path: String, kind: Int, time: TimeCode, prototype: Bool
) raises UsdError -> Value:
    _validate_time(time)
    var p = _c_bytes(path)
    return _take_value(
        external_call["usdm_instance_data", UInt64](
            stage._handle,
            p.unsafe_ptr(),
            c_int(kind),
            time.value,
            c_int(time.is_default),
            c_int(prototype),
        )
    )


def instance_transforms(
    stage: Stage,
    path: String,
    time: TimeCode = .default,
    *,
    include_prototype: Bool = True,
) raises UsdError -> Value:
    """All local matrices, including masked instances, aligned with protoIndices.
    """
    return _instances(stage, path, 0, time, include_prototype)


def instance_mask(
    stage: Stage, path: String, time: TimeCode = .default
) raises UsdError -> Value:
    """One 0/1 integer per instance; applies inactiveIds and invisibleIds."""
    return _instances(stage, path, 1, time, True)


def bound_material(
    stage: Stage, path: String, material_purpose: String = ""
) raises UsdError -> String:
    var p = _c_bytes(path)
    var m = _c_bytes(material_purpose)
    return _take_text(
        external_call["usdm_bound_material", UInt64](
            stage._handle, p.unsafe_ptr(), m.unsafe_ptr()
        )
    )


def _skeleton(
    stage: Stage, path: String, mesh: String, kind: Int, time: TimeCode
) raises UsdError -> Value:
    _validate_time(time)
    var p = _c_bytes(path)
    var m = _c_bytes(mesh)
    return _take_value(
        external_call["usdm_skeleton_data", UInt64](
            stage._handle,
            p.unsafe_ptr(),
            m.unsafe_ptr(),
            c_int(kind),
            time.value,
            c_int(time.is_default),
        )
    )


def skeleton_joints(stage: Stage, path: String) raises UsdError -> Value:
    return _skeleton(stage, path, "", 0, .default)


def joint_transforms(
    stage: Stage, path: String, time: TimeCode = .default
) raises UsdError -> Value:
    return _skeleton(stage, path, "", 1, time)


def skinning_transforms(
    stage: Stage, path: String, time: TimeCode = .default
) raises UsdError -> Value:
    return _skeleton(stage, path, "", 2, time)


def skinned_points(
    stage: Stage, skeleton: String, mesh: String, time: TimeCode = .default
) raises UsdError -> Value:
    """SDK blend shapes/inbetweens followed by joint skinning, in skeleton space.
    """
    return _skeleton(stage, skeleton, mesh, 3, time)


def collection_members(
    stage: Stage, path: String, name: String
) raises UsdError -> List[String]:
    var p = _c_bytes(path)
    var n = _c_bytes(name)
    return _take_strings(
        external_call["usdm_collection_members", UInt64](
            stage._handle, p.unsafe_ptr(), n.unsafe_ptr()
        )
    )
