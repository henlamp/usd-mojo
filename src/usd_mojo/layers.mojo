# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Owned SDK layers and explicit edit targets; no implicit layer flattening."""
from std.ffi import c_int, external_call
from .errors import UsdError
from .stage import Stage
from ._bridge import (
    _c_bytes,
    _error,
    _check,
    _take_text,
    _take_strings,
    _StringsOwner,
    _take_value,
)


@fieldwise_init
struct LayerOffset(ImplicitlyCopyable):
    var offset: Float64
    var scale: Float64


struct Layer(Movable):
    var _handle: UInt64

    def __init__(
        out self,
        var identifier: String,
        *,
        create: Bool = False,
        anonymous: Bool = False,
    ) raises UsdError:
        self._handle = 0
        if create and anonymous:
            raise UsdError(.invalid_argument, "Choose create or anonymous")
        var data = _c_bytes(identifier)
        self._handle = external_call["usdm_layer_open", UInt64](
            data.unsafe_ptr(), c_int(2 if anonymous else 1 if create else 0)
        )
        if not self._handle:
            raise _error()

    def __init__(
        out self, stage: Stage, *, session: Bool = False
    ) raises UsdError:
        self._handle = external_call["usdm_stage_layer", UInt64](
            stage._handle, c_int(session)
        )
        if not self._handle:
            raise _error()

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_layer_close", NoneType](self._handle)

    @staticmethod
    def anonymous(tag: String = "scratch.usda") raises UsdError -> Self:
        return Self(tag, anonymous=True)

    def _text(self, kind: Int) raises UsdError -> String:
        return _take_text(
            external_call["usdm_layer_text", UInt64](self._handle, c_int(kind))
        )

    def identifier(self) raises UsdError -> String:
        return self._text(0)

    def real_path(self) raises UsdError -> String:
        return self._text(1)

    def content(self) raises UsdError -> String:
        return self._text(2)

    def dirty(self) raises UsdError -> Bool:
        var result = external_call["usdm_layer_flag", c_int](
            self._handle, c_int(0)
        )
        _check(Int64(result))
        return result != 0

    def is_anonymous(self) raises UsdError -> Bool:
        var result = external_call["usdm_layer_flag", c_int](
            self._handle, c_int(1)
        )
        _check(Int64(result))
        return result != 0

    def _write(mut self, kind: Int, var text: String) raises UsdError:
        var data = _c_bytes(text)
        _check(
            Int64(
                external_call["usdm_layer_write", c_int](
                    self._handle, c_int(kind), data.unsafe_ptr()
                )
            )
        )

    def save(mut self) raises UsdError:
        self._write(0, "")

    def export(self, var filename: String) raises UsdError:
        var data = _c_bytes(filename)
        _check(
            Int64(
                external_call["usdm_layer_write", c_int](
                    self._handle, c_int(1), data.unsafe_ptr()
                )
            )
        )

    def replace_content(mut self, text: String) raises UsdError:
        """Parse USDA separately before replacing this layer's content."""
        self._write(2, text)

    def sublayers(self) raises UsdError -> List[String]:
        return _take_strings(
            external_call["usdm_layer_sublayers", UInt64](self._handle)
        )

    def set_sublayers(mut self, paths: List[String]) raises UsdError:
        var values = _StringsOwner(paths)
        _check(
            Int64(
                external_call["usdm_layer_set_sublayers", c_int](
                    self._handle, values.handle
                )
            )
        )

    def field_names(self, path: String = "/") raises UsdError -> List[String]:
        var data = _c_bytes(path)
        return _take_strings(
            external_call["usdm_layer_field_names", UInt64](
                self._handle, data.unsafe_ptr()
            )
        )

    def sublayer_offsets(self) raises UsdError -> List[LayerOffset]:
        var values = _take_value(
            external_call["usdm_layer_offsets", UInt64](self._handle)
        )
        if len(values.numbers) % 2:
            raise UsdError(.internal, "Invalid sublayer offsets")
        var result = List[LayerOffset](capacity=len(values.numbers) // 2)
        for i in range(0, len(values.numbers), 2):
            result.append(LayerOffset(values.numbers[i], values.numbers[i + 1]))
        return result^

    def set_sublayer_offset(
        mut self, index: Int, offset: Float64, scale: Float64 = 1
    ) raises UsdError:
        _check(
            Int64(
                external_call["usdm_layer_offset_set", c_int](
                    self._handle, Int64(index), offset, scale
                )
            )
        )

    def override_prim(mut self, path: String) raises UsdError:
        """Ensure a local over without changing an existing prim's specifier."""
        var p = _c_bytes(path)
        _check(Int64(external_call["usdm_layer_override", c_int](self._handle,p.unsafe_ptr())))

    def remove_variant(mut self, path: String, set_name: String, variant: String) raises UsdError:
        """Remove this layer's variant definition; retain authored selections."""
        if variant.byte_length() == 0:
            raise UsdError(.invalid_argument, "Variant name is required")
        self._remove_variant(path, set_name, variant)

    def remove_variant_set(mut self, path: String, set_name: String) raises UsdError:
        self._remove_variant(path, set_name, "")

    def _remove_variant(mut self, path: String, set_name: String, variant: String) raises UsdError:
        var p = _c_bytes(path)
        var s = _c_bytes(set_name)
        var v = _c_bytes(variant)
        _check(Int64(external_call["usdm_layer_remove_variant", c_int](self._handle,p.unsafe_ptr(),s.unsafe_ptr(),v.unsafe_ptr())))


@fieldwise_init
struct NamespaceCheck(Copyable):
    var errors: List[String]
    var warnings: List[String]

    def can_apply(self) -> Bool:
        return len(self.errors) == 0


struct NamespaceEditor(Movable):
    """Preflight SDK namespace edits; dependent stages must be supplied explicitly.

    Only loaded and composed dependencies are visible. Unselected variants and
    unloaded payloads require separate edits, as with the SDK namespace editor.
    """

    var _handle: UInt64

    def __init__(
        out self, stage: Stage, *, allow_relocates: Bool = True
    ) raises UsdError:
        self._handle = external_call["usdm_namespace_open", UInt64](
            stage._handle, c_int(allow_relocates)
        )
        if not self._handle:
            raise _error()

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_namespace_close", NoneType](self._handle)

    def add_dependent_stage(mut self, stage: Stage) raises UsdError:
        _check(
            Int64(
                external_call["usdm_namespace_dependent", c_int](
                    self._handle, stage._handle
                )
            )
        )

    def _queue(
        mut self, source: String, destination: String, property: Bool
    ) raises UsdError:
        var s = _c_bytes(source)
        var d = _c_bytes(destination)
        _check(
            Int64(
                external_call["usdm_namespace_queue", c_int](
                    self._handle,
                    s.unsafe_ptr(),
                    d.unsafe_ptr(),
                    c_int(property),
                )
            )
        )

    def move_prim(
        mut self, source: String, destination: String
    ) raises UsdError:
        self._queue(source, destination, False)

    def delete_prim(mut self, path: String) raises UsdError:
        self._queue(path, "", False)

    def move_property(
        mut self, source: String, destination: String
    ) raises UsdError:
        self._queue(source, destination, True)

    def delete_property(mut self, path: String) raises UsdError:
        self._queue(path, "", True)

    def check(self) raises UsdError -> NamespaceCheck:
        var fields = _take_strings(
            external_call["usdm_namespace_check", UInt64](self._handle)
        )
        if len(fields) % 2:
            raise UsdError(.internal, "Invalid namespace diagnostics")
        var errors = List[String]()
        var warnings = List[String]()
        for i in range(0, len(fields), 2):
            if fields[i] == "error":
                errors.append(fields[i + 1])
            else:
                warnings.append(fields[i + 1])
        return NamespaceCheck(errors^, warnings^)

    def apply(mut self) raises UsdError:
        _check(
            Int64(external_call["usdm_namespace_apply", c_int](self._handle))
        )


struct EditTarget(Movable):
    """Retain an SDK edit mapping and its stage; applying to another stage fails.
    """

    var _handle: UInt64

    def __init__(out self, stage: Stage) raises UsdError:
        var empty = _c_bytes("")
        self._handle = external_call["usdm_edit_target", UInt64](
            stage._handle, UInt64(0), empty.unsafe_ptr()
        )
        if not self._handle:
            raise _error()

    def __init__(
        out self, stage: Stage, layer: Layer, *, reference_prim: String = ""
    ) raises UsdError:
        var path = _c_bytes(reference_prim)
        self._handle = external_call["usdm_edit_target", UInt64](
            stage._handle, layer._handle, path.unsafe_ptr()
        )
        if not self._handle:
            raise _error()

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle

    def __deinit__(deinit self):
        if self._handle:
            external_call["usdm_target_close", NoneType](self._handle)

    def apply(self, mut stage: Stage) raises UsdError:
        _check(
            Int64(
                external_call["usdm_target_set", c_int](
                    stage._handle, self._handle
                )
            )
        )

    def map_to_spec_path(self, var path: String) raises UsdError -> String:
        var data = _c_bytes(path)
        return _take_text(
            external_call["usdm_target_map", UInt64](
                self._handle, data.unsafe_ptr()
            )
        )


def save_layers(mut stage: Stage, *, session: Bool = False) raises UsdError:
    """Save contributing dirty layers, or only session layers, using SDK policy.
    """
    _check(
        Int64(
            external_call["usdm_stage_save_layers", c_int](
                stage._handle, c_int(session)
            )
        )
    )


def rename_prim(
    mut stage: Stage, var path: String, var destination: String
) raises UsdError:
    if destination.byte_length() == 0:
        raise UsdError(.invalid_argument, "Use remove_prim to delete a prim")
    var source = _c_bytes(path)
    var target = _c_bytes(destination)
    _check(
        Int64(
            external_call["usdm_namespace_edit", c_int](
                stage._handle, source.unsafe_ptr(), target.unsafe_ptr()
            )
        )
    )


def remove_prim(mut stage: Stage, var path: String) raises UsdError:
    var source = _c_bytes(path)
    var empty = _c_bytes("")
    _check(
        Int64(
            external_call["usdm_namespace_edit", c_int](
                stage._handle, source.unsafe_ptr(), empty.unsafe_ptr()
            )
        )
    )


def _add_arc(
    mut stage: Stage, path: String, target: String, kind: Int
) raises UsdError:
    var p = _c_bytes(path)
    var t = _c_bytes(target)
    _check(
        Int64(
            external_call["usdm_composition_edit", c_int](
                stage._handle, p.unsafe_ptr(), t.unsafe_ptr(), c_int(kind)
            )
        )
    )


def add_inherit(mut stage: Stage, path: String, target: String) raises UsdError:
    _add_arc(stage, path, target, 0)


def add_specialize(
    mut stage: Stage, path: String, target: String
) raises UsdError:
    _add_arc(stage, path, target, 1)
