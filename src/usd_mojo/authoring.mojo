# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Non-destructive authoring into the current edit target, including bulk values."""
from std.ffi import c_int, external_call
from .stage import Stage, TimeCode, _validate_time
from .value import Value
from .errors import UsdError
from ._bridge import (
    _c_bytes,
    _check,
    _error,
    _make_value,
    _StringsOwner,
)


@fieldwise_init
struct AttributeEdit(Copyable):
    var path: String
    var name: String
    var value: Value
    var time: TimeCode


def _specifier(mut stage: Stage, path: String, kind: Int) raises UsdError:
    var p = _c_bytes(path)
    _check(
        Int64(
            external_call["usdm_override_prim", c_int](
                stage._handle, p.unsafe_ptr(), c_int(kind)
            )
        )
    )


def override_prim(mut stage: Stage, path: String) raises UsdError:
    """Author an over; preserve weaker definitions and existing strong specs."""
    _specifier(stage, path, 0)


def create_class_prim(mut stage: Stage, path: String) raises UsdError:
    _specifier(stage, path, 1)


def set_active(mut stage: Stage, path: String, active: Bool) raises UsdError:
    var p = _c_bytes(path)
    _check(
        Int64(
            external_call["usdm_set_active", c_int](
                stage._handle, p.unsafe_ptr(), c_int(active)
            )
        )
    )


def create_attribute(
    mut stage: Stage,
    path: String,
    name: String,
    type_name: String,
    *,
    custom: Bool = True,
    uniform: Bool = False,
) raises UsdError:
    var p = _c_bytes(path)
    var n = _c_bytes(name)
    var t = _c_bytes(type_name)
    _check(
        Int64(
            external_call["usdm_attribute_create", c_int](
                stage._handle,
                p.unsafe_ptr(),
                n.unsafe_ptr(),
                t.unsafe_ptr(),
                c_int(custom),
                c_int(uniform),
            )
        )
    )


def _attribute_edit(
    mut stage: Stage, path: String, name: String, kind: Int, time: TimeCode
) raises UsdError:
    _validate_time(time)
    var p = _c_bytes(path)
    var n = _c_bytes(name)
    _check(
        Int64(
            external_call["usdm_attribute_edit", c_int](
                stage._handle,
                p.unsafe_ptr(),
                n.unsafe_ptr(),
                c_int(kind),
                time.value,
                c_int(time.is_default),
            )
        )
    )


def clear_attribute_values(
    mut stage: Stage, path: String, name: String
) raises UsdError:
    """Remove defaults and samples in the current edit target; reveal weaker data.
    """
    _attribute_edit(stage, path, name, 0, .default)


def clear_value_at(
    mut stage: Stage, path: String, name: String, time: TimeCode = .default
) raises UsdError:
    _attribute_edit(stage, path, name, 1, time)


def block_attribute(
    mut stage: Stage, path: String, name: String
) raises UsdError:
    """Author a value block and remove this edit target's time samples."""
    _attribute_edit(stage, path, name, 2, .default)


def block_value_at(
    mut stage: Stage, path: String, name: String, time: TimeCode
) raises UsdError:
    _attribute_edit(stage, path, name, 3, time)


def remove_property_opinion(
    mut stage: Stage, path: String, name: String
) raises UsdError:
    """Remove the current layer's property spec; weaker properties can remain.
    """
    var p = _c_bytes(path)
    var n = _c_bytes(name)
    _check(
        Int64(
            external_call["usdm_remove_property", c_int](
                stage._handle, p.unsafe_ptr(), n.unsafe_ptr()
            )
        )
    )


def _property_paths(
    mut stage: Stage, path: String, name: String, paths: List[String], kind: Int
) raises UsdError:
    var p = _c_bytes(path)
    var n = _c_bytes(name)
    var values = _StringsOwner(paths)
    _check(
        Int64(
            external_call["usdm_property_paths_set", c_int](
                stage._handle,
                p.unsafe_ptr(),
                n.unsafe_ptr(),
                values.handle,
                c_int(kind),
            )
        )
    )


def set_connections(
    mut stage: Stage, path: String, name: String, sources: List[String]
) raises UsdError:
    """An explicit empty list blocks weaker connection opinions."""
    _property_paths(stage, path, name, sources, 0)


def clear_connection_opinions(
    mut stage: Stage, path: String, name: String
) raises UsdError:
    """Remove connection opinions from this edit target; reveal weaker sources.
    """
    _property_paths(stage, path, name, List[String](), 1)


def set_relationship_targets(
    mut stage: Stage, path: String, name: String, targets: List[String]
) raises UsdError:
    _property_paths(stage, path, name, targets, 2)


struct _BatchOwner(Movable):
    var handle: UInt64

    def __init__(out self) raises UsdError:
        self.handle = external_call["usdm_batch_new", UInt64]()
        if not self.handle:
            raise _error()

    def __init__(out self, *, deinit move: Self):
        self.handle = move.handle

    def __deinit__(deinit self):
        external_call["usdm_batch_close", NoneType](self.handle)


def set_values(mut stage: Stage, edits: List[AttributeEdit]) raises UsdError:
    """Preflight a batch, then author Sdf values with deferred recomposition.

    Prims must already exist. Input order decides repeated writes to the same
    attribute/time. Conflicting types and invalid mappings fail before edits.
    Non-identity time mappings and timecode-valued data delegate writes to Usd
    and can emit multiple notices; root/identity batches defer recomposition.
    This is not an undo transaction for SDK or allocation failures during writes.
    """
    var batch = _BatchOwner()
    for edit in edits:
        _validate_time(edit.time)
        var p = _c_bytes(edit.path)
        var n = _c_bytes(edit.name)
        var value = _make_value(edit.value)
        _check(
            Int64(
                external_call["usdm_batch_append", c_int](
                    batch.handle,
                    p.unsafe_ptr(),
                    n.unsafe_ptr(),
                    value.handle,
                    edit.time.value,
                    c_int(edit.time.is_default),
                )
            )
        )
    _check(
        Int64(
            external_call["usdm_batch_apply", c_int](
                stage._handle, batch.handle
            )
        )
    )
