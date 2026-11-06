# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Capabilities of the linked SDK, including explicit unsupported marker types."""
from std.ffi import external_call
from .errors import UsdError
from ._bridge import _take_strings


@fieldwise_init
struct ValueTypeInfo(Copyable):
    var name: String
    var cpp_type: String
    var role: String
    var is_array: Bool
    var readable_writable: Bool
    var native_view: Bool


def value_types() raises UsdError -> List[ValueTypeInfo]:
    var fields = _take_strings(external_call["usdm_value_types", UInt64]())
    if len(fields) % 6:
        raise UsdError(.internal, "Invalid value type catalog")
    var result = List[ValueTypeInfo](capacity=len(fields) // 6)
    for i in range(0, len(fields), 6):
        result.append(
            ValueTypeInfo(
                fields[i],
                fields[i + 1],
                fields[i + 2],
                fields[i + 3] == "1",
                fields[i + 4] == "1",
                fields[i + 5] == "1",
            )
        )
    return result^


@fieldwise_init
struct SchemaTypeInfo(Copyable):
    var name: String
    var kind: String
    var properties: List[String]


def schema_types() raises UsdError -> List[SchemaTypeInfo]:
    var fields = _take_strings(external_call["usdm_schema_types", UInt64]())
    if len(fields) % 3:
        raise UsdError(.internal, "Invalid schema catalog")
    var result = List[SchemaTypeInfo](capacity=len(fields) // 3)
    for i in range(0, len(fields), 3):
        var names = List[String]()
        for name in fields[i + 2].split("\n"):
            if name.byte_length() > 0:
                names.append(String(name))
        result.append(SchemaTypeInfo(fields[i], fields[i + 1], names^))
    return result^
