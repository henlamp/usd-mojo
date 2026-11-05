// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
#include <pxr/usd/usd/schemaRegistry.h>
#include <pxr/usd/usd/primDefinition.h>
#include <pxr/usd/usdGeom/pointInstancer.h>
#include <pxr/usd/usdGeom/primvarsAPI.h>
#include <pxr/usd/usdGeom/imageable.h>
#include <pxr/usd/usdGeom/bboxCache.h>
#include <pxr/usd/usdSkel/cache.h>
#include <pxr/usd/usdSkel/root.h>
#include <pxr/usd/usdSkel/skeleton.h>
#include <pxr/usd/usdSkel/skeletonQuery.h>
#include <pxr/usd/usdSkel/skinningQuery.h>
#include <pxr/usd/usdSkel/bindingAPI.h>
#include <pxr/usd/usdSkel/blendShapeQuery.h>
#include <pxr/usd/usdSkel/animQuery.h>
#include <pxr/usd/usd/collectionAPI.h>
#include <pxr/usd/usdShade/material.h>
#include <pxr/usd/usdShade/shader.h>
#include <pxr/usd/usdUtils/dependencies.h>
#include <assetLocalizationPackage.h>
#include <pxr/usd/sdf/zipFile.h>
#include <map>
#include <filesystem>

namespace {
VtValue restore_asset_slots(const VtValue &original, const VtValue &localized) {
    if (original.IsHolding<VtArray<SdfAssetPath>>()) {
        const auto &before = original.UncheckedGet<VtArray<SdfAssetPath>>();
        if (std::none_of(before.begin(), before.end(), [](const auto &p) { return p.GetAssetPath().empty(); }))
            return localized;
        VtArray<SdfAssetPath> after;
        if (localized.IsHolding<VtArray<SdfAssetPath>>())
            after = localized.UncheckedGet<VtArray<SdfAssetPath>>();
        VtArray<SdfAssetPath> restored;
        restored.reserve(before.size());
        size_t cursor = 0;
        for (const auto &path : before) {
            if (path.GetAssetPath().empty()) restored.emplace_back();
            else {
                require(cursor < after.size(), "Package localization lost an asset", ErrorKind::InvalidData);
                restored.push_back(after[cursor++]);
            }
        }
        require(cursor == after.size(), "Unexpected localized asset extent", ErrorKind::InvalidData);
        return VtValue(restored);
    }
    if (original.IsHolding<VtDictionary>()) {
        auto result = localized.IsHolding<VtDictionary>() ? localized.UncheckedGet<VtDictionary>() : VtDictionary{};
        bool changed = false;
        for (const auto &item : original.UncheckedGet<VtDictionary>()) {
            const auto found = result.find(item.first);
            const auto value = found == result.end() ? VtValue{} : found->second;
            auto restored = restore_asset_slots(item.second, value);
            if (restored != value) {
                result[item.first] = std::move(restored);
                changed = true;
            }
        }
        return changed ? VtValue(result) : localized;
    }
    return localized;
}

// The pinned SDK's default package builder filters empty asset-array entries.
// Its localization client supports keeping those slots without editing sources.
static_assert(USDM_EXPECTED_SDK_VERSION == 2608, "Review the package-writer declarations for this SDK");
class PackageWriter final : public UsdUtils_AssetLocalizationPackage {
    SdfZipFileWriter writer;
    bool _WriteToPackage(const std::string &source, const std::string &target) override {
        const auto resolved = ArGetResolver().Resolve(source);
        return !resolved.IsEmpty() && !writer.AddFile(resolved.GetPathString(), target).empty();
    }
public:
    PackageWriter() { SetEditLayersInPlace(false); SetKeepEmptyPathsInArrays(true); }
    void EndProcessValue(const SdfLayerRefPtr &layer, const SdfPath &path,
                         const TfToken &key, const VtValue &value) override {
        UsdUtils_AssetLocalizationPackage::EndProcessValue(layer, path, key, value);
        auto target = SdfLayer::Find(GetLayerUsedForWriting(layer)->GetIdentifier());
        auto localized = target->GetField(path, key);
        auto restored = restore_asset_slots(value, localized);
        if (restored != localized) target->SetField(path, key, restored);
    }
    void EndProcessTimeSampleValue(const SdfLayerRefPtr &layer, const SdfPath &path,
                                   double time, const VtValue &value) override {
        UsdUtils_AssetLocalizationPackage::EndProcessTimeSampleValue(layer, path, time, value);
        auto target = SdfLayer::Find(GetLayerUsedForWriting(layer)->GetIdentifier());
        VtValue localized;
        target->QueryTimeSample(path, time, &localized);
        auto restored = restore_asset_slots(value, localized);
        if (restored != localized) target->SetTimeSample(path, time, restored);
    }
    bool Write(const std::string &path) override {
        writer = SdfZipFileWriter::CreateNew(path);
        return UsdUtils_AssetLocalizationPackage::Write(path) && writer.Save();
    }
};

struct SchemaOwner {
    std::map<std::string, VtValue> values;
    std::map<std::string, std::string> types;
    std::map<std::string, SdfPathVector> targets, connections;
    std::vector<std::string> names, missing;
};
SchemaOwner &schema_owner(uint64_t h) {
    require(h != 0, "Schema snapshot is closed");
    return *reinterpret_cast<SchemaOwner *>(h);
}
std::unique_ptr<ValueOwner> domain_value(const VtValue &value, const std::string &type = {}) {
    auto result = std::make_unique<ValueOwner>();
    result->type = type.empty() ? SdfGetValueTypeNameForValue(value).GetAsToken().GetString() : type;
    decode(*result, value);
    return result;
}
UsdSkelRoot skel_root(UsdPrim p) {
    while (p && !p.IsPseudoRoot()) {
        if (auto root = UsdSkelRoot(p)) return root;
        p = p.GetParent();
    }
    throw BridgeError(ErrorKind::InvalidData, "Skeleton requires an ancestor SkelRoot");
}
}
USDM_API uint64_t usdm_schema_snapshot(uint64_t h, const char *path, double t, int32_t d) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<SchemaOwner>();
        auto p = prim(h, path);
        auto tc = time_code(t, d);
        for (const auto &a : p.GetAttributes()) {
            auto name = a.GetName().GetString();
            result->names.push_back(name);
            result->types[name] = a.GetTypeName().GetAsToken().GetString();
            VtValue value;
            if (a.Get(&value, tc)) result->values.emplace(name, std::move(value));
            else result->missing.push_back(name);
            a.GetConnections(&result->connections[name]);
        }
        for (const auto &r : p.GetRelationships()) {
            auto name = r.GetName().GetString();
            r.GetForwardedTargets(&result->targets[name]);
        }
        return result;
    });
}
USDM_API void usdm_schema_close(uint64_t h) noexcept { delete reinterpret_cast<SchemaOwner *>(h); }
USDM_API uint64_t usdm_schema_names(uint64_t h, int32_t kind) noexcept {
    return protect_owned([&] {
        auto &s = schema_owner(h);
        auto result = std::make_unique<StringsOwner>();
        if (kind == 0) result->values = s.names;
        else if (kind == 1) result->values = s.missing;
        else {
            require(kind == 2, "Invalid schema name selector");
            for (const auto &item : s.targets) result->values.push_back(item.first);
        }
        return result;
    });
}
USDM_API uint64_t usdm_schema_value(uint64_t h, const char *name) noexcept {
    return protect_owned([&] {
        require(name && *name, "Empty attribute name");
        auto &values = schema_owner(h).values;
        auto it = values.find(name);
        require(it != values.end(), "Attribute has no resolved value", ErrorKind::NotFound);
        return domain_value(it->second, schema_owner(h).types.at(name));
    });
}
USDM_API uint64_t usdm_schema_paths(uint64_t h, const char *name, int32_t kind) noexcept {
    return protect_owned([&] {
        require(name && *name && (kind == 0 || kind == 1), "Invalid property query");
        auto &s = schema_owner(h);
        auto &paths = kind == 0 ? s.targets : s.connections;
        auto it = paths.find(name);
        require(it != paths.end(), "Property does not exist", ErrorKind::NotFound);
        auto result = std::make_unique<StringsOwner>();
        for (const auto &path : it->second) result->values.push_back(path.GetString());
        return result;
    });
}
USDM_API uint64_t usdm_schema_definition(const char *name, int32_t api) noexcept {
    return protect_owned([&] {
        require(name && *name && (api == 0 || api == 1), "Invalid schema definition query");
        const auto &registry = UsdSchemaRegistry::GetInstance();
        auto def = api ? registry.FindAppliedAPIPrimDefinition(TfToken(name))
                       : registry.FindConcretePrimDefinition(TfToken(name));
        require(def != nullptr, "Schema is not registered", ErrorKind::NotFound);
        auto result = std::make_unique<StringsOwner>();
        for (const auto &p : def->GetPropertyNames()) result->values.push_back(p.GetString());
        return result;
    });
}
USDM_API uint64_t usdm_geom_text(uint64_t h, const char *path, int32_t kind, double t, int32_t d) noexcept {
    return protect_owned([&] {
        auto p = prim(h, path);
        auto imageable = UsdGeomImageable(p);
        require(bool(imageable), "Expected an Imageable prim", ErrorKind::TypeMismatch);
        require(kind == 0 || kind == 1, "Invalid geometry query");
        return editor_text((kind == 0 ? imageable.ComputeVisibility(time_code(t, d)) :
            imageable.ComputePurpose()).GetString());
    });
}
USDM_API uint64_t usdm_world_bounds(uint64_t h, const char *path, uint64_t purposes, double t, int32_t d) noexcept {
    return protect_owned([&] {
        TfTokenVector tokens;
        for (const auto &name : strings_owner(purposes).values) tokens.emplace_back(name);
        require(!tokens.empty(), "Bounds require at least one purpose");
        UsdGeomBBoxCache cache(time_code(t, d), tokens, false, false);
        auto range = cache.ComputeWorldBound(prim(h, path)).ComputeAlignedRange();
        require(!range.IsEmpty(), "Prim has no bound for the selected purposes", ErrorKind::NotFound);
        VtVec3dArray bounds{range.GetMin(), range.GetMax()};
        return domain_value(VtValue(bounds));
    });
}
USDM_API uint64_t usdm_inherited_primvar(uint64_t h, const char *path, const char *name, double t, int32_t d) noexcept {
    return protect_owned([&] {
        require(name && *name, "Empty primvar name");
        auto pv = UsdGeomPrimvarsAPI(prim(h, path)).FindPrimvarWithInheritance(TfToken(name));
        require(bool(pv), "No inherited primvar", ErrorKind::NotFound);
        VtValue flattened;
        require(pv.ComputeFlattened(&flattened, time_code(t, d)), "Cannot flatten primvar", ErrorKind::InvalidData);
        return domain_value(flattened);
    });
}
USDM_API uint64_t usdm_instance_data(uint64_t h, const char *path, int32_t kind, double t, int32_t d, int32_t prototype) noexcept {
    return protect_owned([&] {
        auto instancer = UsdGeomPointInstancer(prim(h, path));
        require(bool(instancer), "Expected a PointInstancer", ErrorKind::TypeMismatch);
        auto tc = time_code(t, d);
        VtIntArray indices;
        require(instancer.GetProtoIndicesAttr().Get(&indices, tc), "PointInstancer has no prototype indices", ErrorKind::InvalidData);
        SdfPathVector prototypes;
        instancer.GetPrototypesRel().GetTargets(&prototypes);
        for (auto i : indices) require(i >= 0 && size_t(i) < prototypes.size(), "Prototype index out of range", ErrorKind::InvalidData);
        if (kind == 1) {
            auto mask = instancer.ComputeMaskAtTime(tc);
            require(mask.empty() || mask.size() == indices.size(), "Invalid instance mask", ErrorKind::InvalidData);
            VtIntArray included(indices.size(), 1);
            if (!mask.empty()) for (size_t i = 0; i < mask.size(); ++i) included[i] = mask[i];
            return domain_value(VtValue(included));
        }
        require(kind == 0 && (prototype == 0 || prototype == 1), "Invalid instancer query");
        VtMatrix4dArray transforms;
        require(instancer.ComputeInstanceTransformsAtTime(&transforms, tc, tc,
            prototype ? UsdGeomPointInstancer::IncludeProtoXform : UsdGeomPointInstancer::ExcludeProtoXform,
            UsdGeomPointInstancer::IgnoreMask), "Cannot compute instance transforms", ErrorKind::InvalidData);
        require(transforms.size() == indices.size(), "Instance transform count mismatch", ErrorKind::InvalidData);
        return domain_value(VtValue(transforms));
    });
}
USDM_API uint64_t usdm_bound_material(uint64_t h, const char *path, const char *purpose) noexcept {
    return protect_owned([&] {
        require(purpose != nullptr, "Null material purpose");
        auto material = UsdShadeMaterialBindingAPI(prim(h, path)).ComputeBoundMaterial(TfToken(purpose));
        return editor_text(material ? material.GetPath().GetString() : "");
    });
}
USDM_API uint64_t usdm_shader_graph(uint64_t h, const char *path, const char *context) noexcept {
    return protect_owned([&] {
        auto root = prim(h, path);
        require(bool(UsdShadeMaterial(root)), "Expected a Material", ErrorKind::TypeMismatch);
        require(context != nullptr, "Null render context");
        UsdShadeMaterial material(root);
        std::set<SdfPath> terminals;
        // Resolve through node graphs using the SDK. A disconnected/invalid
        // context terminal falls back independently for surface, volume and
        // displacement; retain its authored edges for diagnostics as well.
        for (const auto &entry : {
                std::make_pair(material.GetSurfaceOutput(TfToken(context)), material.GetSurfaceOutput()),
                std::make_pair(material.GetDisplacementOutput(TfToken(context)), material.GetDisplacementOutput()),
                std::make_pair(material.GetVolumeOutput(TfToken(context)), material.GetVolumeOutput())}) {
            const auto &output = entry.first;
            if (output) terminals.insert(output.GetAttr().GetPath());
            bool has_shader = false;
            if (output) for (const auto &source : output.GetValueProducingAttributes(true))
                has_shader = has_shader || source.GetPrim().IsA<UsdShadeShader>();
            if (!has_shader && *context) {
                if (entry.second) terminals.insert(entry.second.GetAttr().GetPath());
            }
        }
        auto result = std::make_unique<StringsOwner>();
        std::vector<UsdPrim> pending{root};
        std::set<SdfPath> visited;
        while (!pending.empty()) {
            auto p = pending.back(); pending.pop_back();
            if (!visited.insert(p.GetPath()).second) continue;
            result->values.insert(result->values.end(), {"node", p.GetPath().GetString(), p.GetTypeName().GetString()});
            for (const auto &a : p.GetAttributes()) {
                const auto name = a.GetName().GetString();
                if (p == root && name.rfind("outputs:", 0) == 0) {
                    if (!terminals.count(a.GetPath())) continue;
                }
                SdfPathVector sources;
                a.GetConnections(&sources);
                for (const auto &source : sources) {
                    auto target = owner(h).stage->GetAttributeAtPath(source);
                    result->values.insert(result->values.end(), {target ? "edge" : "unresolved", a.GetPath().GetString(), source.GetString()});
                    if (target) pending.push_back(target.GetPrim());
                }
            }
        }
        return result;
    });
}
USDM_API uint64_t usdm_skeleton_data(uint64_t h, const char *path, const char *mesh, int32_t kind, double t, int32_t d) noexcept {
    return protect_owned([&] {
        auto p = prim(h, path);
        auto skel = UsdSkelSkeleton(p);
        require(bool(skel), "Expected a Skeleton", ErrorKind::TypeMismatch);
        UsdSkelCache cache;
        require(cache.Populate(skel_root(p), UsdTraverseInstanceProxies()), "Cannot populate skeleton cache", ErrorKind::InvalidData);
        auto query = cache.GetSkelQuery(skel);
        require(bool(query), "Invalid skeleton topology or bind transforms", ErrorKind::InvalidData);
        if (kind == 0) return domain_value(VtValue(query.GetJointOrder()));
        VtMatrix4dArray transforms;
        auto tc = time_code(t, d);
        if (kind == 1) require(query.ComputeJointSkelTransforms(&transforms, tc), "Cannot compute joint transforms", ErrorKind::InvalidData);
        else if (kind == 2 || kind == 3) require(query.ComputeSkinningTransforms(&transforms, tc), "Cannot compute skinning transforms", ErrorKind::InvalidData);
        else throw BridgeError(ErrorKind::InvalidArgument, "Invalid skeleton query");
        if (kind != 3) return domain_value(VtValue(transforms));
        auto target = prim(h, mesh);
        auto binding = UsdSkelBindingAPI(target);
        auto inherited = binding.GetInheritedSkeleton();
        require(inherited && inherited.GetPrim() == p, "Mesh is bound to a different skeleton", ErrorKind::InvalidArgument);
        auto skin = cache.GetSkinningQuery(target);
        require(bool(skin), "Mesh has no skinning query", ErrorKind::InvalidData);
        VtVec3fArray points;
        require(target.GetAttribute(TfToken("points")).Get(&points, tc), "Mesh has no points", ErrorKind::InvalidData);
        auto animation = query.GetAnimQuery();
        std::vector<UsdAttribute> weight_attributes;
        const bool has_weights = skin.HasBlendShapes() && animation &&
            animation.GetBlendShapeWeightAttributes(&weight_attributes) &&
            std::any_of(weight_attributes.begin(), weight_attributes.end(), [&](const auto &a) {
                VtValue value;
                if (!a.Get(&value, tc)) return false;
                require(value.IsHolding<VtFloatArray>(), "Invalid blend-shape weight type", ErrorKind::InvalidData);
                return true;
            });
        if (has_weights) {
            VtFloatArray weights;
            require(animation.ComputeBlendShapeWeights(&weights, tc), "Cannot read blend-shape weights", ErrorKind::InvalidData);
            require(weights.size() == animation.GetBlendShapeOrder().size(),
                    "Blend-shape weight/order count mismatch", ErrorKind::InvalidData);
            for (float weight : weights)
                require(std::isfinite(weight), "Blend-shape weights must be finite", ErrorKind::InvalidData);
            if (auto mapper = skin.GetBlendShapeMapper()) {
                VtFloatArray remapped;
                require(mapper->Remap(weights, &remapped), "Cannot map blend-shape weights", ErrorKind::InvalidData);
                weights.swap(remapped);
            }
            UsdSkelBlendShapeQuery shapes(binding);
            require(bool(shapes), "Invalid blend-shape binding", ErrorKind::InvalidData);
            VtFloatArray subweights;
            VtUIntArray shape_indices, sub_indices;
            require(shapes.ComputeSubShapeWeights(weights, &subweights, &shape_indices, &sub_indices), "Invalid blend-shape weights", ErrorKind::InvalidData);
            require(shapes.ComputeDeformedPoints(subweights, shape_indices, sub_indices,
                shapes.ComputeBlendShapePointIndices(), shapes.ComputeSubShapePointOffsets(), points),
                "Cannot deform blend-shape points", ErrorKind::InvalidData);
        }
        if (auto mapper = skin.GetJointMapper()) {
            VtMatrix4dArray remapped;
            require(mapper->RemapTransforms(transforms, &remapped), "Cannot map skeleton joints", ErrorKind::InvalidData);
            transforms.swap(remapped);
        }
        require(skin.ComputeSkinnedPoints(transforms, &points, tc), "Cannot skin points", ErrorKind::InvalidData);
        return domain_value(VtValue(points));
    });
}
USDM_API uint64_t usdm_collection_members(uint64_t h, const char *path, const char *name) noexcept {
    return protect_owned([&] {
        require(name && *name, "Empty collection instance name");
        auto collection = UsdCollectionAPI(prim(h, path), TfToken(name));
        require(bool(collection), "Collection is not applied", ErrorKind::NotFound);
        auto result = std::make_unique<StringsOwner>();
        for (const auto &p : UsdCollectionAPI::ComputeIncludedPaths(collection.ComputeMembershipQuery(), owner(h).stage, UsdTraverseInstanceProxies()))
            result->values.push_back(p.GetString());
        return result;
    });
}
USDM_API uint64_t usdm_dependencies(uint64_t h) noexcept {
    return protect_owned([&] {
        auto stage = owner(h).stage;
        ArResolverContextBinder bind(stage->GetPathResolverContext());
        std::vector<SdfLayerRefPtr> layers;
        std::vector<std::string> assets, unresolved;
        require(UsdUtilsComputeAllDependencies(SdfAssetPath(stage->GetRootLayer()->GetIdentifier()),
            &layers, &assets, &unresolved), "Cannot discover asset dependencies", ErrorKind::Io);
        auto result = std::make_unique<StringsOwner>();
        for (const auto &layer : layers) {
            result->values.push_back("layer"); result->values.push_back(layer->GetIdentifier());
        }
        for (const auto &asset : assets) {
            result->values.push_back("asset"); result->values.push_back(asset);
        }
        for (const auto &asset : unresolved) {
            result->values.push_back("unresolved"); result->values.push_back(asset);
        }
        return result;
    });
}
USDM_API int32_t usdm_usdz(uint64_t h, const char *destination) noexcept {
    return protect([&] {
        require(destination && *destination, "Empty USDZ filename");
        namespace fs = std::filesystem;
        auto path = fs::absolute(destination);
        require(path.extension() == ".usdz", "Package filename must end in .usdz");
        require(!fs::exists(path), "Package destination already exists");
        auto stage = owner(h).stage;
        // Generated clip manifests are anonymous SDK caches, not authored edits.
        for (const auto &layer : stage->GetUsedLayers(false))
            if (!(layer == stage->GetSessionLayer() && layer->IsEmpty()))
                require(!layer->IsDirty() && !layer->IsAnonymous(), "Save non-anonymous layers before packaging");
        ArResolverContextBinder bind(stage->GetPathResolverContext());
        std::vector<SdfLayerRefPtr> layers;
        std::vector<std::string> assets, unresolved;
        require(UsdUtilsComputeAllDependencies(SdfAssetPath(stage->GetRootLayer()->GetIdentifier()),
            &layers, &assets, &unresolved), "Cannot discover package dependencies", ErrorKind::Io);
        require(unresolved.empty(), "Package has unresolved dependencies", ErrorKind::NotFound);
        for (const auto &layer : layers)
            require(!layer->IsDirty() && !layer->IsAnonymous(), "Package dependency has unsaved edits");
        // A private sibling directory prevents temporary-file collisions and partial output.
        auto temp = path;
        temp += ".usd-mojo-tmp";
        require(fs::create_directory(temp), "Package temporary directory already exists", ErrorKind::Io);
        struct Cleanup { fs::path p; ~Cleanup() { std::error_code error; fs::remove_all(p, error); } } cleanup{temp};
        auto output = temp / path.filename();
        PackageWriter writer;
        require(writer.Build(SdfAssetPath(stage->GetRootLayer()->GetIdentifier()), "") &&
                writer.Write(output.string()), "Cannot create USDZ package", ErrorKind::Io);
        // Hard-link publication is atomic and refuses to overwrite a concurrently created destination.
        fs::create_hard_link(output, path);
        return int32_t(0);
    }, int32_t(-1));
}
