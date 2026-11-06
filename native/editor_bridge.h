// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
// Layer and metadata owners retain SDK values independently of a Stage wrapper.
#include <pxr/usd/sdf/layer.h>
#include <pxr/usd/sdf/primSpec.h>
#include <pxr/usd/sdf/variantSetSpec.h>
#include <pxr/usd/sdf/variantSpec.h>
#include <pxr/usd/usd/namespaceEditor.h>
#include <pxr/usd/usd/inherits.h>
#include <pxr/usd/usd/specializes.h>
#include <pxr/usd/pcp/primIndex.h>
#include <pxr/usd/pcp/layerStack.h>
#include <pxr/usd/ar/defaultResolverContext.h>
#include <pxr/usd/ar/resolverContextBinder.h>
#include <algorithm>

namespace {
struct LayerOwner { SdfLayerRefPtr layer; };
struct TargetOwner { UsdStageRefPtr stage; UsdEditTarget target; };
struct MetadataOwner { VtValue value; };
struct NamespaceOwner {
    UsdStageRefPtr stage;
    std::vector<UsdStageRefPtr> dependencies;
    std::unique_ptr<UsdNamespaceEditor> editor;
};
NamespaceOwner &namespace_owner(uint64_t h) {
    require(h != 0, "Namespace editor is closed");
    return *reinterpret_cast<NamespaceOwner *>(h);
}
LayerOwner &layer_owner(uint64_t h) {
    require(h != 0, "Layer is closed");
    return *reinterpret_cast<LayerOwner *>(h);
}
TargetOwner &target_owner(uint64_t h) {
    require(h != 0, "Edit target is closed");
    return *reinterpret_cast<TargetOwner *>(h);
}
MetadataOwner &meta_owner(uint64_t h) {
    require(h != 0, "Metadata is closed");
    return *reinterpret_cast<MetadataOwner *>(h);
}
std::unique_ptr<TextOwner> editor_text(std::string s) {
    auto result = std::make_unique<TextOwner>();
    result->text = std::move(s);
    return result;
}
}
USDM_API uint64_t usdm_strings_new() noexcept {
    return protect_owned([] { return std::make_unique<StringsOwner>(); });
}
USDM_API int32_t usdm_strings_append(uint64_t h, const char *value) noexcept {
    return protect([&] {
        require(value != nullptr, "Null string argument");
        strings_owner(h).values.emplace_back(value);
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_layer_open(const char *path, int32_t mode) noexcept {
    return protect_owned([&] {
        require(path != nullptr && mode >= 0 && mode <= 2, "Invalid layer arguments");
        if (mode != 2) require(*path, "Empty layer identifier");
        if (mode == 0) preflight_local_crate(path);
        SdfLayerRefPtr layer;
        if (mode == 0) layer = SdfLayer::FindOrOpen(path);
        else if (mode == 1) layer = SdfLayer::CreateNew(path);
        else layer = SdfLayer::CreateAnonymous(path);
        require(bool(layer), "Cannot open or create layer", ErrorKind::Io);
        auto result = std::make_unique<LayerOwner>();
        result->layer = std::move(layer);
        return result;
    });
}
USDM_API uint64_t usdm_stage_layer(uint64_t h, int32_t session) noexcept {
    return protect_owned([&] {
        require(session == 0 || session == 1, "Invalid layer selector");
        auto layer = session ? owner(h).stage->GetSessionLayer()
                             : owner(h).stage->GetRootLayer();
        require(bool(layer), "Stage has no selected layer", ErrorKind::NotFound);
        auto result = std::make_unique<LayerOwner>();
        result->layer = layer;
        return result;
    });
}
USDM_API void usdm_layer_close(uint64_t h) noexcept {
    delete reinterpret_cast<LayerOwner *>(h);
}
USDM_API uint64_t usdm_layer_text(uint64_t h, int32_t kind) noexcept {
    return protect_owned([&] {
        auto layer = layer_owner(h).layer;
        if (kind == 0) return editor_text(layer->GetIdentifier());
        if (kind == 1) return editor_text(layer->GetRealPath());
        require(kind == 2, "Invalid layer text selector");
        std::string text;
        require(layer->ExportToString(&text), "Cannot serialize layer", ErrorKind::Io);
        return editor_text(std::move(text));
    });
}
USDM_API int32_t usdm_layer_flag(uint64_t h, int32_t kind) noexcept {
    return protect([&] {
        auto layer = layer_owner(h).layer;
        require(kind == 0 || kind == 1, "Invalid layer flag selector");
        return int32_t(kind == 0 ? layer->IsDirty() : layer->IsAnonymous());
    }, int32_t(-1));
}
USDM_API int32_t usdm_layer_write(uint64_t h, int32_t kind, const char *text) noexcept {
    return protect([&] {
        require(text != nullptr && kind >= 0 && kind <= 2, "Invalid layer write arguments");
        auto layer = layer_owner(h).layer;
        if (kind == 0) {
            require(!layer->IsAnonymous(), "Anonymous layers need an export filename");
            require(layer->Save(), "Cannot save layer", ErrorKind::Io);
        } else if (kind == 1) {
            require(*text, "Empty layer export filename");
            require(layer->Export(text), "Cannot export layer", ErrorKind::Io);
        } else {
            // Parse into a separate layer: malformed text must not corrupt existing edits.
            auto parsed = SdfLayer::CreateAnonymous("usd-mojo-parse.usda");
            TfErrorMark diagnostics;
            require(parsed->ImportFromString(text), "Invalid USDA layer text", ErrorKind::InvalidData);
            check_diagnostics(diagnostics);
            layer->TransferContent(parsed);
        }
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_layer_sublayers(uint64_t h) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<StringsOwner>();
        const auto paths = layer_owner(h).layer->GetSubLayerPaths();
        result->values.assign(paths.begin(), paths.end());
        return result;
    });
}
USDM_API int32_t usdm_layer_set_sublayers(uint64_t h, uint64_t strings) noexcept {
    return protect([&] {
        const auto &paths = strings_owner(strings).values;
        for (const auto &p : paths) require(!p.empty(), "Empty sublayer identifier");
        layer_owner(h).layer->SetSubLayerPaths(paths);
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_layer_offsets(uint64_t h) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<ValueOwner>();
        result->type = "double[]";
        for (const auto &offset : layer_owner(h).layer->GetSubLayerOffsets()) {
            result->numbers.push_back(offset.GetOffset());
            result->numbers.push_back(offset.GetScale());
        }
        return result;
    });
}
USDM_API int32_t usdm_layer_offset_set(uint64_t h, int64_t index, double offset, double scale) noexcept {
    return protect([&] {
        auto layer = layer_owner(h).layer;
        require(index >= 0 && uint64_t(index) < layer->GetSubLayerPaths().size(), "Sublayer index out of range");
        require(std::isfinite(offset) && std::isfinite(scale) && scale != 0, "Invalid sublayer time mapping");
        layer->SetSubLayerOffset(SdfLayerOffset(offset, scale), int(index));
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_namespace_open(uint64_t h, int32_t relocates) noexcept {
    return protect_owned([&] {
        require(relocates == 0 || relocates == 1, "Invalid relocates flag");
        auto result = std::make_unique<NamespaceOwner>();
        result->stage = owner(h).stage;
        UsdNamespaceEditor::EditOptions options;
        options.allowRelocatesAuthoring = relocates != 0;
        result->editor = std::make_unique<UsdNamespaceEditor>(result->stage, options);
        return result;
    });
}
USDM_API void usdm_namespace_close(uint64_t h) noexcept { delete reinterpret_cast<NamespaceOwner *>(h); }
USDM_API int32_t usdm_namespace_dependent(uint64_t h, uint64_t stage) noexcept {
    return protect([&] {
        auto &s = namespace_owner(h);
        auto dependency = owner(stage).stage;
        s.dependencies.push_back(dependency);
        s.editor->AddDependentStage(dependency);
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_namespace_queue(uint64_t h, const char *old_path, const char *new_path, int32_t property) noexcept {
    return protect([&] {
        require(old_path && *old_path && new_path && (property == 0 || property == 1), "Invalid namespace operation");
        auto old = SdfPath(old_path);
        auto next = *new_path ? SdfPath(new_path) : SdfPath();
        auto valid = [&](const SdfPath &p) { return p.IsAbsolutePath() &&
            (property ? p.IsPropertyPath() : p.IsPrimPath()) && p != SdfPath::AbsoluteRootPath(); };
        require(valid(old) && (next.IsEmpty() || valid(next)), "Invalid namespace path");
        auto &editor = *namespace_owner(h).editor;
        bool ok = property ? (next.IsEmpty() ? editor.DeletePropertyAtPath(old) : editor.MovePropertyAtPath(old, next))
                           : (next.IsEmpty() ? editor.DeletePrimAtPath(old) : editor.MovePrimAtPath(old, next));
        require(ok, "Cannot queue namespace operation");
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_namespace_check(uint64_t h) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<StringsOwner>();
        auto check = namespace_owner(h).editor->CanApplyEdits();
        for (const auto &s : check.errors) result->values.insert(result->values.end(), {"error", s});
        for (const auto &s : check.warnings) result->values.insert(result->values.end(), {"warning", s});
        return result;
    });
}
USDM_API int32_t usdm_namespace_apply(uint64_t h) noexcept {
    return protect([&] {
        auto &editor = *namespace_owner(h).editor;
        auto check = editor.CanApplyEdits();
        if (!check) {
            std::string errors;
            for (const auto &s : check.errors) errors += s + "\n";
            throw BridgeError(ErrorKind::InvalidArgument, errors);
        }
        require(editor.ApplyEdits(), "Cannot apply namespace edit", ErrorKind::Sdk);
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_edit_target(uint64_t h, uint64_t layer, const char *reference) noexcept {
    return protect_owned([&] {
        require(reference != nullptr, "Null reference prim path");
        auto result = std::make_unique<TargetOwner>();
        result->stage = owner(h).stage;
        if (!layer) {
            require(!*reference, "A reference edit target requires a layer");
            result->target = result->stage->GetEditTarget();
        } else if (!*reference) {
            auto target = layer_owner(layer).layer;
            require(result->stage->HasLocalLayer(target), "Layer is not in this stage's local layer stack");
            result->target = result->stage->GetEditTargetForLocalLayer(target);
        } else {
            auto p = prim(h, reference);
            auto wanted = layer_owner(layer).layer;
            for (const auto &node : p.GetPrimIndex().GetNodeRange()) {
                if (node.GetArcType() == PcpArcTypeRoot) continue;
                const auto &layers = node.GetLayerStack()->GetLayers();
                if (std::find(layers.begin(), layers.end(), wanted) != layers.end()) {
                    auto candidate = UsdEditTarget(wanted, node);
                    require(!result->target.IsValid() || result->target == candidate,
                            "Reference layer has ambiguous edit mappings");
                    result->target = candidate;
                }
            }
        }
        require(result->target.IsValid(), "Cannot construct this edit target");
        return result;
    });
}
USDM_API void usdm_target_close(uint64_t h) noexcept {
    delete reinterpret_cast<TargetOwner *>(h);
}
USDM_API int32_t usdm_target_set(uint64_t stage, uint64_t target) noexcept {
    return protect([&] {
        auto &t = target_owner(target);
        require(owner(stage).stage == t.stage, "Edit target belongs to another stage");
        t.stage->SetEditTarget(t.target);
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_target_map(uint64_t h, const char *path) noexcept {
    return protect_owned([&] {
        require(path && SdfPath::IsValidPathString(path), "Invalid scene path");
        auto mapped = target_owner(h).target.MapToSpecPath(SdfPath(path));
        require(!mapped.IsEmpty(), "Scene path is outside the edit target's mapping");
        return editor_text(mapped.GetString());
    });
}
USDM_API int32_t usdm_stage_save_layers(uint64_t h, int32_t session) noexcept {
    return protect([&] {
        require(session == 0 || session == 1, "Invalid save selector");
        if (session) owner(h).stage->SaveSessionLayers();
        else owner(h).stage->Save();
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_namespace_edit(uint64_t h, const char *old_path, const char *new_path) noexcept {
    return protect([&] {
        auto old = prim_path(old_path);
        require(old != SdfPath::AbsoluteRootPath(), "Cannot edit pseudo-root namespace");
        require(new_path != nullptr, "Null destination path");
        UsdNamespaceEditor editor(owner(h).stage);
        bool queued = false;
        if (*new_path) {
            auto next = prim_path(new_path);
            require(next != SdfPath::AbsoluteRootPath(), "Cannot replace pseudo-root");
            queued = editor.MovePrimAtPath(old, next);
        } else queued = editor.DeletePrimAtPath(old);
        require(queued, "Cannot queue namespace edit");
        auto can = editor.CanApplyEdits();
        if (!can) {
            std::string why;
            for (const auto &error : can.errors) why += error + "\n";
            throw BridgeError(ErrorKind::InvalidArgument, why);
        }
        require(editor.ApplyEdits(), "Cannot apply namespace edit", ErrorKind::Sdk);
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_composition_edit(uint64_t h, const char *path, const char *target, int32_t kind) noexcept {
    return protect([&] {
        auto p = prim(h, path);
        auto t = prim_path(target);
        require(kind == 0 || kind == 1, "Invalid composition arc selector");
        require(kind == 0 ? p.GetInherits().AddInherit(t) : p.GetSpecializes().AddSpecialize(t),
                "Cannot add composition arc");
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_meta_dictionary() noexcept {
    return protect_owned([] {
        auto result = std::make_unique<MetadataOwner>();
        result->value = VtValue(VtDictionary{});
        return result;
    });
}
USDM_API uint64_t usdm_meta_leaf(uint64_t value) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<MetadataOwner>();
        result->value = encode(value_owner(value));
        return result;
    });
}
USDM_API uint64_t usdm_meta_read(uint64_t h, const char *path, const char *name, const char *key, const char *dict) noexcept {
    return protect_owned([&] {
        require(path && name && (!*name || *path), "Attribute metadata requires a prim path");
        auto result = std::make_unique<MetadataOwner>();
        result->value = metadata_value(h, path, name, key, dict);
        return result;
    });
}
USDM_API void usdm_meta_close(uint64_t h) noexcept {
    delete reinterpret_cast<MetadataOwner *>(h);
}
USDM_API uint64_t usdm_meta_type(uint64_t h) noexcept {
    return protect_owned([&] { return editor_text(meta_owner(h).value.GetTypeName()); });
}
USDM_API int32_t usdm_meta_is_dictionary(uint64_t h) noexcept {
    return protect([&] { return int32_t(meta_owner(h).value.IsHolding<VtDictionary>()); }, int32_t(-1));
}
USDM_API uint64_t usdm_meta_keys(uint64_t h) noexcept {
    return protect_owned([&] {
        const auto &v = meta_owner(h).value;
        require(v.IsHolding<VtDictionary>(), "Metadata is not a dictionary", ErrorKind::TypeMismatch);
        auto result = std::make_unique<StringsOwner>();
        for (const auto &p : v.UncheckedGet<VtDictionary>()) result->values.push_back(p.first);
        std::sort(result->values.begin(), result->values.end());
        return result;
    });
}
USDM_API uint64_t usdm_meta_child(uint64_t h, const char *key) noexcept {
    return protect_owned([&] {
        require(key != nullptr, "Null dictionary key");
        const auto &v = meta_owner(h).value;
        require(v.IsHolding<VtDictionary>(), "Metadata is not a dictionary", ErrorKind::TypeMismatch);
        const auto &d = v.UncheckedGet<VtDictionary>();
        auto p = d.find(key);
        require(p != d.end(), "Dictionary key does not exist", ErrorKind::NotFound);
        auto result = std::make_unique<MetadataOwner>();
        result->value = p->second;
        return result;
    });
}
USDM_API int32_t usdm_meta_set_child(uint64_t h, const char *key, uint64_t child, int32_t erase) noexcept {
    return protect([&] {
        require(key != nullptr && (erase == 0 || erase == 1), "Invalid dictionary edit arguments");
        auto &v = meta_owner(h).value;
        require(v.IsHolding<VtDictionary>(), "Metadata is not a dictionary", ErrorKind::TypeMismatch);
        auto copy = v.UncheckedGet<VtDictionary>();
        if (erase) copy.erase(key);
        else copy[key] = meta_owner(child).value;
        v = VtValue(std::move(copy));
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_meta_value(uint64_t h) noexcept {
    return protect_owned([&] {
        const auto &v = meta_owner(h).value;
        auto type = SdfGetValueTypeNameForValue(v);
        require(bool(type), "Metadata is not a supported base value; retain its SDK value or inspect dictionary keys", ErrorKind::Unsupported);
        auto result = std::make_unique<ValueOwner>();
        result->type = type.GetAsToken().GetString();
        decode(*result, v);
        return result;
    });
}
USDM_API int32_t usdm_meta_write(uint64_t h, const char *path, const char *name, const char *key, const char *dict, uint64_t metadata, int32_t clear) noexcept {
    return protect([&] {
        require(path && name && key && *key && dict && (clear == 0 || clear == 1), "Invalid metadata authoring arguments");
        require(!*name || *path, "Attribute metadata requires a prim path");
        VtValue value;
        if (!clear) value = meta_owner(metadata).value;
        auto edit = [&](auto &&object) {
            if (*dict) return clear ? object.ClearMetadataByDictKey(TfToken(key), TfToken(dict)) : object.SetMetadataByDictKey(TfToken(key), TfToken(dict), value);
            return clear ? object.ClearMetadata(TfToken(key)) : object.SetMetadata(TfToken(key), value);
        };
        bool ok;
        if (!*path) ok = edit(*owner(h).stage);
        else if (!*name) ok = edit(prim(h, path));
        else ok = edit(attribute(h, path, name));
        require(ok, "Cannot author metadata", ErrorKind::Sdk);
        return int32_t(0);
    }, int32_t(-1));
}

namespace {
SdfSpecHandle editor_spec(uint64_t h, const char *path) {
    require(path && SdfPath::IsValidPathString(path), "Invalid layer spec path");
    SdfPath p(path);
    require(p.IsAbsolutePath(), "Layer spec path must be absolute");
    auto spec = layer_owner(h).layer->GetObjectAtPath(p);
    require(bool(spec), "Layer spec does not exist", ErrorKind::NotFound);
    return spec;
}
template <class T> SdfListOp<T> editor_list(const std::vector<T> &items, int32_t op) {
    require(op >= 0 && op <= 5, "Invalid list operation");
    SdfListOp<T> result;
    std::string why;
    bool valid = true;
    if (op == 0) valid = result.SetExplicitItems(items, &why);
    else if (op == 1) valid = result.SetPrependedItems(items, &why);
    else if (op == 2) valid = result.SetAppendedItems(items, &why);
    else if (op == 3) valid = result.SetDeletedItems(items, &why);
    else if (op == 4) result.SetAddedItems(items);
    else result.SetOrderedItems(items);
    require(valid, why);
    return result;
}
template <class T> const std::vector<T> &editor_items(const SdfListOp<T> &list, int32_t op) {
    require(op >= 0 && op <= 5, "Invalid list operation");
    if (op == 0) return list.GetExplicitItems();
    if (op == 1) return list.GetPrependedItems();
    if (op == 2) return list.GetAppendedItems();
    if (op == 3) return list.GetDeletedItems();
    if (op == 4) return list.GetAddedItems();
    return list.GetOrderedItems();
}
const std::string &editor_item_text(const std::string &value) { return value; }
std::string editor_item_text(const TfToken &value) { return value.GetString(); }
std::string editor_item_text(const SdfPath &value) { return value.GetString(); }
template <class T> std::unique_ptr<StringsOwner> editor_list_strings(const VtValue &value, int32_t op) {
    auto result = std::make_unique<StringsOwner>();
    for (const auto &v : editor_items(value.UncheckedGet<SdfListOp<T>>(), op))
        result->values.push_back(editor_item_text(v));
    return result;
}
template <class F> auto editor_arc(const VtValue &value, int32_t op, int64_t index, F &&fn) {
    require(index >= 0, "Negative composition arc index");
    if (value.IsHolding<SdfReferenceListOp>()) {
        const auto &items = editor_items(value.UncheckedGet<SdfReferenceListOp>(), op);
        require(uint64_t(index) < items.size(), "Composition arc index outside list");
        return fn(items[size_t(index)]);
    }
    require(value.IsHolding<SdfPayloadListOp>(), "Metadata is not a reference or payload list", ErrorKind::TypeMismatch);
    const auto &items = editor_items(value.UncheckedGet<SdfPayloadListOp>(), op);
    require(uint64_t(index) < items.size(), "Composition arc index outside list");
    return fn(items[size_t(index)]);
}
}
USDM_API uint64_t usdm_layer_metadata(uint64_t h, const char *path, const char *key) noexcept {
    return protect_owned([&] {
        require(key && *key, "Empty layer field key");
        auto spec = editor_spec(h, path);
        require(spec->HasInfo(TfToken(key)), "Layer has no authored field", ErrorKind::NotFound);
        auto result = std::make_unique<MetadataOwner>();
        result->value = spec->GetInfo(TfToken(key));
        return result;
    });
}
USDM_API int32_t usdm_layer_set_metadata(uint64_t h, const char *path, const char *key, uint64_t metadata, int32_t clear) noexcept {
    return protect([&] {
        require(key && *key && (clear == 0 || clear == 1), "Invalid layer field arguments");
        auto spec = editor_spec(h, path);
        if (clear) spec->ClearInfo(TfToken(key));
        else spec->SetInfo(TfToken(key), meta_owner(metadata).value);
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_layer_field_names(uint64_t h, const char *path) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<StringsOwner>();
        for (const auto &key : editor_spec(h, path)->ListInfoKeys()) result->values.push_back(key.GetString());
        std::sort(result->values.begin(), result->values.end());
        return result;
    });
}
USDM_API uint64_t usdm_meta_string_list(uint64_t items, int32_t op, int32_t kind) noexcept {
    return protect_owned([&] {
        require(kind >= 0 && kind <= 2, "Invalid list item kind");
        const auto &values = strings_owner(items).values;
        auto result = std::make_unique<MetadataOwner>();
        if (kind == 0) {
            std::vector<SdfPath> paths;
            for (const auto &v : values) {
                require(SdfPath::IsValidPathString(v), "Invalid list path");
                paths.emplace_back(v);
            }
            result->value = VtValue(editor_list(paths, op));
        } else if (kind == 1) {
            std::vector<TfToken> tokens;
            for (const auto &v : values) tokens.emplace_back(v);
            result->value = VtValue(editor_list(tokens, op));
        } else result->value = VtValue(editor_list(values, op));
        return result;
    });
}
USDM_API uint64_t usdm_meta_list_strings(uint64_t h, int32_t op) noexcept {
    return protect_owned([&] {
        const auto &v = meta_owner(h).value;
        if (v.IsHolding<SdfPathListOp>()) return editor_list_strings<SdfPath>(v, op);
        if (v.IsHolding<SdfTokenListOp>()) return editor_list_strings<TfToken>(v, op);
        require(v.IsHolding<SdfStringListOp>(), "Metadata is not a path, token or string list", ErrorKind::TypeMismatch);
        return editor_list_strings<std::string>(v, op);
    });
}
USDM_API uint64_t usdm_meta_arcs(uint64_t assets, uint64_t prims, uint64_t times, int32_t op, int32_t payload) noexcept {
    return protect_owned([&] {
        require(payload == 0 || payload == 1, "Invalid composition arc kind");
        const auto &a = strings_owner(assets).values;
        const auto &p = strings_owner(prims).values;
        const auto &t = value_owner(times);
        require(t.type == "double[]" && t.signed_values.empty() && t.unsigned_values.empty() && t.texts.empty(), "Invalid arc times");
        require(a.size() == p.size() && a.size() <= std::numeric_limits<size_t>::max() / 2 && t.numbers.size() == 2 * a.size(), "Composition arc arrays differ in length");
        std::vector<SdfReference> references;
        std::vector<SdfPayload> payloads;
        for (size_t i = 0; i < a.size(); ++i) {
            require(!a[i].empty() || !p[i].empty(), "Empty composition arc");
            auto path = p[i].empty() ? SdfPath() : prim_path(p[i].c_str());
            require(std::isfinite(t.numbers[2*i]) && std::isfinite(t.numbers[2*i+1]) && t.numbers[2*i+1] != 0, "Invalid composition time offset/scale");
            SdfLayerOffset offset(t.numbers[2*i], t.numbers[2*i+1]);
            if (payload) payloads.emplace_back(a[i], path, offset);
            else references.emplace_back(a[i], path, offset);
        }
        auto result = std::make_unique<MetadataOwner>();
        if (payload) result->value = VtValue(editor_list(payloads, op));
        else result->value = VtValue(editor_list(references, op));
        return result;
    });
}
USDM_API int64_t usdm_meta_arc_count(uint64_t h, int32_t op) noexcept {
    return protect([&] {
        const auto &v = meta_owner(h).value;
        if (v.IsHolding<SdfReferenceListOp>()) return int64_t(editor_items(v.UncheckedGet<SdfReferenceListOp>(), op).size());
        require(v.IsHolding<SdfPayloadListOp>(), "Metadata is not a composition arc list", ErrorKind::TypeMismatch);
        return int64_t(editor_items(v.UncheckedGet<SdfPayloadListOp>(), op).size());
    }, int64_t(-1));
}
USDM_API uint64_t usdm_meta_arc_text(uint64_t h, int32_t op, int64_t index, int32_t kind) noexcept {
    return protect_owned([&] {
        require(kind == 0 || kind == 1, "Invalid composition arc field");
        return editor_arc(meta_owner(h).value, op, index, [&](const auto &a) {
            return editor_text(kind == 0 ? a.GetAssetPath() : a.GetPrimPath().GetString());
        });
    });
}
USDM_API int32_t usdm_meta_arc_times(uint64_t h, int32_t op, int64_t index, double *out, int64_t count) noexcept {
    return protect([&] {
        require(out && count == 2, "Composition time output must have two components");
        const auto offset = editor_arc(meta_owner(h).value, op, index, [](const auto &a) { return a.GetLayerOffset(); });
        out[0] = offset.GetOffset();
        out[1] = offset.GetScale();
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_layer_remove_variant(uint64_t h, const char *path, const char *set, const char *variant) noexcept {
    return protect([&] {
        require(set && *set && variant, "Variant set/name is required");
        auto layer=layer_owner(h).layer;auto spec=layer->GetPrimAtPath(prim_path(path));
        require(bool(spec),"Layer prim does not exist",ErrorKind::NotFound);
        auto sets=spec->GetVariantSets();auto found=sets.find(set);
        require(found!=sets.end(),"Variant set does not exist in this layer",ErrorKind::NotFound);
        SdfVariantSetSpecHandle set_spec = found->second;
        if(!*variant)spec->RemoveVariantSet(set);
        else {
            auto variants=set_spec->GetVariants();auto v=variants.find(variant);
            require(v!=variants.end(),"Variant does not exist in this layer",ErrorKind::NotFound);
            set_spec->RemoveVariant(*v);
        }
        return int32_t(0);
    },int32_t(-1));
}
USDM_API int32_t usdm_layer_override(uint64_t h, const char *path) noexcept {
    return protect([&] {
        require(path && SdfPath::IsValidPathString(path), "Invalid layer prim path");
        SdfPath p(path);
        require(p.IsAbsolutePath() && (p.IsPrimPath() || p.IsPrimVariantSelectionPath()) && p != SdfPath::AbsoluteRootPath(), "Expected an absolute layer prim path");
        auto layer=layer_owner(h).layer;
        require(layer->PermissionToEdit(),"Layer is not editable");
        require(bool(SdfCreatePrimInLayer(layer,p)),"Cannot create local prim spec");
        return int32_t(0);
    },int32_t(-1));
}
