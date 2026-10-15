// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
// General USD information. Semantic interpretation belongs to consumers.
namespace {
struct StringsOwner {
    std::vector<std::string> values;
};
StringsOwner &strings_owner(uint64_t h) {
    require(h != 0, "String snapshot is closed");
    return *reinterpret_cast<StringsOwner *>(h);
}
UsdMetadataValueMap metadata_map(uint64_t h, const char *path, const char *name) {
    if (!path || !*path)
        return owner(h).stage->GetPseudoRoot().GetAllMetadata();
    if (!name || !*name)
        return prim(h, path).GetAllMetadata();
    return attribute(h, path, name).GetAllMetadata();
}
VtValue metadata_value(uint64_t h, const char *path, const char *name, const char *key,
                       const char *dict) {
    require(key && *key, "Empty metadata key");
    VtValue value;
    bool ok = false;
    TfToken k(key);
    if (!path || !*path)
        ok = dict && *dict
                 ? owner(h).stage->GetMetadataByDictKey(k, TfToken(dict), &value)
                 : owner(h).stage->GetMetadata(k, &value);
    else if (!name || !*name)
        ok = dict && *dict
                 ? prim(h, path).GetMetadataByDictKey(k, TfToken(dict), &value)
                 : prim(h, path).GetMetadata(k, &value);
    else
        ok = dict && *dict ? attribute(h, path, name)
                                 .GetMetadataByDictKey(k, TfToken(dict), &value)
                           : attribute(h, path, name).GetMetadata(k, &value);
    require(ok, "Metadata key has no value", ErrorKind::NotFound);
    return value;
}
std::unique_ptr<StringsOwner> information(uint64_t h, int32_t kind, const char *path,
                                          const char *name, const char *key,
                                          const char *dict) {
    auto o = std::make_unique<StringsOwner>();
    auto stage = owner(h).stage;
    if (kind == 0) {
        for (const auto &p : stage->FindLoadable())
            o->values.push_back(p.GetString());
    } else if (kind == 1) {
        for (const auto &p : stage->GetLoadSet())
            o->values.push_back(p.GetString());
    } else if (kind == 2) {
        for (const auto &p : stage->GetPrototypes())
            o->values.push_back(p.GetPath().GetString());
    } else if (kind == 3) {
        for (const auto &layer : stage->GetLayerStack())
            o->values.push_back(layer->GetIdentifier());
    } else if (kind == 4) {
        o->values = prim(h, path).GetVariantSets().GetNames();
    } else if (kind == 5) {
        auto vs = prim(h, path).GetVariantSets();
        require(vs.HasVariantSet(name), "Variant set does not exist",
                ErrorKind::NotFound);
        o->values = vs.GetVariantSet(name).GetVariantNames();
    } else if (kind == 6) {
        auto vs = prim(h, path).GetVariantSets();
        require(vs.HasVariantSet(name), "Variant set does not exist",
                ErrorKind::NotFound);
        o->values.push_back(vs.GetVariantSet(name).GetVariantSelection());
    } else if (kind == 7) {
        auto p = prim(h, path);
        auto proto = p.IsInstanceProxy() ? p.GetPrimInPrototype() : p.GetPrototype();
        o->values.push_back(proto ? proto.GetPath().GetString() : "");
    } else if (kind == 8) {
        o->values.push_back(
            attribute(h, path, name).GetTypeName().GetAsToken().GetString());
    } else if (kind == 9) {
        for (const auto &item : metadata_map(h, path, name))
            o->values.push_back(item.first.GetString());
    } else if (kind == 10) {
        auto v = metadata_value(h, path, name, key, dict);
        require(v.IsHolding<VtDictionary>(), "Expected dictionary metadata",
                ErrorKind::TypeMismatch);
        for (const auto &item : v.UncheckedGet<VtDictionary>())
            o->values.push_back(item.first);
    } else if (kind == 11) {
        SdfPathVector paths;
        auto a = attribute(h, path, name);
        require(a.GetConnections(&paths) || !a.HasAuthoredConnections(),
                "Cannot read attribute connections");
        for (const auto &p : paths)
            o->values.push_back(p.GetString());
    } else if (kind == 12) {
        for (const auto &e : stage->GetCompositionErrors())
            o->values.push_back(e->ToString());
    } else if (kind == 13) {
        for (const auto &p : UsdPrimRange::Stage(stage, UsdTraverseInstanceProxies()))
            o->values.push_back(p.GetPath().GetString());
    } else if (kind == 14) {
        for (const auto &p : stage->TraverseAll())
            o->values.push_back(p.GetPath().GetString());
    } else
        throw BridgeError(ErrorKind::Internal, "Unknown information query");
    return o;
}
} // namespace
USDM_API uint64_t usdm_information(uint64_t h, int32_t kind, const char *path,
                                   const char *name, const char *key,
                                   const char *dict) noexcept {
    return protect_owned([&]() { return information(h, kind, path, name, key, dict); });
}
USDM_API int64_t usdm_strings_count(uint64_t h) noexcept {
    return protect([&]() { return int64_t(strings_owner(h).values.size()); },
                   int64_t(-1));
}
USDM_API int64_t usdm_strings_text(uint64_t h, int64_t index, char *dst,
                                   int64_t capacity) noexcept {
    return protect(
        [&]() {
            auto &v = strings_owner(h).values;
            require(index >= 0 && uint64_t(index) < v.size(),
                    "String index outside snapshot");
            return copy_text(v[size_t(index)], dst, capacity);
        },
        int64_t(-1));
}
USDM_API int64_t usdm_strings_text_size(uint64_t h, int64_t index) noexcept {
    return usdm_strings_text(h, index, nullptr, 0);
}
USDM_API void usdm_strings_close(uint64_t h) noexcept {
    delete reinterpret_cast<StringsOwner *>(h);
}
USDM_API uint64_t usdm_stage_open_policy(const char *path, int32_t load_all) noexcept {
    return protect_owned([&]() {
        require(path && *path, "Empty stage filename");
        require(load_all == 0 || load_all == 1, "Invalid load policy");
        TfErrorMark diagnostics;
        preflight_local_crate(path);
        auto stage =
            UsdStage::Open(path, load_all ? UsdStage::LoadAll : UsdStage::LoadNone);
        require(bool(stage), "Cannot open USD stage", ErrorKind::Io);
        check_diagnostics(diagnostics);
        auto o = std::make_unique<StageOwner>();
        o->stage = stage;
        return o;
    });
}
USDM_API int32_t usdm_payload(uint64_t h, const char *path, int32_t loaded) noexcept {
    return protect(
        [&]() {
            require(loaded == 0 || loaded == 1, "Invalid load flag");
            auto s = owner(h).stage;
            auto p = prim(h, path);
            require(p.IsActive() && !p.IsInPrototype(),
                    "Cannot load inactive/prototype prim");
            if (loaded)
                s->Load(prim_path(path));
            else
                s->Unload(prim_path(path));
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_add_payload(uint64_t h, const char *path, const char *asset,
                                  const char *target) noexcept {
    return protect(
        [&]() {
            SdfPath t;
            if (target && *target)
                t = prim_path(target);
            require(prim(h, path).GetPayloads().AddPayload(
                        SdfPayload(asset ? asset : "", t)),
                    "Cannot author payload");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_prim_flags(uint64_t h, const char *path, int32_t *flags,
                                 int64_t size) noexcept {
    return protect(
        [&]() {
            require(flags && size == 7, "Prim flags extent mismatch");
            auto p = prim(h, path);
            flags[0] = p.IsActive();
            flags[1] = p.IsDefined();
            flags[2] = p.IsAbstract();
            flags[3] = p.IsLoaded();
            flags[4] = p.HasPayload();
            flags[5] = p.IsInstance();
            flags[6] = p.IsInstanceProxy();
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_set_instanceable(uint64_t h, const char *path,
                                       int32_t enabled) noexcept {
    return protect(
        [&]() {
            require(enabled == 0 || enabled == 1, "Invalid instance flag");
            require(prim(h, path).SetInstanceable(enabled != 0),
                    "Cannot set instanceable");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_stage_info(uint64_t h, double *values, int64_t size) noexcept {
    return protect(
        [&]() {
            require(values && size == 5, "Stage information extent mismatch");
            auto s = owner(h).stage;
            values[0] = s->GetStartTimeCode();
            values[1] = s->GetEndTimeCode();
            values[2] = s->GetTimeCodesPerSecond();
            values[3] = s->GetFramesPerSecond();
            values[4] = s->HasAuthoredTimeCodeRange();
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_time_range(uint64_t h, double start, double end, double tps,
                                 double fps) noexcept {
    return protect(
        [&]() {
            require(std::isfinite(start) && std::isfinite(end) && start <= end &&
                        std::isfinite(tps) && std::isfinite(fps) && tps > 0 && fps > 0,
                    "Invalid time range/rates");
            auto s = owner(h).stage;
            s->SetStartTimeCode(start);
            s->SetEndTimeCode(end);
            s->SetTimeCodesPerSecond(tps);
            s->SetFramesPerSecond(fps);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API uint64_t usdm_time_samples(uint64_t h, const char *path,
                                    const char *name) noexcept {
    return protect_owned([&]() {
        auto o = std::make_unique<ArrayOwner>();
        require(attribute(h, path, name).GetTimeSamples(&o->values),
                "Cannot read time samples");
        return o;
    });
}
USDM_API uint64_t usdm_asset_paths(uint64_t h, const char *path, const char *name,
                                   double time, int32_t is_default,
                                   int64_t index) noexcept {
    return protect_owned([&]() {
        auto a = attribute(h, path, name);
        SdfAssetPath v;
        auto tc = time_code(time, is_default);
        if (a.GetTypeName().IsArray()) {
            auto values = read<VtArray<SdfAssetPath>>(a, tc);
            require(index >= 0 && uint64_t(index) < values.size(),
                    "Asset array index outside range");
            v = values[size_t(index)];
        } else {
            require(index == 0, "Scalar asset requires index zero");
            v = read<SdfAssetPath>(a, tc);
        }
        auto o = std::make_unique<StringsOwner>();
        o->values = {v.GetAuthoredPath(), v.GetEvaluatedPath(), v.GetResolvedPath()};
        return o;
    });
}
USDM_API int32_t usdm_primvar_info(uint64_t h, const char *path, const char *name,
                                   int64_t *values, int64_t size) noexcept {
    return protect(
        [&]() {
            require(values && size == 2, "Primvar info extent mismatch");
            UsdGeomPrimvar p(attribute(h, path, name));
            require(bool(p), "Attribute is not a primvar", ErrorKind::TypeMismatch);
            values[0] = p.GetElementSize();
            values[1] = p.GetUnauthoredValuesIndex();
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API uint64_t usdm_primvar_interpolation(uint64_t h, const char *path,
                                             const char *name,
                                             int32_t normals) noexcept {
    return protect_owned([&]() {
        auto o = std::make_unique<TextOwner>();
        if (normals) {
            UsdGeomMesh m(prim(h, path));
            require(bool(m), "Normals require a mesh", ErrorKind::TypeMismatch);
            o->text = m.GetNormalsInterpolation().GetString();
        } else {
            UsdGeomPrimvar p(attribute(h, path, name));
            require(bool(p), "Attribute is not a primvar", ErrorKind::TypeMismatch);
            o->text = p.GetInterpolation().GetString();
        }
        return o;
    });
}
USDM_API uint64_t usdm_metadata_read(uint64_t h, const char *path, const char *name,
                                     const char *key, const char *dict) noexcept {
    return protect_owned([&]() {
        auto value = metadata_value(h, path, name, key, dict);
        auto type = SdfGetValueTypeNameForValue(value);
        require(bool(type),
                "Metadata value is not a supported USD base type; use "
                "dictionary keys for dictionaries",
                ErrorKind::Unsupported);
        auto o = std::make_unique<ValueOwner>();
        o->type = type.GetAsToken().GetString();
        decode(*o, value);
        return o;
    });
}
