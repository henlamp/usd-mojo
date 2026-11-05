# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Owned SDK resolver contexts; plugin-defined context syntax stays with Ar."""
from std.ffi import external_call
from .errors import UsdError
from ._bridge import _c_bytes, _StringsOwner, _error


struct ResolverContext(Movable):
    var _handle: UInt64

    def __init__(out self, paths: List[String]) raises UsdError:
        """Create an ArDefaultResolverContext from explicit search directories.
        """
        var data = _StringsOwner(paths)
        var empty = _c_bytes("")
        self._handle = external_call["usdm_context_open", UInt64](
            data.handle, empty.unsafe_ptr()
        )
        if not self._handle:
            raise _error()

    def __init__(out self, configuration: String) raises UsdError:
        """Delegate context parsing to the active SDK resolver/plugin."""
        self._handle = 0
        var data = _c_bytes(configuration)
        self._handle = external_call["usdm_context_open", UInt64](
            UInt64(0), data.unsafe_ptr()
        )
        if not self._handle:
            raise _error()

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_context_close", NoneType](self._handle)
