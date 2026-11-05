# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Native immutable numeric array views, without the generic Value conversion."""
from std.ffi import c_int, external_call
from std.collections import Array, ImmSpan
from std.memory import Pointer
from .stage import Stage, TimeCode, _validate_time
from .errors import UsdError
from ._bridge import _c_bytes, _error, _take_text, _check


def _component_kind[dtype: DType]() -> Int:
    if dtype == DType.uint8:
        return 1
    if dtype == DType.int32:
        return 2
    if dtype == DType.uint32:
        return 3
    if dtype == DType.int64:
        return 4
    if dtype == DType.uint64:
        return 5
    if dtype == DType.float16:
        return 6
    if dtype == DType.float32:
        return 7
    if dtype == DType.float64:
        return 8
    return 0


struct ArraySnapshot(Movable):
    """Own SDK COW array storage and lend packed numeric components.

    SDK resolution/decompression can allocate. The returned host view itself
    neither converts components nor copies their buffer. GPU uploads are separate.
    Strings, assets and quaternions use the generic Value reader instead.
    """

    var _handle: UInt64
    var _kind: UInt64
    var _count: Int
    var _address: UInt64
    var type_name: String
    var element_count: Int
    var components_per_element: Int
    var byte_count: Int

    def __init__(
        out self,
        stage: Stage,
        path: String,
        name: String,
        time: TimeCode = .default,
    ) raises UsdError:
        self._handle = 0
        self._kind = 0
        self._count = 0
        self._address = 0
        self.type_name = ""
        self.element_count = 0
        self.components_per_element = 0
        self.byte_count = 0
        _validate_time(time)
        var p = _c_bytes(path)
        var n = _c_bytes(name)
        self._handle = external_call["usdm_native_array", UInt64](
            stage._handle,
            p.unsafe_ptr(),
            n.unsafe_ptr(),
            time.value,
            c_int(time.is_default),
        )
        if not self._handle:
            raise _error()
        try:
            var info = Array[UInt64, 7]()
            if (
                external_call["usdm_native_array_info", c_int](
                    self._handle, info.unsafe_ptr(), Int64(7)
                )
                < 0
            ):
                raise _error()
            self.type_name = _take_text(
                external_call["usdm_native_array_type", UInt64](self._handle)
            )
            self._kind = info[0]
            self.element_count = Int(info[1])
            self.components_per_element = Int(info[2])
            self._count = Int(info[3])
            self.byte_count = Int(info[4])
            self._address = info[5]
        except error:
            external_call["usdm_native_array_close", NoneType](self._handle)
            self._handle = 0
            raise error^

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle
        self._kind = move._kind
        self._count = move._count
        self._address = move._address
        self.type_name = move.type_name^
        self.element_count = move.element_count
        self.components_per_element = move.components_per_element
        self.byte_count = move.byte_count

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_native_array_close", NoneType](self._handle)

    def view[
        dtype: DType
    ](self) raises UsdError -> ImmSpan[Scalar[dtype], origin_of(self)]:
        comptime kind = _component_kind[dtype]()
        if kind == 0 or self._kind != UInt64(kind):
            raise UsdError(
                .type_mismatch,
                "Requested component dtype differs from the USD array storage",
            )
        return ImmSpan(
            unsafe_ptr=Pointer[Scalar[dtype], origin_of(self)](
                unsafe_from_address=Int(self._address)
            ),
            length=self._count,
        )


def set_array[
    dtype: DType
](
    mut stage: Stage,
    path: String,
    name: String,
    type_name: String,
    values: ImmSpan[Scalar[dtype], _],
    time: TimeCode = .default,
) raises UsdError:
    """Copy packed host components once into SDK-owned storage, then author them.

    No Float64 promotion is used. The caller's buffer can be released or changed
    after return. This is an explicit copy, not a borrowed writable USD buffer.
    """
    comptime kind = _component_kind[dtype]()
    if kind == 0:
        raise UsdError(.unsupported, "Unsupported native array component dtype")
    _validate_time(time)
    var p = _c_bytes(path)
    var n = _c_bytes(name)
    var t = _c_bytes(type_name)
    _check(
        Int64(
            external_call["usdm_native_array_write", c_int](
                stage._handle,
                p.unsafe_ptr(),
                n.unsafe_ptr(),
                t.unsafe_ptr(),
                values.unsafe_ptr(),
                Int64(len(values)),
                UInt64(kind),
                time.value,
                c_int(time.is_default),
            )
        )
    )
