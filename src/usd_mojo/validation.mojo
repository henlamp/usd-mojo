# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Owned findings for a composed working set, with explicit validator coverage."""
from std.ffi import c_int, external_call
from std.collections import Array, Optional
from .stage import Stage, TimeCode, _validate_time
from .errors import UsdError
from ._bridge import _StringsOwner, _take_strings, _check, _error


@fieldwise_init
struct ValidationSite(Copyable):
    var layer_identifier: String
    var stage_identifier: String
    var object_path: String
    var valid: Bool


@fieldwise_init
struct ValidationIssue(Copyable):
    var identifier: String
    var severity: String
    var message: String
    var sites: List[ValidationSite]


@fieldwise_init
struct ValidationReport(Copyable):
    var issues: List[ValidationIssue]
    var validators: List[String]
    var population_mask: List[String]
    var unloaded_payloads: List[String]
    var muted_layers: List[String]
    var total_issues: UInt64
    var error_count: UInt64
    var warning_count: UInt64
    var info_count: UInt64
    var time: Optional[TimeCode]

    def is_valid(self) -> Bool:
        """No errors from the selected rules/time on this working set."""
        return self.error_count == 0

    def truncated(self) -> Bool:
        return UInt64(len(self.issues)) < self.total_issues


struct _ValidationOwner(Movable):
    var handle: UInt64

    def __init__(out self, handle: UInt64) raises UsdError:
        self.handle = handle
        if not handle:
            raise _error()

    def __init__(out self, *, deinit move: Self):
        self.handle = move.handle

    def __deinit__(deinit self):
        external_call["usdm_validation_close", NoneType](self.handle)


def validator_names() raises UsdError -> List[String]:
    return _take_strings(external_call["usdm_validator_names", UInt64]())


def validate_stage(
    stage: Stage,
    *,
    validators: List[String] = List[String](),
    time: Optional[TimeCode] = None,
    max_issues: Int = 1000,
) raises UsdError -> ValidationReport:
    """Run SDK validators and the mesh checker; never fix or save source data.

    An empty validator list selects all available rules. time=None includes all
    authored samples; an explicit TimeCode selects its default/sample value.
    max_issues limits returned detail, not SDK execution or total error counts.
    Inactive, masked, muted, unloaded and unselected variant contents are outside
    the working set. Invalid SDK sites can lack a retrievable object path.
    """
    var names = _StringsOwner(validators)
    var mode = 0
    var frame = Float64(0)
    if time:
        var value = time.value()
        _validate_time(value)
        mode = 1 if value.is_default else 2
        frame = value.value
    var native = _ValidationOwner(
        external_call["usdm_validate", UInt64](
            stage._handle, names.handle, Int64(max_issues), frame, c_int(mode)
        )
    )
    var info = Array[UInt64, 5]()
    _check(
        Int64(
            external_call["usdm_validation_info", c_int](
                native.handle, info.unsafe_ptr(), Int64(5)
            )
        )
    )
    var issues = List[ValidationIssue](capacity=Int(info[4]))
    for i in range(Int(info[4])):
        var fields = _take_strings(
            external_call["usdm_validation_issue", UInt64](
                native.handle, Int64(i)
            )
        )
        if len(fields) < 3 or (len(fields) - 3) % 4:
            raise UsdError(.internal, "Invalid validation issue snapshot")
        var sites = List[ValidationSite]()
        for j in range(3, len(fields), 4):
            sites.append(
                ValidationSite(
                    fields[j],
                    fields[j + 1],
                    fields[j + 2],
                    fields[j + 3] == "1",
                )
            )
        issues.append(ValidationIssue(fields[0], fields[1], fields[2], sites^))
    return ValidationReport(
        issues^,
        _take_strings(
            external_call["usdm_validation_strings", UInt64](
                native.handle, c_int(0)
            )
        ),
        _take_strings(
            external_call["usdm_validation_strings", UInt64](
                native.handle, c_int(1)
            )
        ),
        _take_strings(
            external_call["usdm_validation_strings", UInt64](
                native.handle, c_int(2)
            )
        ),
        _take_strings(
            external_call["usdm_validation_strings", UInt64](
                native.handle, c_int(3)
            )
        ),
        info[0],
        info[1],
        info[2],
        info[3],
        time.copy(),
    )
