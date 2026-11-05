// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
namespace {
struct ChangeOwner {
    uint64_t generation = 0;
    bool all_dirty = false;
    std::vector<std::string> resynced, changed;
};
struct SceneOwner {
    UsdStageRefPtr frozen;
    uint64_t generation;
    std::vector<std::string> paths, types, prototypes;
    VtMatrix4dArray transforms;
};
SceneOwner &scene_owner(uint64_t h) {
    require(h != 0, "Scene snapshot is closed");
    return *reinterpret_cast<SceneOwner *>(h);
}
ChangeOwner &change_owner(uint64_t h) {
    require(h != 0, "Change snapshot is closed");
    return *reinterpret_cast<ChangeOwner *>(h);
}
}
USDM_API uint64_t usdm_changes(uint64_t h) noexcept {
    return protect_owned([&] {
        auto &s = owner(h);
        auto result = std::make_unique<ChangeOwner>();
        result->generation = s.generation;
        result->all_dirty = s.all_dirty;
        for (const auto &p : s.resynced) result->resynced.push_back(p.GetString());
        for (const auto &p : s.changed) result->changed.push_back(p.GetString());
        return result;
    });
}
USDM_API void usdm_changes_close(uint64_t h) noexcept { delete reinterpret_cast<ChangeOwner *>(h); }
USDM_API int32_t usdm_changes_ack(uint64_t h) noexcept {
    return protect([&] {
        auto &s = owner(h);
        s.resynced.clear(); s.changed.clear(); s.all_dirty = false;
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_changes_info(uint64_t h, uint64_t *data, int64_t count) noexcept {
    return protect([&] {
        require(data && count == 2, "Invalid change metadata buffer");
        auto &s = change_owner(h);
        data[0] = s.generation; data[1] = s.all_dirty;
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_changes_paths(uint64_t h, int32_t kind) noexcept {
    return protect_owned([&] {
        require(kind == 0 || kind == 1, "Invalid change path selector");
        auto result = std::make_unique<StringsOwner>();
        auto &s = change_owner(h);
        result->values = kind == 0 ? s.resynced : s.changed;
        return result;
    });
}
USDM_API uint64_t usdm_scene_snapshot(uint64_t h, double t, int32_t d) noexcept {
    return protect_owned([&] {
        auto &source = owner(h);
        require_flatten_metadata(source);
        auto result = std::make_unique<SceneOwner>();
        result->generation = source.generation;
        // Flatten includes the session and selected working set. This is an evaluated
        // snapshot, not a replacement for original layers, variants or provenance.
        result->frozen = UsdStage::Open(source.stage->Flatten());
        require(bool(result->frozen), "Cannot freeze scene", ErrorKind::Sdk);
        UsdGeomXformCache cache(time_code(t, d));
        for (const auto &p : UsdPrimRange::Stage(result->frozen)) {
            result->paths.push_back(p.GetPath().GetString());
            result->types.push_back(p.GetTypeName().GetString());
            auto proto = p.GetPrototype();
            result->prototypes.push_back(proto ? proto.GetPath().GetString() : "");
            result->transforms.push_back(cache.GetLocalToWorldTransform(p));
        }
        return result;
    });
}
USDM_API void usdm_scene_close(uint64_t h) noexcept { delete reinterpret_cast<SceneOwner *>(h); }
USDM_API int32_t usdm_scene_info(uint64_t h, uint64_t *data, int64_t count) noexcept {
    return protect([&] {
        require(data && count == 3, "Invalid scene metadata buffer");
        auto &s = scene_owner(h);
        static_assert(sizeof(GfMatrix4d) == 16 * sizeof(double), "Contiguous matrices required");
        data[0] = s.generation; data[1] = s.transforms.size() * 16;
        data[2] = reinterpret_cast<uint64_t>(s.transforms.cdata());
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_scene_paths(uint64_t h, int32_t kind) noexcept {
    return protect_owned([&] {
        require(kind >= 0 && kind <= 2, "Invalid scene path selector");
        auto &s = scene_owner(h);
        auto result = std::make_unique<StringsOwner>();
        result->values = kind == 0 ? s.paths : kind == 1 ? s.types : s.prototypes;
        return result;
    });
}
USDM_API uint64_t usdm_scene_transforms(uint64_t h) noexcept {
    return protect_owned([&] { return domain_value(VtValue(scene_owner(h).transforms)); });
}
USDM_API uint64_t usdm_scene_value(uint64_t h, const char *path, const char *name, double t, int32_t d) noexcept {
    return protect_owned([&] {
        auto p = scene_owner(h).frozen->GetPrimAtPath(prim_path(path));
        require(bool(p), "Snapshot prim does not exist", ErrorKind::NotFound);
        require(name && *name, "Empty snapshot attribute name");
        auto a = p.GetAttribute(TfToken(name));
        require(bool(a), "Snapshot attribute does not exist", ErrorKind::NotFound);
        VtValue value;
        require(a.Get(&value, time_code(t, d)), "Snapshot attribute has no value", ErrorKind::NotFound);
        return domain_value(value, a.GetTypeName().GetAsToken().GetString());
    });
}
USDM_API int32_t usdm_scene_export(uint64_t h, const char *filename) noexcept {
    return protect([&] {
        require(filename && *filename, "Empty snapshot export filename");
        require(scene_owner(h).frozen->Export(filename), "Cannot export scene snapshot", ErrorKind::Io);
        return int32_t(0);
    }, int32_t(-1));
}
