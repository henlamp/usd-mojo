# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Owned USD values with exact integer storage and explicit USD type identity.

Floating vectors/matrices are component-major per element; matrices are row-major
and quaternions use (real, x, y, z). Assets retain authored asset paths. Float16
and Float32 values are rounded by the SDK, not stored as borrowed pointers.
"""


struct Value(Copyable):
    var type_name: String
    var numbers: List[Float64]
    var integers: List[Int64]
    var unsigned_integers: List[UInt64]
    var texts: List[String]

    def __init__(out self, var type_name: String):
        self.type_name = type_name^
        self.numbers = List[Float64]()
        self.integers = List[Int64]()
        self.unsigned_integers = List[UInt64]()
        self.texts = List[String]()

    @staticmethod
    def floating(var type_name: String, var values: List[Float64]) -> Self:
        var result = Self(type_name^)
        result.numbers = values^
        return result^

    @staticmethod
    def signed(var type_name: String, var values: List[Int64]) -> Self:
        var result = Self(type_name^)
        result.integers = values^
        return result^

    @staticmethod
    def unsigned(var type_name: String, var values: List[UInt64]) -> Self:
        var result = Self(type_name^)
        result.unsigned_integers = values^
        return result^

    @staticmethod
    def text(var type_name: String, var values: List[String]) -> Self:
        var result = Self(type_name^)
        result.texts = values^
        return result^
