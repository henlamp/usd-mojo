// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
#include <pxr/usd/sdf/changeBlock.h>
#include <pxr/usd/sdf/attributeSpec.h>
#include <pxr/usd/sdf/primSpec.h>
#include <unordered_map>

namespace {
struct AttributeEditOwner {
    SdfPath scene_path, spec_path;
    TfToken name;
    SdfValueTypeName type;
    VtValue value;
    UsdTimeCode time;
    bool custom = true;
    SdfVariability variability = SdfVariabilityVarying;
    SdfAttributeSpecHandle authored;
};
struct BatchOwner { std::vector<AttributeEditOwner> edits; };
BatchOwner &batch_owner(uint64_t h) {
    require(h != 0, "Attribute batch is closed");
    return *reinterpret_cast<BatchOwner *>(h);
}
}
USDM_API int32_t usdm_override_prim(uint64_t h, const char *path, int32_t kind) noexcept {
    return protect([&] {
        require(kind == 0 || kind == 1, "Invalid prim specifier selector");
        auto p = prim_path(path);
        require(p != SdfPath::AbsoluteRootPath(), "Cannot override pseudo-root");
        auto result = kind == 0 ? owner(h).stage->OverridePrim(p) : owner(h).stage->CreateClassPrim(p);
        require(bool(result), "Cannot author prim specifier");
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_set_active(uint64_t h, const char *path, int32_t active) noexcept {
    return protect([&] {
        require(active == 0 || active == 1, "Invalid activation flag");
        require(prim(h, path).SetActive(active != 0), "Cannot author activation");
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_attribute_create(uint64_t h, const char *path, const char *name, const char *type, int32_t custom, int32_t uniform) noexcept {
    return protect([&] {
        require(type && *type && (custom == 0 || custom == 1) && (uniform == 0 || uniform == 1), "Invalid attribute declaration");
        auto t = SdfSchema::GetInstance().FindType(TfToken(type));
        require(bool(t), "Unknown USD attribute type", ErrorKind::Unsupported);
        auto p = prim(h, path);
        auto n = attr_name(name);
        auto existing = p.GetAttribute(n);
        require(!existing || existing.GetTypeName() == t, "Existing attribute has a different USD type");
        require(bool(p.CreateAttribute(n, t, custom != 0,
            uniform ? SdfVariabilityUniform : SdfVariabilityVarying)), "Cannot create attribute");
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_attribute_edit(uint64_t h, const char *path, const char *name, int32_t kind, double t, int32_t d) noexcept {
    return protect([&] {
        require(kind >= 0 && kind <= 3, "Invalid attribute mutation");
        auto a = attribute(h, path, name);
        auto tc = time_code(t, d);
        if (kind == 0) require(a.Clear(), "Cannot clear attribute values");
        else if (kind == 1) require(a.ClearAtTime(tc), "Cannot clear attribute value at time");
        else if (kind == 2) a.Block();
        else require(a.Set(SdfValueBlock(), tc), "Cannot block attribute value at time");
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_remove_property(uint64_t h, const char *path, const char *name) noexcept {
    return protect([&] {
        require(prim(h, path).RemoveProperty(attr_name(name)), "Cannot remove property opinion from edit target");
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_property_paths_set(uint64_t h, const char *path, const char *name, uint64_t paths, int32_t kind) noexcept {
    return protect([&] {
        require(kind >= 0 && kind <= 2, "Invalid property path operation");
        SdfPathVector values;
        for (const auto &text : strings_owner(paths).values) {
            require(SdfPath::IsValidPathString(text), "Invalid property target path");
            SdfPath value(text);
            require(value.IsAbsoluteRootOrPrimPath() || value.IsPropertyPath(), "Expected a prim/property target path");
            values.push_back(value);
        }
        if (kind == 2) {
            auto p = prim(h, path);
            auto n = attr_name(name);
            auto rel = p.GetRelationship(n);
            if (!rel) rel = p.CreateRelationship(n, true);
            require(rel.SetTargets(values), "Cannot set relationship targets");
        } else {
            auto a = attribute(h, path, name);
            require(kind == 0 ? a.SetConnections(values) : a.ClearConnections(), "Cannot edit attribute connections");
        }
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_batch_new() noexcept {
    return protect_owned([] { return std::make_unique<BatchOwner>(); });
}
USDM_API void usdm_batch_close(uint64_t h) noexcept { delete reinterpret_cast<BatchOwner *>(h); }
USDM_API int32_t usdm_batch_append(uint64_t h, const char *path, const char *name, uint64_t value, double t, int32_t d) noexcept {
    return protect([&] {
        AttributeEditOwner edit;
        edit.scene_path = prim_path(path);
        require(edit.scene_path != SdfPath::AbsoluteRootPath(), "Cannot author attribute on pseudo-root");
        edit.name = attr_name(name);
        edit.time = time_code(t, d);
        const auto &input = value_owner(value);
        edit.value = encode(input);
        edit.type = SdfSchema::GetInstance().FindType(TfToken(input.type));
        batch_owner(h).edits.push_back(std::move(edit));
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_batch_apply(uint64_t h, uint64_t batch) noexcept {
    return protect([&] {
        auto stage = owner(h).stage;
        auto target = stage->GetEditTarget();
        auto layer = target.GetLayer();
        require(layer && layer->PermissionToEdit(), "Edit target layer is not editable");
        auto &edits = batch_owner(batch).edits;
        std::unordered_map<SdfPath, SdfValueTypeName, SdfPath::Hash> types;
        types.reserve(edits.size());
        // Finish all USD queries/validation before entering SdfChangeBlock.
        for (auto &edit : edits) {
            auto p = stage->GetPrimAtPath(edit.scene_path);
            require(bool(p), "Batch prim does not exist", ErrorKind::NotFound);
            require(!p.IsInstanceProxy() && !p.IsInPrototype(), "Cannot batch-author instance/prototype properties");
            edit.spec_path = target.MapToSpecPath(edit.scene_path.AppendProperty(edit.name));
            require(!edit.spec_path.IsEmpty(), "Attribute is outside the edit target mapping");
            auto property = p.GetProperty(edit.name);
            require(!property || property.Is<UsdAttribute>(), "Batch attribute conflicts with a relationship");
            auto existing = p.GetAttribute(edit.name);
            if (existing) {
                require(existing.GetTypeName() == edit.type, "Existing attribute has a different USD type");
                edit.custom = existing.IsCustom();
                edit.variability = existing.GetVariability();
            }
            auto spec = layer->GetObjectAtPath(edit.spec_path);
            require(!spec || spec->GetSpecType() == SdfSpecTypeAttribute,
                    "Edit target contains a non-attribute property spec");
            edit.authored = layer->GetAttributeAtPath(edit.spec_path);
            require(!edit.authored || edit.authored->GetTypeName() == edit.type, "Authored attribute has a different USD type");
            auto inserted = types.emplace(edit.spec_path, edit.type);
            require(inserted.second || inserted.first->second == edit.type, "Batch contains conflicting attribute types");
        }
        const auto &offset = target.GetMapFunction().GetTimeOffset();
        bool needs_usd_time_mapping = offset.GetOffset() != 0 || offset.GetScale() != 1;
        for (const auto &edit : edits)
            needs_usd_time_mapping = needs_usd_time_mapping || edit.value.IsHolding<SdfTimeCode>() ||
                edit.value.IsHolding<VtArray<SdfTimeCode>>();
        if (needs_usd_time_mapping) {
            // Usd handles both sample-time and timecode-valued data conversion.
            // It must not run inside SdfChangeBlock while composition is deferred.
            for (const auto &edit : edits) {
                auto p = stage->GetPrimAtPath(edit.scene_path);
                auto a = p.GetAttribute(edit.name);
                if (!a) a = p.CreateAttribute(edit.name, edit.type, edit.custom, edit.variability);
                require(a.Set(edit.value, edit.time), "Cannot author mapped attribute value");
            }
            return int32_t(0);
        }
        {
            SdfChangeBlock changes;
            // Only Sdf APIs are safe while stage recomposition is deferred.
            for (const auto &edit : edits) {
                auto attribute_spec = edit.authored ? edit.authored : layer->GetAttributeAtPath(edit.spec_path);
                if (!attribute_spec) {
                    auto parent = SdfCreatePrimInLayer(layer, edit.spec_path.GetParentPath());
                    require(bool(parent), "Cannot create attribute's prim spec");
                    attribute_spec = SdfAttributeSpec::New(parent, edit.name.GetString(), edit.type, edit.variability, edit.custom);
                }
                require(bool(attribute_spec), "Cannot create attribute spec");
                if (edit.time.IsDefault()) require(attribute_spec->SetDefaultValue(edit.value), "Cannot set attribute default");
                else layer->SetTimeSample(edit.spec_path, edit.time.GetValue(), edit.value);
            }
        }
        return int32_t(0);
    }, int32_t(-1));
}
