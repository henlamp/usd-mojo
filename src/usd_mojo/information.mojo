# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Owned general USD information with SDK units and semantics."""


@fieldwise_init
struct AssetPathData(Copyable):
    var authored: String
    var evaluated: String
    var resolved: String


@fieldwise_init
struct StageInfo(ImplicitlyCopyable):
    var start_time: Float64
    var end_time: Float64
    var time_codes_per_second: Float64
    var frames_per_second: Float64
    var has_authored_range: Bool


@fieldwise_init
struct PrimInfo(Copyable):
    var type_name: String
    var active: Bool
    var defined: Bool
    var abstract: Bool
    var loaded: Bool
    var has_payload: Bool
    var instance: Bool
    var instance_proxy: Bool
    var prototype_path: String


@fieldwise_init
struct PrimvarInfo(Copyable):
    var interpolation: String
    var element_size: Int
    var unauthored_values_index: Int
