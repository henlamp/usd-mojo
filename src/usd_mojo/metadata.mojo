# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Owned SDK metadata, including nested dictionaries and opaque list operations."""
from std.ffi import c_int, external_call
from std.collections import Array
from .errors import UsdError
from .stage import Stage
from .layers import Layer
from .value import Value
from ._bridge import (
    _c_bytes,
    _error,
    _check,
    _take_text,
    _take_strings,
    _take_value,
    _make_value,
    _StringsOwner,
)


struct CompositionArc(Copyable):
    var asset_path: String
    var prim_path: String
    var offset: Float64
    var scale: Float64

    def __init__(
        out self,
        var asset_path: String,
        var prim_path: String = "",
        offset: Float64 = 0,
        scale: Float64 = 1,
    ):
        self.asset_path = asset_path^
        self.prim_path = prim_path^
        self.offset = offset
        self.scale = scale


def _operation(name: String) raises UsdError -> Int:
    if name == "explicit":
        return 0
    if name == "prepend":
        return 1
    if name == "append":
        return 2
    if name == "delete":
        return 3
    if name == "add":
        return 4
    if name == "order":
        return 5
    raise UsdError(.invalid_argument, "Unknown USD list operation")


struct Metadata(Movable):
    var _handle: UInt64

    @staticmethod
    def _from_handle(handle: UInt64) raises UsdError -> Self:
        if not handle:
            raise _error()
        return Self(_handle=handle)

    def __init__(out self, *, _handle: UInt64):
        self._handle = _handle

    def __init__(out self) raises UsdError:
        self._handle = external_call["usdm_meta_dictionary", UInt64]()
        if not self._handle:
            raise _error()

    def __init__(out self, value: Value) raises UsdError:
        var native = _make_value(value)
        self._handle = external_call["usdm_meta_leaf", UInt64](native.handle)
        if not self._handle:
            raise _error()

    def __init__(
        out self,
        stage: Stage,
        key: String,
        *,
        path: String = "",
        attribute: String = "",
        dictionary: String = "",
    ) raises UsdError:
        self._handle = 0
        var k = _c_bytes(key)
        var p = _c_bytes(path)
        var a = _c_bytes(attribute)
        var d = _c_bytes(dictionary)
        self._handle = external_call["usdm_meta_read", UInt64](
            stage._handle,
            p.unsafe_ptr(),
            a.unsafe_ptr(),
            k.unsafe_ptr(),
            d.unsafe_ptr(),
        )
        if not self._handle:
            raise _error()

    def __init__(out self, parent: Metadata, key: String) raises UsdError:
        self._handle = 0
        var data = _c_bytes(key)
        self._handle = external_call["usdm_meta_child", UInt64](
            parent._handle, data.unsafe_ptr()
        )
        if not self._handle:
            raise _error()

    def __init__(
        out self, layer: Layer, key: String, *, path: String = "/"
    ) raises UsdError:
        self._handle = 0
        var p = _c_bytes(path)
        var k = _c_bytes(key)
        self._handle = external_call["usdm_layer_metadata", UInt64](
            layer._handle, p.unsafe_ptr(), k.unsafe_ptr()
        )
        if not self._handle:
            raise _error()

    def __init__(
        out self,
        items: List[String],
        *,
        kind: String = "path",
        operation: String = "explicit",
    ) raises UsdError:
        self._handle = 0
        var k = 0
        if kind == "token":
            k = 1
        elif kind == "string":
            k = 2
        elif kind != "path":
            raise UsdError(.invalid_argument, "Unknown USD list item kind")
        var op = _operation(operation)
        var data = _StringsOwner(items)
        self._handle = external_call["usdm_meta_string_list", UInt64](
            data.handle, c_int(op), c_int(k)
        )
        if not self._handle:
            raise _error()

    def __init__(
        out self,
        arcs: List[CompositionArc],
        *,
        payloads: Bool = False,
        operation: String = "prepend",
    ) raises UsdError:
        self._handle = 0
        var op = _operation(operation)
        var assets = List[String](capacity=len(arcs))
        var prims = List[String](capacity=len(arcs))
        var times = List[Float64](capacity=2 * len(arcs))
        for arc in arcs:
            assets.append(arc.asset_path)
            prims.append(arc.prim_path)
            times.append(arc.offset)
            times.append(arc.scale)
        var a = _StringsOwner(assets)
        var p = _StringsOwner(prims)
        var values = Value.floating("double[]", times^)
        var t = _make_value(values)
        self._handle = external_call["usdm_meta_arcs", UInt64](
            a.handle, p.handle, t.handle, c_int(op), c_int(payloads)
        )
        if not self._handle:
            raise _error()

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_meta_close", NoneType](self._handle)

    def type_name(self) raises UsdError -> String:
        return _take_text(external_call["usdm_meta_type", UInt64](self._handle))

    def is_dictionary(self) raises UsdError -> Bool:
        var result = external_call["usdm_meta_is_dictionary", c_int](
            self._handle
        )
        _check(Int64(result))
        return result != 0

    def keys(self) raises UsdError -> List[String]:
        return _take_strings(
            external_call["usdm_meta_keys", UInt64](self._handle)
        )

    def value(self) raises UsdError -> Value:
        return _take_value(
            external_call["usdm_meta_value", UInt64](self._handle)
        )

    def set(mut self, key: String, value: Metadata) raises UsdError:
        var data = _c_bytes(key)
        _check(
            Int64(
                external_call["usdm_meta_set_child", c_int](
                    self._handle, data.unsafe_ptr(), value._handle, c_int(0)
                )
            )
        )

    def erase(mut self, key: String) raises UsdError:
        var data = _c_bytes(key)
        _check(
            Int64(
                external_call["usdm_meta_set_child", c_int](
                    self._handle, data.unsafe_ptr(), UInt64(0), c_int(1)
                )
            )
        )

    def items(
        self, operation: String = "explicit"
    ) raises UsdError -> List[String]:
        var op = _operation(operation)
        return _take_strings(
            external_call["usdm_meta_list_strings", UInt64](
                self._handle, c_int(op)
            )
        )

    def arcs(
        self, operation: String = "prepend"
    ) raises UsdError -> List[CompositionArc]:
        var op = _operation(operation)
        var count = external_call["usdm_meta_arc_count", Int64](
            self._handle, c_int(op)
        )
        _check(count)
        var result = List[CompositionArc](capacity=Int(count))
        for i in range(Int(count)):
            var asset = _take_text(
                external_call["usdm_meta_arc_text", UInt64](
                    self._handle, c_int(op), Int64(i), c_int(0)
                )
            )
            var prim = _take_text(
                external_call["usdm_meta_arc_text", UInt64](
                    self._handle, c_int(op), Int64(i), c_int(1)
                )
            )
            var times = Array[Float64, 2]()
            _check(
                Int64(
                    external_call["usdm_meta_arc_times", c_int](
                        self._handle,
                        c_int(op),
                        Int64(i),
                        times.unsafe_ptr(),
                        Int64(2),
                    )
                )
            )
            result.append(CompositionArc(asset^, prim^, times[0], times[1]))
        return result^


def _author_metadata(
    mut stage: Stage,
    key: String,
    metadata: UInt64,
    path: String,
    attribute: String,
    dictionary: String,
    clear: Bool,
) raises UsdError:
    var k = _c_bytes(key)
    var p = _c_bytes(path)
    var a = _c_bytes(attribute)
    var d = _c_bytes(dictionary)
    _check(
        Int64(
            external_call["usdm_meta_write", c_int](
                stage._handle,
                p.unsafe_ptr(),
                a.unsafe_ptr(),
                k.unsafe_ptr(),
                d.unsafe_ptr(),
                metadata,
                c_int(clear),
            )
        )
    )


def set_metadata(
    mut stage: Stage,
    key: String,
    value: Metadata,
    *,
    path: String = "",
    attribute: String = "",
    dictionary: String = "",
) raises UsdError:
    _author_metadata(
        stage, key, value._handle, path, attribute, dictionary, False
    )


def clear_metadata(
    mut stage: Stage,
    key: String,
    *,
    path: String = "",
    attribute: String = "",
    dictionary: String = "",
) raises UsdError:
    _author_metadata(stage, key, 0, path, attribute, dictionary, True)


def set_layer_field(
    mut layer: Layer, key: String, value: Metadata, *, path: String = "/"
) raises UsdError:
    var p = _c_bytes(path)
    var k = _c_bytes(key)
    _check(
        Int64(
            external_call["usdm_layer_set_metadata", c_int](
                layer._handle,
                p.unsafe_ptr(),
                k.unsafe_ptr(),
                value._handle,
                c_int(0),
            )
        )
    )


def clear_layer_field(
    mut layer: Layer, key: String, *, path: String = "/"
) raises UsdError:
    var p = _c_bytes(path)
    var k = _c_bytes(key)
    _check(
        Int64(
            external_call["usdm_layer_set_metadata", c_int](
                layer._handle,
                p.unsafe_ptr(),
                k.unsafe_ptr(),
                UInt64(0),
                c_int(1),
            )
        )
    )
