# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Owned SDK splines with explicit knot, tangent and extrapolation editing."""
from std.collections import Array, Optional
from std.ffi import c_int, external_call
from .errors import UsdError
from .stage import Stage
from .metadata import Metadata
from ._bridge import (
    _c_bytes,
    _take_strings,
    _take_value,
    _check,
    _error,
)


def _selector(value: String, choices: List[String]) raises UsdError -> Int:
    for i in range(len(choices)):
        if choices[i] == value:
            return i
    raise UsdError(.invalid_argument, String("Unknown spline mode: ", value))


struct SplineKnot(Copyable):
    var time: Float64
    var value: Float64
    var interpolation: String
    var pre_value: Optional[Float64]
    var pre_slope: Float64
    var post_slope: Float64
    var pre_width: Float64
    var post_width: Float64
    var pre_algorithm: String
    var post_algorithm: String

    def __init__(
        out self,
        time: Float64,
        value: Float64,
        *,
        interpolation: String = "curve",
        pre_value: Optional[Float64] = None,
        pre_slope: Float64 = 0,
        post_slope: Float64 = 0,
        pre_width: Float64 = 0,
        post_width: Float64 = 0,
        pre_algorithm: String = "none",
        post_algorithm: String = "none",
    ):
        self.time = time
        self.value = value
        self.interpolation = interpolation
        self.pre_value = pre_value.copy()
        self.pre_slope = pre_slope
        self.post_slope = post_slope
        self.pre_width = pre_width
        self.post_width = post_width
        self.pre_algorithm = pre_algorithm
        self.post_algorithm = post_algorithm


@fieldwise_init
struct SplineExtrapolation(Copyable):
    var mode: String
    var slope: Float64
    var boundary: Optional[Float64]


@fieldwise_init
struct SplineLoop(Copyable):
    var start: Float64
    var end: Float64
    var before: Int
    var after: Int
    var offset: Float64


struct Spline(Movable):
    """Independent SDK spline; author() copies its value into the edit target.

    Reading retains all SDK spline settings. Borrowing a stage is only needed
    while reading/authoring; this owner can outlive the source stage.
    """

    var _handle: UInt64
    var type_name: String
    var curve: String

    def __init__(
        out self, type_name: String = "double", *, curve: String = "bezier"
    ) raises UsdError:
        self._handle = 0
        self.type_name = ""
        self.curve = ""
        var c = _selector(curve, [String("bezier"), String("hermite")])
        var t = _c_bytes(type_name)
        self._handle = external_call["usdm_spline_new", UInt64](
            t.unsafe_ptr(), c_int(c)
        )
        self._finish_init()

    def __init__(out self, stage: Stage, path: String, name: String) raises UsdError:
        self._handle = 0
        self.type_name = ""
        self.curve = ""
        var p = _c_bytes(path)
        var n = _c_bytes(name)
        self._handle = external_call["usdm_spline_read", UInt64](
            stage._handle, p.unsafe_ptr(), n.unsafe_ptr()
        )
        self._finish_init()

    def __init__(out self, other: Self) raises UsdError:
        self._handle = external_call["usdm_spline_copy", UInt64](other._handle)
        self.type_name = ""
        self.curve = ""
        self._finish_init()

    def _finish_init(mut self) raises UsdError:
        if not self._handle:
            raise _error()
        try:
            var info = _take_strings(
                external_call["usdm_spline_info", UInt64](self._handle)
            )
            if len(info) != 2:
                raise UsdError(.internal, "Invalid spline metadata")
            self.type_name = info[0]
            self.curve = info[1]
        except error:
            external_call["usdm_spline_close", NoneType](self._handle)
            self._handle = 0
            raise error^

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle
        self.type_name = move.type_name^
        self.curve = move.curve^

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_spline_close", NoneType](self._handle)

    def set_knot(mut self, knot: SplineKnot) raises UsdError:
        var data: Array[Float64, 8] = [
            knot.time,
            knot.value,
            knot.value,
            knot.pre_slope,
            knot.post_slope,
            knot.pre_width,
            knot.post_width,
            Float64(Bool(knot.pre_value)),
        ]
        if knot.pre_value:
            data[2] = knot.pre_value.value()
        var modes: Array[Int32, 3] = [
            Int32(
                _selector(
                    knot.interpolation,
                    [
                        String("block"),
                        String("held"),
                        String("linear"),
                        String("curve"),
                    ],
                )
            ),
            Int32(
                _selector(
                    knot.pre_algorithm,
                    [String("none"), String("custom"), String("auto_ease")],
                )
            ),
            Int32(
                _selector(
                    knot.post_algorithm,
                    [String("none"), String("custom"), String("auto_ease")],
                )
            ),
        ]
        _check(
            Int64(
                external_call["usdm_spline_set_knot", c_int](
                    self._handle,
                    data.unsafe_ptr(),
                    Int64(8),
                    modes.unsafe_ptr(),
                    Int64(3),
                )
            )
        )

    def knot(self, time: Float64) raises UsdError -> SplineKnot:
        var data = Array[Float64, 8]()
        var modes = Array[Int32, 3]()
        _check(
            Int64(
                external_call["usdm_spline_knot", c_int](
                    self._handle,
                    time,
                    data.unsafe_ptr(),
                    Int64(8),
                    modes.unsafe_ptr(),
                    Int64(3),
                )
            )
        )
        var pre = Optional[Float64]()
        if data[7] != 0:
            pre = data[2]
        var interpolations = [
            String("block"),
            String("held"),
            String("linear"),
            String("curve"),
        ]
        var algorithms = [String("none"), String("custom"), String("auto_ease")]
        return SplineKnot(
            data[0],
            data[1],
            interpolation=interpolations[Int(modes[0])],
            pre_value=pre,
            pre_slope=data[3],
            post_slope=data[4],
            pre_width=data[5],
            post_width=data[6],
            pre_algorithm=algorithms[Int(modes[1])],
            post_algorithm=algorithms[Int(modes[2])],
        )

    def knot_times(self) raises UsdError -> List[Float64]:
        var result = _take_value(
            external_call["usdm_spline_times", UInt64](self._handle)
        )
        return result.numbers.copy()

    def remove_knot(mut self, time: Float64) raises UsdError:
        _check(Int64(external_call["usdm_spline_remove", c_int](self._handle, time)))

    def evaluate(
        self, time: Float64, *, mode: String = "value"
    ) raises UsdError -> Float64:
        var m = _selector(
            mode,
            [
                String("value"),
                String("pre_value"),
                String("derivative"),
                String("pre_derivative"),
                String("held"),
                String("pre_held"),
            ],
        )
        var result = _take_value(
            external_call["usdm_spline_eval", UInt64](self._handle, time, c_int(m))
        )
        if len(result.numbers) != 1:
            raise UsdError(.internal, "Invalid spline result")
        return result.numbers[0]

    def set_extrapolation(
        mut self,
        mode: String,
        *,
        before: Bool = False,
        slope: Float64 = 0,
        boundary: Optional[Float64] = None,
    ) raises UsdError:
        var m = _selector(
            mode,
            [
                String("block"),
                String("held"),
                String("linear"),
                String("sloped"),
                String("repeat"),
                String("reset"),
                String("oscillate"),
            ],
        )
        var value = Float64(0)
        if boundary:
            value = boundary.value()
        _check(
            Int64(
                external_call["usdm_spline_extrapolate", c_int](
                    self._handle,
                    c_int(0 if before else 1),
                    c_int(m),
                    slope,
                    value,
                    c_int(Bool(boundary)),
                )
            )
        )

    def author(self, mut stage: Stage, path: String, name: String) raises UsdError:
        var p = _c_bytes(path)
        var n = _c_bytes(name)
        _check(
            Int64(
                external_call["usdm_spline_author", c_int](
                    stage._handle, self._handle, p.unsafe_ptr(), n.unsafe_ptr()
                )
            )
        )

    def extrapolation(
        self, *, before: Bool = False
    ) raises UsdError -> SplineExtrapolation:
        var result = _take_value(
            external_call["usdm_spline_options", UInt64](
                self._handle, c_int(0 if before else 1)
            )
        )
        var modes = [
            String("block"),
            String("held"),
            String("linear"),
            String("sloped"),
            String("repeat"),
            String("reset"),
            String("oscillate"),
        ]
        var boundary = Optional[Float64]()
        if result.numbers[2] != 0:
            boundary = result.numbers[3]
        return SplineExtrapolation(
            modes[Int(result.numbers[0])], result.numbers[1], boundary^
        )

    def set_inner_loop(
        mut self,
        start: Float64,
        end: Float64,
        *,
        before: Int = 0,
        after: Int = 0,
        offset: Float64 = 0,
    ) raises UsdError:
        _check(
            Int64(
                external_call["usdm_spline_loop", c_int](
                    self._handle, start, end, Int64(before), Int64(after), offset
                )
            )
        )

    def inner_loop(self) raises UsdError -> SplineLoop:
        var result = _take_value(
            external_call["usdm_spline_options", UInt64](self._handle, c_int(2))
        )
        return SplineLoop(
            result.numbers[0],
            result.numbers[1],
            Int(result.numbers[2]),
            Int(result.numbers[3]),
            result.numbers[4],
        )

    def knot_metadata(self, time: Float64) raises UsdError -> Metadata:
        return Metadata._from_handle(
            external_call["usdm_spline_knot_metadata", UInt64](self._handle, time)
        )

    def set_knot_metadata(mut self, time: Float64, data: Metadata) raises UsdError:
        _check(
            Int64(
                external_call["usdm_spline_knot_metadata_set", c_int](
                    self._handle, time, data._handle
                )
            )
        )
