# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Reachable shader connections with explicit render-context selection."""
from std.ffi import external_call
from .stage import Stage
from .errors import UsdError
from ._bridge import _c_bytes, _take_strings


@fieldwise_init
struct ShaderConnection(Copyable):
    var destination: String
    var source: String
    var resolved: Bool


@fieldwise_init
struct ShaderGraph(Copyable):
    var nodes: List[String]
    var connections: List[ShaderConnection]


def shader_graph(
    stage: Stage, material: String, render_context: String = ""
) raises UsdError -> ShaderGraph:
    """Preserve connection edges, including cycles and missing sources.

    This describes a network; it does not evaluate shader implementations.
    Each node's values are available through SchemaSnapshot.
    Each terminal falls back to the universal output when its context has no
    SDK-resolved shader source. Invalid context edges remain as diagnostics.
    """
    var m = _c_bytes(material)
    var c = _c_bytes(render_context)
    var fields = _take_strings(
        external_call["usdm_shader_graph", UInt64](
            stage._handle, m.unsafe_ptr(), c.unsafe_ptr()
        )
    )
    if len(fields) % 3:
        raise UsdError(.internal, "Invalid shader graph snapshot")
    var nodes = List[String]()
    var connections = List[ShaderConnection]()
    for i in range(0, len(fields), 3):
        if fields[i] == "node":
            nodes.append(fields[i + 1])
        else:
            connections.append(
                ShaderConnection(
                    fields[i + 1], fields[i + 2], fields[i] == "edge"
                )
            )
    return ShaderGraph(nodes^, connections^)
