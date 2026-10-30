# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Bounded change invalidation and frozen, owned scenes for runtime handoff."""
from std.ffi import c_int, external_call
from std.collections import Array, ImmSpan
from std.memory import Pointer
from .stage import Stage, TimeCode, _validate_time
from .errors import UsdError
from .value import Value
from ._bridge import (
    _c_bytes,
    _take_strings,
    _take_value,
    _error,
    _check,
)


@fieldwise_init
struct ChangeSet(Copyable):
    var generation: UInt64
    var all_dirty: Bool
    var resynced: List[String]
    var changed: List[String]


struct _ChangeOwner(Movable):
    var handle: UInt64

    def __init__(out self, stage: Stage) raises UsdError:
        self.handle = external_call["usdm_changes", UInt64](stage._handle)
        if not self.handle:
            raise _error()

    def __init__(out self, *, deinit move: Self):
        self.handle = move.handle

    def __deinit__(deinit self):
        external_call["usdm_changes_close", NoneType](self.handle)


def poll_changes(mut stage: Stage) raises UsdError -> ChangeSet:
    """Consume notices since the last poll. all_dirty requires a full refresh.

    Generation counts SDK notices, not edit transactions. Notice buffering is
    bounded at 8192 paths; allocation failure also requests a full refresh.
    """
    var native = _ChangeOwner(stage)
    var info = Array[UInt64, 2]()
    _check(
        Int64(
            external_call["usdm_changes_info", c_int](
                native.handle, info.unsafe_ptr(), Int64(2)
            )
        )
    )
    var resynced = _take_strings(
        external_call["usdm_changes_paths", UInt64](native.handle, c_int(0))
    )
    var changed = _take_strings(
        external_call["usdm_changes_paths", UInt64](native.handle, c_int(1))
    )
    var result = ChangeSet(info[0], Bool(info[1]), resynced^, changed^)
    _check(Int64(external_call["usdm_changes_ack", c_int](stage._handle)))
    return result^


struct SceneSnapshot(Movable):
    """Frozen working set with contiguous, borrowed float64 world matrices.

    Captures session opinions and selected variants/payloads. Original layer
    provenance remains on the source Stage. The snapshot owns CPU storage;
    transferring it to a GPU belongs to the runtime adapter.
    Unregistered metadata requires its schema plugin or an explicit population
    mask excluding those objects; flattening must not silently discard it.
    """

    var _handle: UInt64
    var generation: UInt64
    var _count: Int
    var _address: UInt64

    def __init__(
        out self, stage: Stage, time: TimeCode = .default
    ) raises UsdError:
        self._handle = 0
        self.generation = 0
        self._count = 0
        self._address = 0
        _validate_time(time)
        self._handle = external_call["usdm_scene_snapshot", UInt64](
            stage._handle, time.value, c_int(time.is_default)
        )
        if not self._handle:
            raise _error()
        var info = Array[UInt64, 3]()
        var status = external_call["usdm_scene_info", c_int](
            self._handle, info.unsafe_ptr(), Int64(3)
        )
        if status < 0:
            var error = _error()
            external_call["usdm_scene_close", NoneType](self._handle)
            self._handle = 0
            raise error^
        self.generation = info[0]
        self._count = Int(info[1])
        self._address = info[2]

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle
        self.generation = move.generation
        self._count = move._count
        self._address = move._address

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_scene_close", NoneType](self._handle)

    def _paths(self, kind: Int) raises UsdError -> List[String]:
        return _take_strings(
            external_call["usdm_scene_paths", UInt64](self._handle, c_int(kind))
        )

    def paths(self) raises UsdError -> List[String]:
        return self._paths(0)

    def types(self) raises UsdError -> List[String]:
        return self._paths(1)

    def prototypes(self) raises UsdError -> List[String]:
        return self._paths(2)

    def transforms(self) -> ImmSpan[Float64, origin_of(self)]:
        return ImmSpan(
            unsafe_ptr=Pointer[Float64, origin_of(self)](
                unsafe_from_address=Int(self._address)
            ),
            length=self._count,
        )

    def value(
        self, path: String, name: String, time: TimeCode = .default
    ) raises UsdError -> Value:
        _validate_time(time)
        var p = _c_bytes(path)
        var n = _c_bytes(name)
        return _take_value(
            external_call["usdm_scene_value", UInt64](
                self._handle,
                p.unsafe_ptr(),
                n.unsafe_ptr(),
                time.value,
                c_int(time.is_default),
            )
        )

    def export(self, filename: String) raises UsdError:
        var p = _c_bytes(filename)
        _check(
            Int64(
                external_call["usdm_scene_export", c_int](
                    self._handle, p.unsafe_ptr()
                )
            )
        )
