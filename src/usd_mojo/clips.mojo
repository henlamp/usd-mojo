# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Clip dictionaries preserve explicit and template clip-set definitions."""
from .stage import Stage
from .errors import UsdError, UsdErrorKind
from .metadata import Metadata, set_metadata, clear_metadata


def clip_sets(stage: Stage, path: String) raises UsdError -> List[String]:
    _ = stage.prim_type(path)
    try:
        var metadata = Metadata(stage, "clips", path=path)
        return metadata.keys()
    except error:
        if error.kind == UsdErrorKind.not_found:
            return List[String]()
        raise error^


def clip_set(
    stage: Stage, path: String, name: String = "default"
) raises UsdError -> Metadata:
    var metadata = Metadata(stage, "clips", path=path)
    return Metadata(metadata, name)


def set_clip_set(
    mut stage: Stage, path: String, data: Metadata, name: String = "default"
) raises UsdError:
    if name.byte_length() == 0 or ":" in name:
        raise UsdError(
            .invalid_argument, "Clip set name must be a nonempty dictionary key"
        )
    if not data.is_dictionary():
        raise UsdError(
            .type_mismatch, "Clip set definition must be a dictionary"
        )
    set_metadata(stage, "clips", data, path=path, dictionary=name)


def clear_clip_set(
    mut stage: Stage, path: String, name: String = "default"
) raises UsdError:
    if name.byte_length() == 0 or ":" in name:
        raise UsdError(
            .invalid_argument, "Clip set name must be a nonempty dictionary key"
        )
    clear_metadata(stage, "clips", path=path, dictionary=name)
