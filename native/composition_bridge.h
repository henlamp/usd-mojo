// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
#include <pxr/usd/usd/stagePopulationMask.h>
#include <pxr/usd/usd/stageLoadRules.h>
#include <pxr/base/tf/enum.h>
#include <set>
#include <pxr/base/plug/registry.h>
#include <pxr/base/plug/plugin.h>
#include <pxr/usd/ar/resolver.h>

namespace {
struct ContextOwner { ArResolverContext value; };
ContextOwner &context_owner(uint64_t h) {
    require(h != 0, "Resolver context is closed");
    return *reinterpret_cast<ContextOwner *>(h);
}
UsdStagePopulationMask population_mask(uint64_t strings) {
    UsdStagePopulationMask result;
    for (const auto &path : strings_owner(strings).values) result.Add(prim_path(path.c_str()));
    return result;
}
}
USDM_API uint64_t usdm_context_open(uint64_t paths, const char *configuration) noexcept {
    return protect_owned([&] {
        require(configuration != nullptr, "Null resolver configuration");
        auto result = std::make_unique<ContextOwner>();
        if (paths) result->value = ArResolverContext(ArDefaultResolverContext(strings_owner(paths).values));
        else result->value = ArGetResolver().CreateContextFromString(configuration);
        return result;
    });
}
USDM_API void usdm_context_close(uint64_t h) noexcept { delete reinterpret_cast<ContextOwner *>(h); }
USDM_API uint64_t usdm_stage_open_context(const char *filename, uint64_t context, uint64_t mask, int32_t load) noexcept {
    return protect_owned([&] {
        require(filename && *filename && (load == 0 || load == 1), "Invalid stage opening arguments");
        preflight_local_crate(filename);
        auto result = std::make_unique<StageOwner>();
        result->stage = UsdStage::OpenMasked(filename, context_owner(context).value, population_mask(mask),
            load ? UsdStage::LoadAll : UsdStage::LoadNone);
        require(bool(result->stage), "Cannot open USD stage in resolver context", ErrorKind::Io);
        result->watch();
        return result;
    });
}
USDM_API uint64_t usdm_stage_open_masked(const char *filename, uint64_t mask, uint64_t search, int32_t load) noexcept {
    return protect_owned([&] {
        require(filename && *filename && (load == 0 || load == 1), "Invalid stage opening arguments");
        preflight_local_crate(filename);
        auto paths = population_mask(mask);
        auto policy = load ? UsdStage::LoadAll : UsdStage::LoadNone;
        auto result = std::make_unique<StageOwner>();
        const auto &search_paths = strings_owner(search).values;
        if (search_paths.empty()) result->stage = UsdStage::OpenMasked(filename, paths, policy);
        else {
            ArResolverContext context{ArDefaultResolverContext(search_paths)};
            result->stage = UsdStage::OpenMasked(filename, context, paths, policy);
        }
        require(bool(result->stage), "Cannot open masked USD stage", ErrorKind::Io);
        result->watch();
        return result;
    });
}
USDM_API uint64_t usdm_stage_mask(uint64_t h) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<StringsOwner>();
        for (const auto &path : owner(h).stage->GetPopulationMask().GetPaths())
            result->values.push_back(path.GetString());
        return result;
    });
}
USDM_API int32_t usdm_stage_mask_set(uint64_t h, uint64_t paths, int32_t expand) noexcept {
    return protect([&] {
        require(expand == 0 || expand == 1, "Invalid population edit selector");
        if (expand) owner(h).stage->ExpandPopulationMask();
        else owner(h).stage->SetPopulationMask(population_mask(paths));
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_load_rules(uint64_t h) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<StringsOwner>();
        for (const auto &entry : owner(h).stage->GetLoadRules().GetRules()) {
            result->values.push_back(entry.first.GetString());
            result->values.push_back(entry.second == UsdStageLoadRules::AllRule ? "all" :
                entry.second == UsdStageLoadRules::OnlyRule ? "only" : "none");
        }
        return result;
    });
}
USDM_API int32_t usdm_set_load_rules(uint64_t h, uint64_t paths, uint64_t modes) noexcept {
    return protect([&] {
        const auto &p = strings_owner(paths).values;
        const auto &m = strings_owner(modes).values;
        require(p.size() == m.size(), "Load rule arrays differ in length");
        UsdStageLoadRules rules;
        std::set<SdfPath> unique;
        for (size_t i = 0; i < p.size(); ++i) {
            auto path = prim_path(p[i].c_str());
            require(unique.insert(path).second, "Duplicate load rule path");
            require(m[i] == "all" || m[i] == "only" || m[i] == "none", "Invalid load rule mode");
            rules.AddRule(path, m[i] == "all" ? UsdStageLoadRules::AllRule :
                m[i] == "only" ? UsdStageLoadRules::OnlyRule : UsdStageLoadRules::NoneRule);
        }
        rules.Minimize();
        owner(h).stage->SetLoadRules(rules);
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API int32_t usdm_mute_layer(uint64_t h, const char *identifier, int32_t muted) noexcept {
    return protect([&] {
        require(identifier && *identifier && (muted == 0 || muted == 1), "Invalid layer mute arguments");
        if (muted) owner(h).stage->MuteLayer(identifier);
        else owner(h).stage->UnmuteLayer(identifier);
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_muted_layers(uint64_t h) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<StringsOwner>();
        result->values = owner(h).stage->GetMutedLayers();
        return result;
    });
}
USDM_API uint64_t usdm_prim_arcs(uint64_t h, const char *path) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<StringsOwner>();
        for (const auto &node : prim(h, path).GetPrimIndex().GetNodeRange()) {
            for (const auto &layer : node.GetLayerStack()->GetLayers()) {
                result->values.push_back(TfEnum::GetName(node.GetArcType()));
                result->values.push_back(layer->GetIdentifier());
                result->values.push_back(node.GetPath().GetString());
            }
        }
        return result;
    });
}
USDM_API uint64_t usdm_register_plugins(const char *path) noexcept {
    return protect_owned([&] {
        require(path && *path, "Empty plugin search path");
        auto result = std::make_unique<StringsOwner>();
        for (const auto &plugin : PlugRegistry::GetInstance().RegisterPlugins(path))
            result->values.push_back(plugin->GetName());
        std::sort(result->values.begin(), result->values.end());
        return result;
    });
}
