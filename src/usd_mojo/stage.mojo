# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Move-only scenes and independent, owned geometry snapshots.

The SDK resolves composition. Owned values and mesh snapshots retain their storage;
read-only mesh views borrow an explicit snapshot owner.
One stage must not be accessed concurrently. Matrix storage and units retain
USD conventions, allowing applications to choose their own conversions.
"""
from .errors import UsdError, UsdErrorKind
from std.collections import Array, ImmSpan, MutSpan
from std.memory import Pointer
from std.ffi import c_int, external_call
from std.math import isfinite
from .values import Vector3, Quaternion, TransformData
from .value import Value
from .information import AssetPathData, StageInfo, PrimInfo, PrimvarInfo


@fieldwise_init
struct TimeCode(ImplicitlyCopyable):
    """USD time-code units; default values differ from numeric frame zero."""

    var value: Float64
    var is_default: Bool
    comptime default = Self(0.0, True)

    @staticmethod
    def at(value: Float64) raises UsdError -> Self:
        if not isfinite(value):
            raise UsdError(.invalid_argument, "USD time code must be finite")
        return Self(value, False)


@fieldwise_init
struct MeshData(Copyable):
    """Owned local-space xyz Float32 points and Int32 polygon topology.

    Points remain in the stage's units. Winding, orientation, subdivision,
    normals, UVs and materials are separate USD properties; this type does
    not claim to contain a fully prepared render or collision mesh.
    """

    var points: List[Float32]
    var face_vertex_counts: List[Int32]
    var face_vertex_indices: List[Int32]

    def point_count(self) -> Int:
        return len(self.points) // 3

    def face_count(self) -> Int:
        return len(self.face_vertex_counts)


def _validate_text(var value: String) raises UsdError:
    for byte in value.bytes():
        if byte == 0:
            raise UsdError(
                .invalid_argument, "USD text must not contain NUL bytes"
            )


def _c_bytes(value: String) -> List[UInt8]:
    """Own a NUL-terminated UTF-8 buffer across the C call, including empty text.

    A temporary CStringSpan may own its terminator; extracting its raw pointer
    does not keep that temporary alive on every pinned compiler/host combination.
    """
    var result = List[UInt8](length=value.byte_length() + 1, fill=0)
    var i = 0
    for byte in value.bytes():
        result[i] = byte
        i += 1
    return result^


def _error() -> UsdError:
    var kind = UsdErrorKind(Int(external_call["usdm_error_kind", c_int]()))
    var needed = Int(external_call["usdm_error_size", Int64]())
    if needed <= 1:
        return UsdError(kind, "OpenUSD operation failed")
    var bytes = List[UInt8](length=needed, fill=0)
    var copied = external_call["usdm_error_text", Int64](
        bytes.unsafe_ptr(), Int64(needed)
    )
    if copied != Int64(needed):
        return UsdError(.internal, "Cannot copy OpenUSD error")
    return UsdError(kind, String(unsafe_from_utf8_ptr=bytes.unsafe_ptr()))


def _check(status: Int64) raises UsdError:
    if status < 0:
        raise _error()


def _validate_time(time: TimeCode) raises UsdError:
    if not time.is_default and not isfinite(time.value):
        raise UsdError(.invalid_argument, "USD time code must be finite")


def sdk_version() -> Int:
    """Return the linked SDK's numeric version, e.g. 2608 for 26.08."""
    return Int(external_call["usdm_sdk_version", c_int]())


struct Stage(Movable):
    """Own an OpenUSD stage. Open existing files, or use create=True.

    File paths resolve on the host. Construction opens the stage with the
    SDK's default load policy. Destruction releases it; save() is explicit.
    Operations author into the current edit target; edit_root() restores root.
    """

    var _handle: UInt64

    def __init__(
        out self,
        var filename: String,
        *,
        create: Bool = False,
        load_payloads: Bool = True,
    ) raises UsdError:
        var _filename_utf8 = _c_bytes(filename)
        self._handle = 0
        _validate_text(filename)
        if external_call["usdm_abi_version", c_int]() != 2:
            raise UsdError(.incompatible, "Incompatible usd-mojo bridge ABI")
        if create or load_payloads:
            self._handle = external_call["usdm_stage_open", UInt64](
                _filename_utf8.unsafe_ptr(), c_int(create)
            )
        else:
            self._handle = external_call["usdm_stage_open_policy", UInt64](
                _filename_utf8.unsafe_ptr(), c_int(0)
            )
        if not self._handle:
            raise _error()

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_stage_close", NoneType](self._handle)

    def _text(
        self,
        kind: Int,
        var path: String = "",
        var name: String = "",
        time: TimeCode = .default,
    ) raises UsdError -> String:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        _validate_time(time)
        var handle = external_call["usdm_text_snapshot", UInt64](
            self._handle,
            _path_utf8.unsafe_ptr(),
            c_int(kind),
            _name_utf8.unsafe_ptr(),
            time.value,
            c_int(time.is_default),
        )
        return self._consume_text(handle)

    def _consume_text(self, handle: UInt64) raises UsdError -> String:
        if not handle:
            raise _error()
        var owner = _TextOwner(handle)
        var needed = external_call["usdm_snapshot_text_size", Int64](
            owner.handle
        )
        _check(needed)
        if needed < 1:
            raise UsdError(.internal, "Invalid text snapshot extent")
        var bytes = List[UInt8](length=Int(needed), fill=0)
        var copied = external_call["usdm_snapshot_text", Int64](
            owner.handle, bytes.unsafe_ptr(), needed
        )
        _check(copied)
        if copied != needed:
            raise UsdError(.internal, "Text snapshot extent mismatch")
        return String(unsafe_from_utf8_ptr=bytes.unsafe_ptr())

    def _value_text(self, handle: UInt64, index: Int) raises UsdError -> String:
        var needed = external_call["usdm_value_text_size", Int64](
            handle, Int64(index)
        )
        _check(needed)
        var bytes = List[UInt8](length=Int(needed), fill=0)
        var copied = external_call["usdm_value_text", Int64](
            handle, Int64(index), bytes.unsafe_ptr(), needed
        )
        _check(copied)
        if copied != needed:
            raise UsdError(.internal, "USD value changed during copy")
        return String(unsafe_from_utf8_ptr=bytes.unsafe_ptr())

    def read_value(
        self, var path: String, var name: String, time: TimeCode = .default
    ) raises UsdError -> Value:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        _validate_time(time)
        var handle = external_call["usdm_value_read", UInt64](
            self._handle,
            _path_utf8.unsafe_ptr(),
            _name_utf8.unsafe_ptr(),
            time.value,
            c_int(time.is_default),
        )
        return self._consume_value(handle)

    def _consume_value(self, handle: UInt64) raises UsdError -> Value:
        if not handle:
            raise _error()
        var owner = _ValueOwner(handle)
        var result = Value(self._value_text(owner.handle, -1))
        var nc = external_call["usdm_value_count", Int64](
            owner.handle, c_int(0)
        )
        var ic = external_call["usdm_value_count", Int64](
            owner.handle, c_int(1)
        )
        var uc = external_call["usdm_value_count", Int64](
            owner.handle, c_int(2)
        )
        var tc = external_call["usdm_value_count", Int64](
            owner.handle, c_int(3)
        )
        _check(nc)
        _check(ic)
        _check(uc)
        _check(tc)
        result.numbers = List[Float64](length=Int(nc), fill=0)
        result.integers = List[Int64](length=Int(ic), fill=0)
        result.unsigned_integers = List[UInt64](length=Int(uc), fill=0)
        _check(
            Int64(
                external_call["usdm_value_copy", c_int](
                    owner.handle,
                    result.numbers.unsafe_ptr(),
                    nc,
                    result.integers.unsafe_ptr(),
                    ic,
                    result.unsigned_integers.unsafe_ptr(),
                    uc,
                )
            )
        )
        for i in range(Int(tc)):
            result.texts.append(self._value_text(owner.handle, i))
        return result^

    def set_value(
        mut self,
        var path: String,
        var name: String,
        value: Value,
        time: TimeCode = .default,
    ) raises UsdError:
        """Author a scalar/array without silently changing its USD type.

        Exact signed/unsigned 64-bit integers never pass through Float64.
        Shape, storage channel and narrowing ranges are checked before authoring.
        """
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        _validate_text(value.type_name)
        _validate_time(time)
        var type_name = value.type_name.copy()
        var _type_name_utf8 = _c_bytes(type_name)
        var handle = external_call["usdm_value_new", UInt64](
            _type_name_utf8.unsafe_ptr()
        )
        if not handle:
            raise _error()
        var owner = _ValueOwner(handle)
        _check(
            Int64(
                external_call["usdm_value_fill", c_int](
                    owner.handle,
                    value.numbers.unsafe_ptr(),
                    Int64(len(value.numbers)),
                    value.integers.unsafe_ptr(),
                    Int64(len(value.integers)),
                    value.unsigned_integers.unsafe_ptr(),
                    Int64(len(value.unsigned_integers)),
                )
            )
        )
        for text in value.texts:
            var owned = String(text)
            _validate_text(owned)
            var _owned_utf8 = _c_bytes(owned)
            _check(
                Int64(
                    external_call["usdm_value_add_text", c_int](
                        owner.handle, _owned_utf8.unsafe_ptr()
                    )
                )
            )
        _check(
            Int64(
                external_call["usdm_value_write", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _name_utf8.unsafe_ptr(),
                    time.value,
                    c_int(time.is_default),
                    owner.handle,
                )
            )
        )

    def add_reference(
        mut self,
        var path: String,
        var asset_path: String,
        var prim_path: String = "",
        offset: Float64 = 0,
        scale: Float64 = 1,
    ) raises UsdError:
        """Add an external or internal reference at the current edit target."""
        var _path_utf8 = _c_bytes(path)
        var _asset_path_utf8 = _c_bytes(asset_path)
        var _prim_path_utf8 = _c_bytes(prim_path)
        _validate_text(path)
        _validate_text(asset_path)
        _validate_text(prim_path)
        _check(
            Int64(
                external_call["usdm_add_reference", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _asset_path_utf8.unsafe_ptr(),
                    _prim_path_utf8.unsafe_ptr(),
                    offset,
                    scale,
                )
            )
        )

    def add_sublayer(
        mut self,
        var asset_path: String,
        offset: Float64 = 0,
        scale: Float64 = 1,
    ) raises UsdError:
        var _asset_path_utf8 = _c_bytes(asset_path)
        _validate_text(asset_path)
        _check(
            Int64(
                external_call["usdm_add_sublayer", c_int](
                    self._handle,
                    _asset_path_utf8.unsafe_ptr(),
                    offset,
                    scale,
                )
            )
        )

    def set_default_prim(mut self, var path: String) raises UsdError:
        var _path_utf8 = _c_bytes(path)
        _validate_text(path)
        _check(
            Int64(
                external_call["usdm_default_prim", c_int](
                    self._handle, _path_utf8.unsafe_ptr()
                )
            )
        )

    def select_variant(
        mut self,
        var path: String,
        var set_name: String,
        var choice: String,
        create: Bool = False,
    ) raises UsdError:
        var _path_utf8 = _c_bytes(path)
        var _set_name_utf8 = _c_bytes(set_name)
        var _choice_utf8 = _c_bytes(choice)
        _validate_text(path)
        _validate_text(set_name)
        _validate_text(choice)
        _check(
            Int64(
                external_call["usdm_variant", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _set_name_utf8.unsafe_ptr(),
                    _choice_utf8.unsafe_ptr(),
                    c_int(create),
                )
            )
        )

    def edit_variant(
        mut self, var path: String, var set_name: String
    ) raises UsdError:
        """Author into the selected variant until edit_root() is called."""
        var _path_utf8 = _c_bytes(path)
        var _set_name_utf8 = _c_bytes(set_name)
        _validate_text(path)
        _validate_text(set_name)
        _check(
            Int64(
                external_call["usdm_variant_edit", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _set_name_utf8.unsafe_ptr(),
                )
            )
        )

    def edit_root(mut self) raises UsdError:
        _check(Int64(external_call["usdm_root_edit", c_int](self._handle)))

    def add_relationship_target(
        mut self, var path: String, var name: String, var target: String
    ) raises UsdError:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        var _target_utf8 = _c_bytes(target)
        _validate_text(path)
        _validate_text(name)
        _validate_text(target)
        _check(
            Int64(
                external_call["usdm_relationship", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _name_utf8.unsafe_ptr(),
                    _target_utf8.unsafe_ptr(),
                    c_int(0),
                )
            )
        )

    def clear_relationship_targets(
        mut self, var path: String, var name: String
    ) raises UsdError:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        var empty = String("")
        var _empty_utf8 = _c_bytes(empty)
        _check(
            Int64(
                external_call["usdm_relationship", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _name_utf8.unsafe_ptr(),
                    _empty_utf8.unsafe_ptr(),
                    c_int(1),
                )
            )
        )

    def default_prim(self) raises UsdError -> String:
        return self._text(12)

    def material_path(
        self, var path: String, var purpose: String = ""
    ) raises UsdError -> String:
        """Resolve inherited SDK material bindings for all/preview/full purpose.
        """
        return self._text(10, path, purpose)

    def interpolation(
        self, var path: String, var name: String
    ) raises UsdError -> String:
        """Read authored interpolation metadata; an empty string means absent.
        """
        return self._text(11, path, name)

    def apply_schema(
        mut self,
        var path: String,
        var schema: String,
        var instance: String = "",
    ) raises UsdError:
        """Apply a registered single/multiple-apply API schema after SDK validation.
        """
        var _path_utf8 = _c_bytes(path)
        var _schema_utf8 = _c_bytes(schema)
        var _instance_utf8 = _c_bytes(instance)
        _validate_text(path)
        _validate_text(schema)
        _validate_text(instance)
        _check(
            Int64(
                external_call["usdm_apply_schema", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _schema_utf8.unsafe_ptr(),
                    _instance_utf8.unsafe_ptr(),
                )
            )
        )

    def _consume_strings(self, handle: UInt64) raises UsdError -> List[String]:
        if not handle:
            raise _error()
        var owner = _StringsOwner(handle)
        var count = external_call["usdm_strings_count", Int64](owner.handle)
        _check(count)
        var result = List[String](capacity=Int(count))
        for i in range(Int(count)):
            var needed = external_call["usdm_strings_text_size", Int64](
                owner.handle, Int64(i)
            )
            _check(needed)
            if needed < 1:
                raise UsdError(.internal, "Invalid string snapshot extent")
            var bytes = List[UInt8](length=Int(needed), fill=0)
            var copied = external_call["usdm_strings_text", Int64](
                owner.handle, Int64(i), bytes.unsafe_ptr(), needed
            )
            _check(copied)
            if copied != needed:
                raise UsdError(.internal, "String snapshot extent mismatch")
            result.append(String(unsafe_from_utf8_ptr=bytes.unsafe_ptr()))
        return result^

    def _information(
        self,
        kind: Int,
        path: String = "",
        name: String = "",
        key: String = "",
        dictionary: String = "",
    ) raises UsdError -> List[String]:
        _validate_text(path)
        _validate_text(name)
        _validate_text(key)
        _validate_text(dictionary)
        var p = _c_bytes(path)
        var n = _c_bytes(name)
        var k = _c_bytes(key)
        var d = _c_bytes(dictionary)
        return self._consume_strings(
            external_call["usdm_information", UInt64](
                self._handle,
                c_int(kind),
                p.unsafe_ptr(),
                n.unsafe_ptr(),
                k.unsafe_ptr(),
                d.unsafe_ptr(),
            )
        )

    def stage_info(self) raises UsdError -> StageInfo:
        var v = List[Float64](length=5, fill=0)
        _check(
            Int64(
                external_call["usdm_stage_info", c_int](
                    self._handle, v.unsafe_ptr(), Int64(5)
                )
            )
        )
        return StageInfo(v[0], v[1], v[2], v[3], Bool(v[4]))

    def set_time_range(
        mut self,
        start: Float64,
        end: Float64,
        time_codes_per_second: Float64 = 24,
        frames_per_second: Float64 = 24,
    ) raises UsdError:
        _check(
            Int64(
                external_call["usdm_time_range", c_int](
                    self._handle,
                    start,
                    end,
                    time_codes_per_second,
                    frames_per_second,
                )
            )
        )

    def prim_info(self, path: String) raises UsdError -> PrimInfo:
        _validate_text(path)
        var p = _c_bytes(path)
        var f = List[Int32](length=7, fill=0)
        _check(
            Int64(
                external_call["usdm_prim_flags", c_int](
                    self._handle, p.unsafe_ptr(), f.unsafe_ptr(), Int64(7)
                )
            )
        )
        var prototype = self._information(7, path)
        return PrimInfo(
            self.prim_type(path),
            Bool(f[0]),
            Bool(f[1]),
            Bool(f[2]),
            Bool(f[3]),
            Bool(f[4]),
            Bool(f[5]),
            Bool(f[6]),
            prototype[0],
        )

    def prototype_paths(self) raises UsdError -> List[String]:
        return self._information(2)

    def instance_paths(self) raises UsdError -> List[String]:
        """Default prim traversal with instance proxies expanded by the SDK."""
        return self._information(13)

    def all_prim_paths(self) raises UsdError -> List[String]:
        """SDK TraverseAll: includes inactive/undefined/abstract prims."""
        return self._information(14)

    def layer_identifiers(self) raises UsdError -> List[String]:
        return self._information(3)

    def loadable_paths(self) raises UsdError -> List[String]:
        return self._information(0)

    def loaded_paths(self) raises UsdError -> List[String]:
        return self._information(1)

    def set_payload_loaded(
        mut self, path: String, loaded: Bool
    ) raises UsdError:
        _validate_text(path)
        var p = _c_bytes(path)
        _check(
            Int64(
                external_call["usdm_payload", c_int](
                    self._handle, p.unsafe_ptr(), c_int(loaded)
                )
            )
        )

    def add_payload(
        mut self, path: String, asset: String, prim_path: String = ""
    ) raises UsdError:
        _validate_text(path)
        _validate_text(asset)
        _validate_text(prim_path)
        var p = _c_bytes(path)
        var a = _c_bytes(asset)
        var t = _c_bytes(prim_path)
        _check(
            Int64(
                external_call["usdm_add_payload", c_int](
                    self._handle, p.unsafe_ptr(), a.unsafe_ptr(), t.unsafe_ptr()
                )
            )
        )

    def set_instanceable(mut self, path: String, enabled: Bool) raises UsdError:
        _validate_text(path)
        var p = _c_bytes(path)
        _check(
            Int64(
                external_call["usdm_set_instanceable", c_int](
                    self._handle, p.unsafe_ptr(), c_int(enabled)
                )
            )
        )

    def variant_sets(self, path: String) raises UsdError -> List[String]:
        return self._information(4, path)

    def variant_names(
        self, path: String, set_name: String
    ) raises UsdError -> List[String]:
        return self._information(5, path, set_name)

    def variant_selection(
        self, path: String, set_name: String
    ) raises UsdError -> String:
        var value = self._information(6, path, set_name)
        return value[0]

    def composition_errors(self) raises UsdError -> List[String]:
        """SDK composition diagnostics, including unresolved composition arcs.
        """
        return self._information(12)

    def connections(
        self, path: String, name: String
    ) raises UsdError -> List[String]:
        return self._information(11, path, name)

    def attribute_type(
        self, path: String, name: String
    ) raises UsdError -> String:
        var result = self._information(8, path, name)
        return result[0]

    def time_samples(
        self, path: String, name: String
    ) raises UsdError -> List[Float64]:
        _validate_text(path)
        _validate_text(name)
        var p = _c_bytes(path)
        var n = _c_bytes(name)
        var handle = external_call["usdm_time_samples", UInt64](
            self._handle, p.unsafe_ptr(), n.unsafe_ptr()
        )
        if not handle:
            raise _error()
        var owner = _ArrayOwner(handle)
        var count = external_call["usdm_array_size", Int64](owner.handle)
        _check(count)
        var values = List[Float64](length=Int(count), fill=0)
        _check(
            Int64(
                external_call["usdm_array_copy", c_int](
                    owner.handle, values.unsafe_ptr(), count
                )
            )
        )
        return values^

    def asset_path(
        self,
        path: String,
        name: String,
        time: TimeCode = .default,
        index: Int = 0,
    ) raises UsdError -> AssetPathData:
        _validate_text(path)
        _validate_text(name)
        _validate_time(time)
        var p = _c_bytes(path)
        var n = _c_bytes(name)
        var v = self._consume_strings(
            external_call["usdm_asset_paths", UInt64](
                self._handle,
                p.unsafe_ptr(),
                n.unsafe_ptr(),
                time.value,
                c_int(time.is_default),
                Int64(index),
            )
        )
        return AssetPathData(v[0], v[1], v[2])

    def primvar_info(
        self, path: String, name: String
    ) raises UsdError -> PrimvarInfo:
        _validate_text(path)
        _validate_text(name)
        var p = _c_bytes(path)
        var n = _c_bytes(name)
        var v = List[Int64](length=2, fill=0)
        _check(
            Int64(
                external_call["usdm_primvar_info", c_int](
                    self._handle,
                    p.unsafe_ptr(),
                    n.unsafe_ptr(),
                    v.unsafe_ptr(),
                    Int64(2),
                )
            )
        )
        var interpolation = self._consume_text(
            external_call["usdm_primvar_interpolation", UInt64](
                self._handle, p.unsafe_ptr(), n.unsafe_ptr(), c_int(0)
            )
        )
        return PrimvarInfo(interpolation^, Int(v[0]), Int(v[1]))

    def normals_interpolation(self, path: String) raises UsdError -> String:
        _validate_text(path)
        var p = _c_bytes(path)
        var n = _c_bytes("")
        return self._consume_text(
            external_call["usdm_primvar_interpolation", UInt64](
                self._handle, p.unsafe_ptr(), n.unsafe_ptr(), c_int(1)
            )
        )

    def metadata_names(
        self, path: String = "", attribute: String = ""
    ) raises UsdError -> List[String]:
        """Empty path selects stage metadata; empty attribute selects prim metadata.
        """
        return self._information(9, path, attribute)

    def metadata_dictionary_keys(
        self,
        key: String,
        path: String = "",
        attribute: String = "",
        dictionary: String = "",
    ) raises UsdError -> List[String]:
        return self._information(10, path, attribute, key, dictionary)

    def read_metadata(
        self,
        key: String,
        path: String = "",
        attribute: String = "",
        dictionary: String = "",
    ) raises UsdError -> Value:
        """Read a supported typed metadata leaf; dictionaries use explicit keys.
        """
        _validate_text(path)
        _validate_text(attribute)
        _validate_text(key)
        _validate_text(dictionary)
        var p = _c_bytes(path)
        var a = _c_bytes(attribute)
        var k = _c_bytes(key)
        var d = _c_bytes(dictionary)
        return self._consume_value(
            external_call["usdm_metadata_read", UInt64](
                self._handle,
                p.unsafe_ptr(),
                a.unsafe_ptr(),
                k.unsafe_ptr(),
                d.unsafe_ptr(),
            )
        )

    def prim_paths(self) raises UsdError -> List[String]:
        """Active, defined, loaded, non-abstract prims; instances unexpanded."""
        var result = List[String]()
        var lines = self._text(0).split("\n")
        for line in lines:
            if line.byte_length():
                result.append(String(line))
        return result^

    def prim_type(self, var path: String) raises UsdError -> String:
        return self._text(1, path)

    def applied_schemas(self, var path: String) raises UsdError -> List[String]:
        var result = List[String]()
        var lines = self._text(5, path).split("\n")
        for line in lines:
            if line.byte_length():
                result.append(String(line))
        return result^

    def has_schema(
        self, var path: String, name: String
    ) raises UsdError -> Bool:
        var schemas = self.applied_schemas(path)
        for schema in schemas:
            if schema == name:
                return True
        return False

    def relationship_names(
        self, var path: String
    ) raises UsdError -> List[String]:
        var result = List[String]()
        var lines = self._text(6, path).split("\n")
        for line in lines:
            if line.byte_length():
                result.append(String(line))
        return result^

    def relationship_targets(
        self, var path: String, var name: String
    ) raises UsdError -> List[String]:
        """Composed and forwarded targets, owning their path strings."""
        var result = List[String]()
        var lines = self._text(7, path, name).split("\n")
        for line in lines:
            if line.byte_length():
                result.append(String(line))
        return result^

    def physics_material_path(self, var path: String) raises UsdError -> String:
        """Resolve inherited physics-purpose material binding through the SDK.
        """
        return self._text(8, path)

    def closest_schema(
        self, var path: String, var schema: String
    ) raises UsdError -> String:
        """Nearest ancestor (including self) carrying the applied API schema."""
        return self._text(9, path, schema)

    def is_instance(self, var path: String) raises UsdError -> Bool:
        var _path_utf8 = _c_bytes(path)
        _validate_text(path)
        var status = external_call["usdm_prim_instance", c_int](
            self._handle, _path_utf8.unsafe_ptr()
        )
        _check(Int64(status))
        return Bool(status)

    def has_attribute(
        self, var path: String, var name: String
    ) raises UsdError -> Bool:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        var status = external_call["usdm_attr_state", c_int](
            self._handle,
            _path_utf8.unsafe_ptr(),
            _name_utf8.unsafe_ptr(),
            c_int(0),
        )
        _check(Int64(status))
        return Bool(status)

    def has_authored_value(
        self, var path: String, var name: String
    ) raises UsdError -> Bool:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        var status = external_call["usdm_attr_state", c_int](
            self._handle,
            _path_utf8.unsafe_ptr(),
            _name_utf8.unsafe_ptr(),
            c_int(1),
        )
        _check(Int64(status))
        return Bool(status)

    def kilograms_per_unit(self) raises UsdError -> Float64:
        var value = List[Float64](length=1, fill=0)
        _check(
            Int64(
                external_call["usdm_kilograms_per_unit", c_int](
                    self._handle, value.unsafe_ptr()
                )
            )
        )
        return value[0]

    def _components(
        self,
        var path: String,
        var name: String,
        kind: Int,
        count: Int,
        time: TimeCode,
    ) raises UsdError -> List[Float64]:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        _validate_time(time)
        var values = List[Float64](length=count, fill=0)
        _check(
            Int64(
                external_call["usdm_components", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _name_utf8.unsafe_ptr(),
                    time.value,
                    c_int(time.is_default),
                    c_int(kind),
                    values.unsafe_ptr(),
                    Int64(count),
                )
            )
        )
        return values^

    def read_vector3(
        self, var path: String, var name: String, time: TimeCode = .default
    ) raises UsdError -> Vector3:
        var v = self._components(path, name, 0, 3, time)
        return Vector3(v[0], v[1], v[2])

    def read_quaternion(
        self, var path: String, var name: String, time: TimeCode = .default
    ) raises UsdError -> Quaternion:
        var q = self._components(path, name, 1, 4, time)
        return Quaternion(q[0], q[1], q[2], q[3])

    def read_matrix4(
        self, var path: String, var name: String, time: TimeCode = .default
    ) raises UsdError -> List[Float64]:
        return self._components(path, name, 2, 16, time)

    def transform(
        self, var path: String, time: TimeCode = .default
    ) raises UsdError -> TransformData:
        var _path_utf8 = _c_bytes(path)
        _validate_text(path)
        _validate_time(time)
        var v = List[Float64](length=10, fill=0)
        _check(
            Int64(
                external_call["usdm_transform", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    time.value,
                    c_int(time.is_default),
                    v.unsafe_ptr(),
                    Int64(10),
                )
            )
        )
        return TransformData(
            Vector3(v[0], v[1], v[2]),
            Quaternion(v[3], v[4], v[5], v[6]),
            Vector3(v[7], v[8], v[9]),
        )

    def _numeric_array(
        self, var path: String, var name: String, kind: Int, time: TimeCode
    ) raises UsdError -> List[Float64]:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        _validate_time(time)
        var handle = external_call["usdm_array_snapshot", UInt64](
            self._handle,
            _path_utf8.unsafe_ptr(),
            _name_utf8.unsafe_ptr(),
            time.value,
            c_int(time.is_default),
            c_int(kind),
        )
        if not handle:
            raise _error()
        var owner = _ArrayOwner(handle)
        var count = external_call["usdm_array_size", Int64](owner.handle)
        _check(count)
        var values = List[Float64](length=Int(count), fill=0)
        _check(
            Int64(
                external_call["usdm_array_copy", c_int](
                    owner.handle, values.unsafe_ptr(), count
                )
            )
        )
        return values^

    def read_float_array(
        self, var path: String, var name: String, time: TimeCode = .default
    ) raises UsdError -> List[Float64]:
        return self._numeric_array(path, name, 0, time)

    def read_int_array(
        self, var path: String, var name: String, time: TimeCode = .default
    ) raises UsdError -> List[Int32]:
        var values = self._numeric_array(path, name, 1, time)
        var result = List[Int32](capacity=len(values))
        for value in values:
            result.append(Int32(value))
        return result^

    def read_vector3_array(
        self, var path: String, var name: String, time: TimeCode = .default
    ) raises UsdError -> List[Vector3]:
        var values = self._numeric_array(path, name, 2, time)
        var result = List[Vector3](capacity=len(values) // 3)
        for i in range(len(values) // 3):
            result.append(
                Vector3(values[3 * i], values[3 * i + 1], values[3 * i + 2])
            )
        return result^

    def attribute_names(self, var path: String) raises UsdError -> List[String]:
        """Composed attributes including schema fallback properties."""
        var result = List[String]()
        var lines = self._text(2, path).split("\n")
        for line in lines:
            if line.byte_length():
                result.append(String(line))
        return result^

    def read_text(
        self, var path: String, var name: String, time: TimeCode = .default
    ) raises UsdError -> String:
        """Read a string or token value; unsupported types raise an error."""
        return self._text(3, path, name, time)

    def up_axis(self) raises UsdError -> String:
        return self._text(4)

    def meters_per_unit(self) raises UsdError -> Float64:
        var value = List[Float64](length=1, fill=0)
        _check(
            Int64(
                external_call["usdm_meters_per_unit", c_int](
                    self._handle, value.unsafe_ptr()
                )
            )
        )
        return value[0]

    def read_float(
        self, var path: String, var name: String, time: TimeCode = .default
    ) raises UsdError -> Float64:
        """Read a float or double attribute, retaining Float64 precision."""
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        _validate_time(time)
        var value = List[Float64](length=1, fill=0)
        _check(
            Int64(
                external_call["usdm_read_float", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _name_utf8.unsafe_ptr(),
                    time.value,
                    c_int(time.is_default),
                    value.unsafe_ptr(),
                )
            )
        )
        return value[0]

    def time_codes_per_second(self) raises UsdError -> Float64:
        """Composed stage rate for converting seconds to numeric time codes."""
        var value = List[Float64](length=1, fill=0)
        _check(
            Int64(
                external_call["usdm_time_codes_per_second", c_int](
                    self._handle, value.unsafe_ptr()
                )
            )
        )
        return value[0]

    def read_bool(
        self, var path: String, var name: String, time: TimeCode = .default
    ) raises UsdError -> Bool:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        _validate_time(time)
        var value = List[c_int](length=1, fill=0)
        _check(
            Int64(
                external_call["usdm_read_bool", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _name_utf8.unsafe_ptr(),
                    time.value,
                    c_int(time.is_default),
                    value.unsafe_ptr(),
                )
            )
        )
        return Bool(value[0])

    def set_float(
        mut self,
        var path: String,
        var name: String,
        value: Float64,
        time: TimeCode = .default,
    ) raises UsdError:
        """Author a float/double; create a custom double if missing."""
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        _validate_time(time)
        _check(
            Int64(
                external_call["usdm_set_float", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _name_utf8.unsafe_ptr(),
                    time.value,
                    c_int(time.is_default),
                    value,
                )
            )
        )

    def set_bool(
        mut self,
        var path: String,
        var name: String,
        value: Bool,
        time: TimeCode = .default,
    ) raises UsdError:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        _validate_text(path)
        _validate_text(name)
        _validate_time(time)
        _check(
            Int64(
                external_call["usdm_set_bool", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _name_utf8.unsafe_ptr(),
                    time.value,
                    c_int(time.is_default),
                    c_int(value),
                )
            )
        )

    def set_text(
        mut self,
        var path: String,
        var name: String,
        var value: String,
        time: TimeCode = .default,
    ) raises UsdError:
        var _path_utf8 = _c_bytes(path)
        var _name_utf8 = _c_bytes(name)
        var _value_utf8 = _c_bytes(value)
        _validate_text(path)
        _validate_text(name)
        _validate_text(value)
        _validate_time(time)
        _check(
            Int64(
                external_call["usdm_set_text", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _name_utf8.unsafe_ptr(),
                    time.value,
                    c_int(time.is_default),
                    _value_utf8.unsafe_ptr(),
                )
            )
        )

    def define_prim(
        mut self, var path: String, var type_name: String = ""
    ) raises UsdError:
        """Define ancestors as needed and assign the supplied schema type."""
        var _path_utf8 = _c_bytes(path)
        var _type_name_utf8 = _c_bytes(type_name)
        _validate_text(path)
        _validate_text(type_name)
        _check(
            Int64(
                external_call["usdm_define_prim", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    _type_name_utf8.unsafe_ptr(),
                )
            )
        )

    def save(mut self) raises UsdError:
        """Save the root layer with its composition arcs and overrides."""
        _check(Int64(external_call["usdm_stage_save", c_int](self._handle)))

    def export(self, var filename: String) raises UsdError:
        """Export the composed, flattened stage; preserves scene values."""
        var _filename_utf8 = _c_bytes(filename)
        _validate_text(filename)
        _check(
            Int64(
                external_call["usdm_stage_export", c_int](
                    self._handle, _filename_utf8.unsafe_ptr()
                )
            )
        )

    def world_transform(
        self, var path: String, time: TimeCode = .default
    ) raises UsdError -> List[Float64]:
        """16 row-major values of USD's row-vector local-to-world matrix.

        Translation is in elements 12, 13, 14; values retain stage units.
        Numeric time codes are frames, not seconds.
        """
        var _path_utf8 = _c_bytes(path)
        _validate_text(path)
        _validate_time(time)
        var values = List[Float64](length=16, fill=0)
        _check(
            Int64(
                external_call["usdm_world_transform", c_int](
                    self._handle,
                    _path_utf8.unsafe_ptr(),
                    time.value,
                    c_int(time.is_default),
                    values.unsafe_ptr(),
                    Int64(16),
                )
            )
        )
        return values^

    def mesh_snapshot(
        self, path: String, time: TimeCode = .default
    ) raises UsdError -> MeshSnapshot:
        """Own a validated snapshot whose views borrow the snapshot, not the stage.
        """
        return MeshSnapshot(self, path, time)

    def mesh(
        self, var path: String, time: TimeCode = .default
    ) raises UsdError -> MeshData:
        """Return independent mutable points and topology copied from one snapshot.
        """
        var snapshot = self.mesh_snapshot(path, time)
        return snapshot.materialize()


struct MeshSnapshot(Movable):
    """Move-only SDK-array owner with read-only, compiler-tracked native views.

    The stage can close or be edited after capture. This snapshot keeps its own
    array references. Views must not outlive or be used after moving their owner.
    Raw addresses are private; mutating SDK storage through unsafe pointers is
    outside this API. A snapshot is not used concurrently across threads.
    """

    var _handle: UInt64
    var _point_components: Int
    var _counts: Int
    var _indices: Int
    var _points_address: UInt64
    var _counts_address: UInt64
    var _indices_address: UInt64

    def __init__(
        out self, stage: Stage, path: String, time: TimeCode = .default
    ) raises UsdError:
        self._handle = 0
        self._point_components = 0
        self._counts = 0
        self._indices = 0
        self._points_address = 0
        self._counts_address = 0
        self._indices_address = 0
        _validate_text(path)
        _validate_time(time)
        var bytes = _c_bytes(path)
        self._handle = external_call["usdm_mesh_snapshot", UInt64](
            stage._handle,
            bytes.unsafe_ptr(),
            time.value,
            c_int(time.is_default),
        )
        if not self._handle:
            raise _error()
        var metadata = Array[UInt64, 6]()
        var status = external_call["usdm_mesh_metadata", c_int](
            self._handle, metadata.unsafe_ptr(), Int64(6)
        )
        if status < 0:
            var failure = _error()
            external_call["usdm_mesh_close", NoneType](self._handle)
            self._handle = 0
            raise failure^
        self._point_components = Int(metadata[0])
        self._counts = Int(metadata[1])
        self._indices = Int(metadata[2])
        self._points_address = metadata[3]
        self._counts_address = metadata[4]
        self._indices_address = metadata[5]

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle
        self._point_components = move._point_components
        self._counts = move._counts
        self._indices = move._indices
        self._points_address = move._points_address
        self._counts_address = move._counts_address
        self._indices_address = move._indices_address

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_mesh_close", NoneType](self._handle)

    def _size(self, kind: Int) raises UsdError -> Int:
        if kind == 0:
            return self._point_components
        if kind == 1:
            return self._counts
        return self._indices

    def point_count(self) raises UsdError -> Int:
        return self._size(0) // 3

    def face_count(self) raises UsdError -> Int:
        return self._size(1)

    def points(self) raises UsdError -> ImmSpan[Float32, origin_of(self)]:
        var count = self._size(0)
        var address = self._points_address
        var pointer = Pointer[Float32, origin_of(self)](
            unsafe_from_address=Int(address)
        )
        return ImmSpan(unsafe_ptr=pointer, length=count)

    def face_vertex_counts(
        self,
    ) raises UsdError -> ImmSpan[Int32, origin_of(self)]:
        var count = self._size(1)
        var address = self._counts_address
        var pointer = Pointer[Int32, origin_of(self)](
            unsafe_from_address=Int(address)
        )
        return ImmSpan(unsafe_ptr=pointer, length=count)

    def face_vertex_indices(
        self,
    ) raises UsdError -> ImmSpan[Int32, origin_of(self)]:
        var count = self._size(2)
        var address = self._indices_address
        var pointer = Pointer[Int32, origin_of(self)](
            unsafe_from_address=Int(address)
        )
        return ImmSpan(unsafe_ptr=pointer, length=count)

    def copy_into(
        self,
        points: MutSpan[Float32, _],
        counts: MutSpan[Int32, _],
        indices: MutSpan[Int32, _],
    ) raises UsdError:
        """Write to exact-sized, disjoint caller buffers; validate before any write.
        """
        _check(
            Int64(
                external_call["usdm_mesh_copy", c_int](
                    self._handle,
                    points.unsafe_ptr(),
                    Int64(len(points)),
                    counts.unsafe_ptr(),
                    Int64(len(counts)),
                    indices.unsafe_ptr(),
                    Int64(len(indices)),
                )
            )
        )

    def materialize(self) raises UsdError -> MeshData:
        var points = List[Float32](length=self._size(0), fill=0)
        var counts = List[Int32](length=self._size(1), fill=0)
        var indices = List[Int32](length=self._size(2), fill=0)
        self.copy_into(MutSpan(points), MutSpan(counts), MutSpan(indices))
        return MeshData(points^, counts^, indices^)


struct _ArrayOwner(Movable):
    var handle: UInt64

    def __init__(out self, handle: UInt64):
        self.handle = handle

    def __init__(out self, *, deinit move: Self):
        self.handle = move.handle

    def __deinit__(deinit self):
        external_call["usdm_array_close", NoneType](self.handle)


struct _ValueOwner(Movable):
    var handle: UInt64

    def __init__(out self, handle: UInt64):
        self.handle = handle

    def __init__(out self, *, deinit move: Self):
        self.handle = move.handle

    def __deinit__(deinit self):
        if self.handle:
            external_call["usdm_value_close", NoneType](self.handle)


struct _TextOwner(Movable):
    var handle: UInt64

    def __init__(out self, handle: UInt64):
        self.handle = handle

    def __init__(out self, *, deinit move: Self):
        self.handle = move.handle

    def __deinit__(deinit self):
        if self.handle:
            external_call["usdm_text_close", NoneType](self.handle)


struct _StringsOwner(Movable):
    var handle: UInt64

    def __init__(out self, handle: UInt64):
        self.handle = handle

    def __init__(out self, *, deinit move: Self):
        self.handle = move.handle

    def __deinit__(deinit self):
        if self.handle:
            external_call["usdm_strings_close", NoneType](self.handle)
