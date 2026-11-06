# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Inspect a composed working set without changing or saving its source files."""
from std.sys import argv
from usd_mojo import Stage, validate_stage


def main() raises:
    var args = argv()
    if len(args) != 2:
        raise Error("Usage: validate_scene SCENE")
    var stage = Stage(args[1])
    var report = validate_stage(stage)
    print(
        "SUMMARY",
        report.error_count,
        report.warning_count,
        report.info_count,
        report.total_issues,
    )
    print("RULES", len(report.validators))
    for path in report.population_mask:
        print("MASK", path)
    for path in report.unloaded_payloads:
        print("UNLOADED", path)
    for layer in report.muted_layers:
        print("MUTED", layer)
    for issue in report.issues:
        print(issue.severity, issue.identifier, issue.message)
        for site in issue.sites:
            print("  SITE", site.layer_identifier, site.object_path)
    if report.truncated():
        print(
            "DETAILS OMITTED", report.total_issues - UInt64(len(report.issues))
        )
    if not report.is_valid():
        raise Error("Scene validation failed; see reported findings")
