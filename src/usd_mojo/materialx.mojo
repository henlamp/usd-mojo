# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Optional C++ MaterialX documents, GLSL/MSL shaders and Metal CPU readback."""
from std.collections import Array, ImmSpan
from std.memory import Pointer
from std.ffi import c_int, external_call
from .errors import UsdError, UsdErrorKind
from ._bridge import _c_bytes


def _mx_error() -> UsdError:
    var kind = UsdErrorKind(Int(external_call["usdm_mx_error_kind", c_int]()))
    var probe = Array[UInt8, 1]()
    var size = external_call["usdm_mx_error", Int64](probe.unsafe_ptr(), Int64(0))
    if size <= 0:
        return UsdError(.internal, "Cannot read MaterialX error")
    var data = List[UInt8](length=Int(size), fill=0)
    if external_call["usdm_mx_error", Int64](data.unsafe_ptr(), size) != size:
        return UsdError(.internal, "Cannot copy MaterialX error")
    return UsdError(kind, String(unsafe_from_utf8_ptr=data.unsafe_ptr()))


def _mx_check(status: Int64) raises UsdError:
    if status < 0:
        raise _mx_error()


struct _MxResult(Movable):
    var handle: UInt64

    def __init__(out self, handle: UInt64) raises UsdError:
        self.handle = handle
        if not handle:
            raise _mx_error()

    def __init__(out self, *, deinit move: Self):
        self.handle = move.handle

    def __deinit__(deinit self):
        external_call["usdm_mx_result_close", NoneType](self.handle)


def _mx_strings(handle: UInt64) raises UsdError -> List[String]:
    var owner = _MxResult(handle)
    var count = external_call["usdm_mx_result_count", Int64](owner.handle)
    _mx_check(count)
    var result = List[String](capacity=Int(count))
    var probe = Array[UInt8, 1]()
    for i in range(Int(count)):
        var size = external_call["usdm_mx_result_text", Int64](
            owner.handle, Int64(i), probe.unsafe_ptr(), Int64(0)
        )
        _mx_check(size)
        var data = List[UInt8](length=Int(size), fill=0)
        _mx_check(
            external_call["usdm_mx_result_text", Int64](
                owner.handle, Int64(i), data.unsafe_ptr(), size
            )
        )
        result.append(String(unsafe_from_utf8_ptr=data.unsafe_ptr()))
    return result^


struct MaterialXDocument(Movable):
    """Owned SDK document and standard library. File access uses SDK search paths.

    XML version upgrades follow MaterialX. The source file changes only on save.
    Instances are not shared concurrently. Generated shaders own their state.
    """

    var _handle: UInt64

    def __init__(out self, filename: String, library_path: String) raises UsdError:
        self._handle = 0
        var f = _c_bytes(filename)
        var p = _c_bytes(library_path)
        self._handle = external_call["usdm_mx_open", UInt64](
            f.unsafe_ptr(), p.unsafe_ptr()
        )
        if not self._handle:
            raise _mx_error()

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_mx_close", NoneType](self._handle)

    def _query(self, kind: Int) raises UsdError -> List[String]:
        return _mx_strings(
            external_call["usdm_mx_query", UInt64](self._handle, c_int(kind))
        )

    def validate(self) raises UsdError -> List[String]:
        """SDK diagnostics; an empty list means the document validates."""
        return self._query(0)

    def renderables(self) raises UsdError -> List[String]:
        return self._query(1)

    def content(self) raises UsdError -> String:
        var result = self._query(2)
        return result[0]

    def nodes(self) raises UsdError -> List[String]:
        return self._query(3)

    def set_input(
        mut self, node: String, name: String, type_name: String, value: String
    ) raises UsdError:
        var n = _c_bytes(node)
        var k = _c_bytes(name)
        var t = _c_bytes(type_name)
        var v = _c_bytes(value)
        _mx_check(
            Int64(
                external_call["usdm_mx_set_input", c_int](
                    self._handle,
                    n.unsafe_ptr(),
                    k.unsafe_ptr(),
                    t.unsafe_ptr(),
                    v.unsafe_ptr(),
                )
            )
        )

    def save(self, filename: String) raises UsdError:
        var f = _c_bytes(filename)
        _mx_check(
            Int64(external_call["usdm_mx_save", c_int](self._handle, f.unsafe_ptr()))
        )

    def shader(
        self, element: String, *, target: String = "msl"
    ) raises UsdError -> MaterialXShader:
        return MaterialXShader(self, element, target=target)


struct MaterialXShader(Movable):
    """SDK-generated shader, independent of later document edits or closure."""

    var _handle: UInt64

    def __init__(
        out self,
        document: MaterialXDocument,
        element: String,
        *,
        target: String = "msl",
    ) raises UsdError:
        self._handle = 0
        var e = _c_bytes(element)
        var t = _c_bytes(target)
        self._handle = external_call["usdm_mx_shader", UInt64](
            document._handle, e.unsafe_ptr(), t.unsafe_ptr()
        )
        if not self._handle:
            raise _mx_error()

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_mx_shader_close", NoneType](self._handle)

    def source(self, stage: String = "pixel") raises UsdError -> String:
        var s = _c_bytes(stage)
        var values = _mx_strings(
            external_call["usdm_mx_shader_source", UInt64](self._handle, s.unsafe_ptr())
        )
        return values[0]

    def render(self, width: Int, height: Int) raises UsdError -> MaterialXImage:
        return MaterialXImage(self, width, height)


struct MaterialXImage(Movable):
    """Owned Float32 RGBA texture-space readback. Render on the main thread.

    This uses the MaterialX Metal renderer, separately from Hydra. MaterialX's
    platform helper owns a hidden window. Images contain no borrowed GPU resource.
    """

    var _handle: UInt64
    var _count: Int
    var _address: UInt64
    var width: Int
    var height: Int

    def __init__(
        out self, shader: MaterialXShader, width: Int, height: Int
    ) raises UsdError:
        self._handle = 0
        self._count = 0
        self._address = 0
        self.width = 0
        self.height = 0
        if (
            width <= 0
            or height <= 0
            or width > 8192
            or height > 8192
            or width * height > 16777216
        ):
            raise UsdError(.invalid_argument, "Image exceeds 16 megapixels")
        self._handle = external_call["usdm_mx_render", UInt64](
            shader._handle, c_int(width), c_int(height)
        )
        if not self._handle:
            raise _mx_error()
        var info = Array[UInt64, 4]()
        if (
            external_call["usdm_mx_image_info", c_int](
                self._handle, info.unsafe_ptr(), Int64(4)
            )
            < 0
        ):
            var error = _mx_error()
            external_call["usdm_mx_image_close", NoneType](self._handle)
            self._handle = 0
            raise error^
        self.width = Int(info[0])
        self.height = Int(info[1])
        self._count = Int(info[2])
        self._address = info[3]

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle
        self._count = move._count
        self._address = move._address
        self.width = move.width
        self.height = move.height

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_mx_image_close", NoneType](self._handle)

    def pixels(self) -> ImmSpan[Float32, origin_of(self)]:
        return ImmSpan(
            unsafe_ptr=Pointer[Float32, origin_of(self)](
                unsafe_from_address=Int(self._address)
            ),
            length=self._count,
        )
