# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Dependency discovery and SDK USDZ packaging with an explicit resolver context."""
from std.ffi import c_int, external_call
from .errors import UsdError
from .stage import Stage
from ._bridge import _c_bytes, _take_strings, _check


@fieldwise_init
struct AssetDependency(Copyable):
    var kind: String
    var path: String


def dependencies(stage: Stage) raises UsdError -> List[AssetDependency]:
    """Discover saved layer/asset dependencies; report unresolved paths separately.
    """
    var fields = _take_strings(
        external_call["usdm_dependencies", UInt64](stage._handle)
    )
    if len(fields) % 2:
        raise UsdError(.internal, "Invalid dependency snapshot")
    var result = List[AssetDependency](capacity=len(fields) // 2)
    for i in range(0, len(fields), 2):
        result.append(AssetDependency(fields[i], fields[i + 1]))
    return result^


def export_usdz(stage: Stage, filename: String) raises UsdError:
    """Package saved layers/assets. Refuse unsaved edits or an existing output.
    """
    var p = _c_bytes(filename)
    _check(
        Int64(external_call["usdm_usdz", c_int](stage._handle, p.unsafe_ptr()))
    )
