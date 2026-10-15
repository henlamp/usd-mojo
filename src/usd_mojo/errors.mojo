# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Stable error categories; diagnostic prose is not a compatibility contract."""
from std.io import Writer


@fieldwise_init
struct UsdErrorKind(Equatable, ImplicitlyCopyable, Writable):
    var _code: Int
    comptime invalid_argument = Self(1)
    comptime not_found = Self(2)
    comptime type_mismatch = Self(3)
    comptime unsupported = Self(4)
    comptime invalid_data = Self(5)
    comptime io = Self(6)
    comptime sdk = Self(7)
    comptime incompatible = Self(8)
    comptime internal = Self(9)
    comptime resource = Self(10)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self._code)

    def code(self) -> Int:
        return self._code


@fieldwise_init
struct UsdError(Copyable, Writable):
    var kind: UsdErrorKind
    var message: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write("USD error ", self.kind.code(), ": ", self.message)
