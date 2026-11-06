# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Explicit SDK working sets, layer muting and composition provenance."""
from std.ffi import c_int, external_call
from .errors import UsdError
from .stage import Stage
from .layers import Layer
from .metadata import Metadata, CompositionArc, set_layer_field, clear_layer_field
from ._bridge import (
    _c_bytes,
    _take_strings,
    _check,
    _StringsOwner,
)


@fieldwise_init
struct LoadRule(Copyable):
    var path: String
    var mode: String


@fieldwise_init
struct PrimArc(Copyable):
    var kind: String
    var layer_identifier: String
    var source_path: String


def population_mask(stage: Stage) raises UsdError -> List[String]:
    return _take_strings(
        external_call["usdm_stage_mask", UInt64](stage._handle)
    )


def set_population_mask(mut stage: Stage, paths: List[String]) raises UsdError:
    var data = _StringsOwner(paths)
    _check(
        Int64(
            external_call["usdm_stage_mask_set", c_int](
                stage._handle, data.handle, c_int(0)
            )
        )
    )


def expand_population_mask(mut stage: Stage) raises UsdError:
    """Expand to relationship/connection dependencies using SDK policy."""
    _check(
        Int64(
            external_call["usdm_stage_mask_set", c_int](
                stage._handle, UInt64(0), c_int(1)
            )
        )
    )


def load_rules(stage: Stage) raises UsdError -> List[LoadRule]:
    var fields = _take_strings(
        external_call["usdm_load_rules", UInt64](stage._handle)
    )
    if len(fields) % 2 != 0:
        raise UsdError(.internal, "Invalid load rule snapshot")
    var result = List[LoadRule](capacity=len(fields) // 2)
    for i in range(0, len(fields), 2):
        result.append(LoadRule(fields[i], fields[i + 1]))
    return result^


def set_load_rules(mut stage: Stage, rules: List[LoadRule]) raises UsdError:
    var paths = List[String](capacity=len(rules))
    var modes = List[String](capacity=len(rules))
    for rule in rules:
        paths.append(rule.path)
        modes.append(rule.mode)
    var p = _StringsOwner(paths)
    var m = _StringsOwner(modes)
    _check(
        Int64(
            external_call["usdm_set_load_rules", c_int](
                stage._handle, p.handle, m.handle
            )
        )
    )


def mute_layer(
    mut stage: Stage, identifier: String, *, muted: Bool = True
) raises UsdError:
    var name = _c_bytes(identifier)
    _check(
        Int64(
            external_call["usdm_mute_layer", c_int](
                stage._handle, name.unsafe_ptr(), c_int(muted)
            )
        )
    )


def muted_layers(stage: Stage) raises UsdError -> List[String]:
    return _take_strings(
        external_call["usdm_muted_layers", UInt64](stage._handle)
    )


def composition_arcs(
    stage: Stage, path: String
) raises UsdError -> List[PrimArc]:
    var p = _c_bytes(path)
    var fields = _take_strings(
        external_call["usdm_prim_arcs", UInt64](stage._handle, p.unsafe_ptr())
    )
    if len(fields) % 3 != 0:
        raise UsdError(.internal, "Invalid composition arc snapshot")
    var result = List[PrimArc](capacity=len(fields) // 3)
    for i in range(0, len(fields), 3):
        result.append(PrimArc(fields[i], fields[i + 1], fields[i + 2]))
    return result^


def register_plugins(path: String) raises UsdError -> List[String]:
    """Register SDK plugins; plugin code and asset access require trusted inputs.
    """
    var p = _c_bytes(path)
    return _take_strings(
        external_call["usdm_register_plugins", UInt64](p.unsafe_ptr())
    )


def set_reference_opinions(mut layer: Layer, path: String, arcs: List[CompositionArc], *, operation: String = "explicit") raises UsdError:
    """Author a local reference list opinion, creating an over if needed."""
    var data = Metadata(arcs, operation=operation)
    layer.override_prim(path)
    set_layer_field(layer, "references", data, path=path)


def set_payload_opinions(mut layer: Layer, path: String, arcs: List[CompositionArc], *, operation: String = "explicit") raises UsdError:
    var data = Metadata(arcs, payloads=True, operation=operation)
    layer.override_prim(path)
    set_layer_field(layer, "payload", data, path=path)


def set_inherit_opinions(mut layer: Layer, path: String, paths: List[String], *, operation: String = "explicit") raises UsdError:
    var data = Metadata(paths, kind="path", operation=operation)
    layer.override_prim(path)
    set_layer_field(layer, "inheritPaths", data, path=path)


def set_specialize_opinions(mut layer: Layer, path: String, paths: List[String], *, operation: String = "explicit") raises UsdError:
    var data = Metadata(paths, kind="path", operation=operation)
    layer.override_prim(path)
    set_layer_field(layer, "specializes", data, path=path)


def clear_arc_opinions(mut layer: Layer, path: String, kind: String) raises UsdError:
    """Remove a local list opinion, revealing weaker composition opinions."""
    if kind != "references" and kind != "payload" and kind != "inheritPaths" and kind != "specializes":
        raise UsdError(.invalid_argument, "Unknown composition arc field")
    clear_layer_field(layer, kind, path=path)
