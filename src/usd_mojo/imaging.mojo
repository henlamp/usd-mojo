# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Optional Hydra imaging. Link usd_mojo_imaging and call on the main thread."""
from std.ffi import c_int, external_call
from std.collections import Array, ImmSpan, MutSpan
from std.memory import Pointer
from .stage import Stage, TimeCode, _validate_time
from .errors import UsdError, UsdErrorKind
from ._bridge import _c_bytes


def _image_error() -> UsdError:
    var kind = UsdErrorKind(Int(external_call["usdm_image_error_kind", c_int]()))
    var probe = Array[UInt8, 1]()
    var size = external_call["usdm_image_error", Int64](
        probe.unsafe_ptr(), Int64(0)
    )
    if size < 0:
        return UsdError(.internal, "Cannot read Hydra error")
    var data = List[UInt8](length=Int(size) + 1, fill=0)
    var copied = external_call["usdm_image_error", Int64](
        data.unsafe_ptr(), Int64(len(data))
    )
    if copied != size:
        return UsdError(.internal, "Cannot copy Hydra error")
    return UsdError(kind, String(unsafe_from_utf8_ptr=data.unsafe_ptr()))


def renderer_plugins() raises UsdError -> List[String]:
    var probe = Array[UInt8, 1]()
    var size = external_call["usdm_image_plugins", Int64](
        probe.unsafe_ptr(), Int64(0)
    )
    if size < 0:
        raise _image_error()
    var data = List[UInt8](length=Int(size) + 1, fill=0)
    if (
        external_call["usdm_image_plugins", Int64](
            data.unsafe_ptr(), Int64(len(data))
        )
        < 0
    ):
        raise _image_error()
    var names = String(unsafe_from_utf8_ptr=data.unsafe_ptr())
    var result = List[String]()
    for name in names.split("\n"):
        if name.byte_length() > 0:
            result.append(String(name))
    return result^


def _validate_render(camera: String, time: TimeCode, max_iterations: Int) raises UsdError:
    _validate_time(time)
    if max_iterations <= 0 or max_iterations > 256:
        raise UsdError(.invalid_argument, "Render iteration limit must be 1..256")


struct RenderSession(Movable):
    """Fixed-size offscreen renderer retaining its stage, Hgi and Hydra engine.

    Create, render, read and destroy on the main thread. render() submits work;
    readback/read_into can synchronize with the GPU. CPU snapshots are independent.
    """

    var _handle: UInt64
    var _has_frame: Bool
    var width: Int
    var height: Int
    var frame: UInt64
    var converged: Bool

    def __init__(
        out self, stage: Stage, width: Int, height: Int, *, renderer: String = ""
    ) raises UsdError:
        self._handle = 0
        self._has_frame = False
        self.width = 0
        self.height = 0
        self.frame = 0
        self.converged = False
        if (
            width <= 0 or height <= 0 or width > 8192 or height > 8192
            or width * height > 16777216
        ):
            raise UsdError(
                .invalid_argument, "Render size exceeds the 16 megapixel limit"
            )
        var r = _c_bytes(renderer)
        self._handle = external_call["usdm_render_session_open", UInt64](
            stage._handle, r.unsafe_ptr(), c_int(width), c_int(height)
        )
        if not self._handle:
            raise _image_error()
        try:
            self._sync_info()
        except error:
            external_call["usdm_render_session_close", NoneType](self._handle)
            self._handle = 0
            raise error^

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle
        self._has_frame = move._has_frame
        self.width = move.width
        self.height = move.height
        self.frame = move.frame
        self.converged = move.converged

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_render_session_close", NoneType](self._handle)

    def _text(self, field: Int) raises UsdError -> String:
        var probe = Array[UInt8, 1]()
        var size = external_call["usdm_render_session_text", Int64](
            self._handle, c_int(field), probe.unsafe_ptr(), Int64(0)
        )
        if size <= 0:
            raise _image_error()
        var data = List[UInt8](length=Int(size), fill=0)
        if external_call["usdm_render_session_text", Int64](
            self._handle, c_int(field), data.unsafe_ptr(), size
        ) < 0:
            raise _image_error()
        return String(unsafe_from_utf8_ptr=data.unsafe_ptr())

    def backend(self) raises UsdError -> String:
        """Return the active Hgi API, such as Metal, OpenGL or Vulkan."""
        return self._text(0)

    def renderer(self) raises UsdError -> String:
        """Return the selected Hydra renderer plugin identifier."""
        return self._text(1)

    def _sync_info(mut self) raises UsdError:
        var info = Array[UInt64, 5]()
        if external_call["usdm_render_session_info", c_int](
            self._handle, info.unsafe_ptr(), Int64(5)
        ) < 0:
            raise _image_error()
        self.width = Int(info[0])
        self.height = Int(info[1])
        self.frame = info[2]
        self._has_frame = Bool(info[3])
        self.converged = Bool(info[4])

    def render(
        mut self, camera: String, time: TimeCode = .default, *,
        max_iterations: Int = 8, lighting: Bool = True,
    ) raises UsdError:
        """Render one frame. A failed attempt invalidates subsequent readback."""
        self._has_frame = False
        self.converged = False
        _validate_render(camera, time, max_iterations)
        var c = _c_bytes(camera)
        if external_call["usdm_render_session_render", c_int](
            self._handle, c.unsafe_ptr(), time.value, c_int(time.is_default),
            c_int(max_iterations), c_int(lighting),
        ) < 0:
            raise _image_error()
        self._sync_info()

    def readback(mut self) raises UsdError -> RenderImage:
        """Read the last successful frame into an independent CPU image."""
        if not self._has_frame:
            raise UsdError(.invalid_argument, "Render a frame before readback")
        return RenderImage(self)

    def read_into(mut self, pixels: MutSpan[Float32, _]) raises UsdError:
        """Read into exact-sized caller storage; retain no pointer after return."""
        if not self._has_frame:
            raise UsdError(.invalid_argument, "Render a frame before readback")
        if len(pixels) != self.width * self.height * 4:
            raise UsdError(.invalid_argument, "Image output extent mismatch")
        if external_call["usdm_render_session_read_into", c_int](
            self._handle, pixels.unsafe_ptr(), Int64(len(pixels))
        ) < 0:
            raise _image_error()


struct RenderImage(Movable):
    """Owned linear Float32 RGBA from the renderer's color AOV, row order retained.

    A bounded render may be unconverged; callers must inspect converged. HDR
    channels are retained without clipping or display color conversion.
    """

    var _handle: UInt64
    var width: Int
    var height: Int
    var converged: Bool
    var _count: Int
    var _address: UInt64

    def __init__(
        out self,
        stage: Stage,
        camera: String,
        width: Int,
        height: Int,
        time: TimeCode = .default,
        *,
        renderer: String = "",
        max_iterations: Int = 8,
        lighting: Bool = True,
    ) raises UsdError:
        _validate_render(camera, time, max_iterations)
        var session = RenderSession(stage, width, height, renderer=renderer)
        session.render(camera, time, max_iterations=max_iterations, lighting=lighting)
        self = Self(session)

    def __init__(out self, mut session: RenderSession) raises UsdError:
        self._handle = 0
        self.width = 0
        self.height = 0
        self.converged = False
        self._count = 0
        self._address = 0
        if not session._has_frame:
            raise UsdError(.invalid_argument, "Render a frame before readback")
        self._handle = external_call["usdm_render_session_readback", UInt64](
            session._handle
        )
        if not self._handle:
            raise _image_error()
        var info = Array[UInt64, 5]()
        if (
            external_call["usdm_image_info", c_int](
                self._handle, info.unsafe_ptr(), Int64(5)
            )
            < 0
        ):
            var error = _image_error()
            external_call["usdm_image_close", NoneType](self._handle)
            self._handle = 0
            raise error^
        self.width = Int(info[0])
        self.height = Int(info[1])
        self.converged = Bool(info[2])
        self._count = Int(info[3])
        self._address = info[4]

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle
        self.width = move.width
        self.height = move.height
        self.converged = move.converged
        self._count = move._count
        self._address = move._address

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_image_close", NoneType](self._handle)

    def pixels(self) -> ImmSpan[Float32, origin_of(self)]:
        return ImmSpan(
            unsafe_ptr=Pointer[Float32, origin_of(self)](
                unsafe_from_address=Int(self._address)
            ),
            length=self._count,
        )
