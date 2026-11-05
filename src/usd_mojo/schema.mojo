# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Resolved schema properties, relationships and connections at one time."""
from std.ffi import c_int, external_call
from .errors import UsdError
from .stage import Stage, TimeCode, _validate_time
from .value import Value
from ._bridge import (
    _c_bytes,
    _error,
    _take_strings,
    _take_value,
)


struct SchemaSnapshot(Movable):
    """Own resolved values independently of a stage, including schema fallbacks.

    Missing/blocked values are listed explicitly. Shader, light, render, physics,
    curve, subdivision, skeleton and plugin properties use their USD names.
    Reading properties does not evaluate a renderer, simulator or tessellator.
    """

    var _handle: UInt64

    def __init__(
        out self, stage: Stage, path: String, time: TimeCode = .default
    ) raises UsdError:
        self._handle = 0
        _validate_time(time)
        var p = _c_bytes(path)
        self._handle = external_call["usdm_schema_snapshot", UInt64](
            stage._handle, p.unsafe_ptr(), time.value, c_int(time.is_default)
        )
        if not self._handle:
            raise _error()

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_schema_close", NoneType](self._handle)

    def _names(self, kind: Int) raises UsdError -> List[String]:
        return _take_strings(
            external_call["usdm_schema_names", UInt64](
                self._handle, c_int(kind)
            )
        )

    def attributes(self) raises UsdError -> List[String]:
        return self._names(0)

    def missing_values(self) raises UsdError -> List[String]:
        return self._names(1)

    def relationships(self) raises UsdError -> List[String]:
        return self._names(2)

    def value(self, name: String) raises UsdError -> Value:
        var n = _c_bytes(name)
        return _take_value(
            external_call["usdm_schema_value", UInt64](
                self._handle, n.unsafe_ptr()
            )
        )

    def _paths(self, name: String, kind: Int) raises UsdError -> List[String]:
        var n = _c_bytes(name)
        return _take_strings(
            external_call["usdm_schema_paths", UInt64](
                self._handle, n.unsafe_ptr(), c_int(kind)
            )
        )

    def targets(self, name: String) raises UsdError -> List[String]:
        return self._paths(name, 0)

    def connections(self, name: String) raises UsdError -> List[String]:
        return self._paths(name, 1)


def schema_properties(
    name: String, *, api: Bool = False
) raises UsdError -> List[String]:
    var n = _c_bytes(name)
    return _take_strings(
        external_call["usdm_schema_definition", UInt64](
            n.unsafe_ptr(), c_int(api)
        )
    )
