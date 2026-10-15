# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Owned typed values retaining USD units and conventions."""
from std.io import Writer


@fieldwise_init
struct Vector3(Equatable, ImplicitlyCopyable, Writable):
    var x: Float64
    var y: Float64
    var z: Float64
    comptime zero = Self(0, 0, 0)

    def write_to(self, mut writer: Some[Writer]):
        writer.write("Vector3(", self.x, ", ", self.y, ", ", self.z, ")")


@fieldwise_init
struct Quaternion(Equatable, ImplicitlyCopyable, Writable):
    """Scalar first: w, x, y, z."""

    var w: Float64
    var x: Float64
    var y: Float64
    var z: Float64
    comptime identity = Self(1, 0, 0, 0)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            "Quaternion(", self.w, ", ", self.x, ", ", self.y, ", ", self.z, ")"
        )


@fieldwise_init
struct TransformData(ImplicitlyCopyable):
    """World TRS; affine shear/reflections require the full matrix accessor."""

    var position: Vector3
    var rotation: Quaternion
    var scale: Vector3
