# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Internal owning C ABI buffers and error transfer."""
from std.ffi import c_int, external_call
from .errors import UsdError, UsdErrorKind
from .value import Value


def _c_bytes(value: String) raises UsdError -> List[UInt8]:
    """Own a NUL-terminated UTF-8 buffer across the C call, including empty text.

    A temporary CStringSpan may own its terminator; extracting its raw pointer
    does not keep that temporary alive on every pinned compiler/host combination.
    """
    var result = List[UInt8](length=value.byte_length() + 1, fill=0)
    var i = 0
    for byte in value.bytes():
        if byte == 0:
            raise UsdError(
                .invalid_argument, "USD text must not contain NUL bytes"
            )
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

    def __init__(out self, values: List[String]) raises UsdError:
        self.handle = 0
        var owner = _StringsOwner(external_call["usdm_strings_new", UInt64]())
        if not owner.handle:
            raise _error()
        for value in values:
            var data = _c_bytes(String(value))
            _check(
                Int64(external_call["usdm_strings_append", c_int](
                    owner.handle, data.unsafe_ptr()
                ))
            )
        self.handle = owner.handle
        owner.handle = 0

    def __init__(out self, *, deinit move: Self):
        self.handle = move.handle

    def __deinit__(deinit self):
        if self.handle:
            external_call["usdm_strings_close", NoneType](self.handle)


def _take_text(handle: UInt64) raises UsdError -> String:
    if not handle:
        raise _error()
    var owner = _TextOwner(handle)
    var needed = external_call["usdm_snapshot_text_size", Int64](owner.handle)
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


def _value_text(handle: UInt64, index: Int) raises UsdError -> String:
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


def _take_value(handle: UInt64) raises UsdError -> Value:
    if not handle:
        raise _error()
    var owner = _ValueOwner(handle)
    var result = Value(_value_text(owner.handle, -1))
    var nc = external_call["usdm_value_count", Int64](owner.handle, c_int(0))
    var ic = external_call["usdm_value_count", Int64](owner.handle, c_int(1))
    var uc = external_call["usdm_value_count", Int64](owner.handle, c_int(2))
    var tc = external_call["usdm_value_count", Int64](owner.handle, c_int(3))
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
        result.texts.append(_value_text(owner.handle, i))
    return result^


def _take_strings(handle: UInt64) raises UsdError -> List[String]:
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


def _make_value(value: Value) raises UsdError -> _ValueOwner:
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
        var _owned_utf8 = _c_bytes(owned)
        _check(
            Int64(
                external_call["usdm_value_add_text", c_int](
                    owner.handle, _owned_utf8.unsafe_ptr()
                )
            )
        )
    return owner^
