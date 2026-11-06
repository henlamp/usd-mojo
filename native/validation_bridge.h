// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
#include <pxr/usdValidation/usdValidation/context.h>
#include <pxr/usdValidation/usdValidation/registry.h>
#include <pxr/usd/usdPhysics/massAPI.h>
#include <tuple>

namespace {
const std::string mesh_validator_name = "usd_mojo:MeshTopology";
const std::string mass_validator_name = "usd_mojo:MassValues";
struct ValidationSiteOwner {
    std::string layer, stage, path;
    bool valid;
    auto key() const { return std::tie(layer, stage, path, valid); }
};
struct ValidationIssueOwner {
    std::string identifier, severity, message;
    std::vector<ValidationSiteOwner> sites;
};
struct ValidationOwner {
    std::vector<std::string> validators, mask, unloaded, muted;
    std::vector<ValidationIssueOwner> issues;
    uint64_t total = 0, errors = 0, warnings = 0, infos = 0;
};
ValidationOwner &validation_owner(uint64_t h) {
    require(h != 0, "Validation report is closed");
    return *reinterpret_cast<ValidationOwner *>(h);
}
std::string validation_site_path(const UsdValidationErrorSite &site) {
    if (auto p = site.GetProperty()) return p.GetPath().GetString();
    if (auto p = site.GetPrim()) return p.GetPath().GetString();
    if (auto p = site.GetPropertySpec()) return p->GetPath().GetString();
    if (auto p = site.GetPrimSpec()) return p->GetPath().GetString();
    return {}; // This SDK does not expose the raw path of an invalid site.
}
void validate_meshes(ValidationOwner &report, const UsdStageRefPtr &stage, double time, int32_t mode) {
    std::set<SdfPath> visited;
    for (auto p : UsdPrimRange::Stage(stage, UsdTraverseInstanceProxies())) {
        if (p.IsInstanceProxy()) p = p.GetPrimInPrototype();
        if (!p.IsA<UsdGeomMesh>() || !visited.insert(p.GetPath()).second) continue;
        UsdGeomMesh mesh(p);
        std::vector<UsdTimeCode> times;
        if (mode != 0) times.push_back(mode == 1 ? UsdTimeCode::Default() : UsdTimeCode(time));
        else {
            std::set<double> samples;
            for (const auto &a : {mesh.GetPointsAttr(), mesh.GetFaceVertexCountsAttr(), mesh.GetFaceVertexIndicesAttr()}) {
                std::vector<double> values;
                a.GetTimeSamples(&values);
                samples.insert(values.begin(), values.end());
            }
            MeshOwner defaults;
            if ((mesh.GetPointsAttr().Get(&defaults.points) && mesh.GetFaceVertexCountsAttr().Get(&defaults.counts) &&
                mesh.GetFaceVertexIndicesAttr().Get(&defaults.indices)) || samples.empty())
                times.push_back(UsdTimeCode::Default());
            for (double sample : samples) times.emplace_back(sample);
        }
        for (auto tc : times) {
            MeshOwner value;
            try {
                require(mesh.GetPointsAttr().Get(&value.points, tc) && mesh.GetFaceVertexCountsAttr().Get(&value.counts, tc) &&
                    mesh.GetFaceVertexIndicesAttr().Get(&value.indices, tc), "Mesh topology arrays have no readable value", ErrorKind::InvalidData);
                validate_topology(value);
            } catch (const BridgeError &error) {
                if (error.kind != ErrorKind::InvalidData) throw;
                ValidationIssueOwner issue;
                issue.identifier = mesh_validator_name + ".InvalidMesh";
                issue.severity = "error";
                issue.message = (tc.IsDefault() ? "Default value: " : "Time " + std::to_string(tc.GetValue()) + ": ") + std::string(error.what());
                issue.sites.push_back({{}, stage->GetRootLayer()->GetIdentifier(), p.GetPath().GetString(), true});
                report.issues.push_back(std::move(issue));
            }
        }
    }
}
void validate_masses(ValidationOwner &report, const UsdStageRefPtr &stage, double time, int32_t mode) {
    std::set<SdfPath> visited;
    for (auto p : UsdPrimRange::Stage(stage, UsdTraverseInstanceProxies())) {
        if (p.IsInstanceProxy()) p = p.GetPrimInPrototype();
        if (!p.HasAPI<UsdPhysicsMassAPI>() || !visited.insert(p.GetPath()).second) continue;
        UsdPhysicsMassAPI mass(p);
        for (const auto &a : {mass.GetMassAttr(), mass.GetDensityAttr(), mass.GetDiagonalInertiaAttr(),
                             mass.GetCenterOfMassAttr(), mass.GetPrincipalAxesAttr()}) {
            std::vector<UsdTimeCode> times;
            if (mode != 0) times.push_back(mode == 1 ? UsdTimeCode::Default() : UsdTimeCode(time));
            else {
                VtValue default_value;
                std::vector<double> samples;
                a.GetTimeSamples(&samples);
                if (a.Get(&default_value) || samples.empty()) times.push_back(UsdTimeCode::Default());
                for (double sample : samples) times.emplace_back(sample);
            }
            for (auto tc : times) {
                VtValue value;
                bool valid = a.Get(&value, tc);
                const bool center = a == mass.GetCenterOfMassAttr();
                const bool scalar = a == mass.GetMassAttr() || a == mass.GetDensityAttr();
                const bool vector = center || a == mass.GetDiagonalInertiaAttr();
                if (valid && scalar && value.IsHolding<float>()) {
                    auto v = value.UncheckedGet<float>();
                    valid = std::isfinite(v) && v >= 0;
                } else if (valid && scalar && value.IsHolding<double>()) {
                    auto v = value.UncheckedGet<double>();
                    valid = std::isfinite(v) && v >= 0;
                } else if (valid && vector && (value.IsHolding<GfVec3f>() || value.IsHolding<GfVec3d>())) {
                    auto v = value.IsHolding<GfVec3f>() ? GfVec3d(value.UncheckedGet<GfVec3f>()) : value.UncheckedGet<GfVec3d>();
                    const bool derived_center = center && v[0] == -std::numeric_limits<double>::infinity() &&
                        v[1] == v[0] && v[2] == v[0];
                    valid = derived_center || (std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]) &&
                        (center || (v[0] >= 0 && v[1] >= 0 && v[2] >= 0)));
                } else if (valid && a == mass.GetPrincipalAxesAttr() && value.IsHolding<GfQuatf>()) {
                    auto v = value.UncheckedGet<GfQuatf>();
                    valid = std::isfinite(v.GetReal());
                    for (int i = 0; i < 3; ++i) valid = valid && std::isfinite(v.GetImaginary()[i]);
                } else valid = false;
                if (!valid) {
                    ValidationIssueOwner issue;
                    issue.identifier = mass_validator_name + ".InvalidValue";
                    issue.severity = "error";
                    issue.message = "Invalid mass data at " + a.GetPath().GetString() +
                        (tc.IsDefault() ? " (default)" : " (time " + std::to_string(tc.GetValue()) + ")");
                    issue.sites.push_back({{}, stage->GetRootLayer()->GetIdentifier(), a.GetPath().GetString(), true});
                    report.issues.push_back(std::move(issue));
                }
            }
        }
    }
}
}
USDM_API uint64_t usdm_validator_names() noexcept {
    return protect_owned([] {
        auto result = std::make_unique<StringsOwner>();
        for (const auto &m : UsdValidationRegistry::GetInstance().GetAllValidatorMetadata())
            if (!m.isSuite) result->values.push_back(m.name.GetString());
        result->values.push_back(mesh_validator_name);
        result->values.push_back(mass_validator_name);
        std::sort(result->values.begin(), result->values.end());
        return result;
    });
}
USDM_API uint64_t usdm_validate(uint64_t h, uint64_t names, int64_t limit, double time, int32_t mode) noexcept {
    return protect_owned([&] {
        require(limit >= 0 && limit <= 1000000 && mode >= 0 && mode <= 2 && (mode != 2 || std::isfinite(time)), "Invalid validation limits/time mode");
        auto result = std::make_unique<ValidationOwner>();
        auto stage = owner(h).stage;
        auto &registry = UsdValidationRegistry::GetInstance();
        auto requested = strings_owner(names).values;
        if (requested.empty()) {
            for (const auto &m : registry.GetAllValidatorMetadata()) if (!m.isSuite) requested.push_back(m.name.GetString());
            requested.push_back(mesh_validator_name);
            requested.push_back(mass_validator_name);
        }
        std::sort(requested.begin(), requested.end());
        require(std::adjacent_find(requested.begin(), requested.end()) == requested.end(), "Duplicate validator name");
        std::vector<const UsdValidationValidator *> selected;
        bool check_mesh = false;
        bool check_mass = false;
        for (const auto &name : requested) {
            if (name == mesh_validator_name) check_mesh = true;
            else if (name == mass_validator_name) check_mass = true;
            else {
                auto validator = registry.GetOrLoadValidatorByName(TfToken(name));
                require(validator != nullptr, "Validator is unavailable: " + name, ErrorKind::NotFound);
                selected.push_back(validator);
            }
            result->validators.push_back(name);
        }
        require(!result->validators.empty(), "No validators available", ErrorKind::Unsupported);
        UsdValidationContext context(selected);
        auto range = mode == 0 ? UsdValidationTimeRange() :
            UsdValidationTimeRange(mode == 1 ? UsdTimeCode::Default() : UsdTimeCode(time));
        auto errors = context.Validate(stage, UsdTraverseInstanceProxies(), range);
        for (const auto &error : errors) {
            if (error.GetType() == UsdValidationErrorType::None) continue;
            ValidationIssueOwner issue;
            issue.identifier = error.GetIdentifier().GetString();
            issue.severity = error.GetType() == UsdValidationErrorType::Error ? "error" :
                error.GetType() == UsdValidationErrorType::Warn ? "warning" : "info";
            issue.message = error.GetMessage();
            for (const auto &site : error.GetSites()) {
                issue.sites.push_back({site.GetLayer() ? site.GetLayer()->GetIdentifier() : "",
                    site.GetStage() ? site.GetStage()->GetRootLayer()->GetIdentifier() : "",
                    validation_site_path(site), site.IsValid()});
            }
            std::sort(issue.sites.begin(), issue.sites.end(), [](const auto &a, const auto &b) { return a.key() < b.key(); });
            result->issues.push_back(std::move(issue));
        }
        if (check_mesh) validate_meshes(*result, stage, time, mode);
        if (check_mass) validate_masses(*result, stage, time, mode);
        for (const auto &issue : result->issues) {
            if (issue.severity == "error") ++result->errors;
            else if (issue.severity == "warning") ++result->warnings;
            else ++result->infos;
        }
        std::sort(result->issues.begin(), result->issues.end(), [](const auto &a, const auto &b) {
            auto left = std::tie(a.identifier, a.severity, a.message);
            auto right = std::tie(b.identifier, b.severity, b.message);
            if (left != right) return left < right;
            return std::lexicographical_compare(a.sites.begin(), a.sites.end(), b.sites.begin(), b.sites.end(),
                [](const auto &x, const auto &y) { return x.key() < y.key(); });
        });
        result->total = result->issues.size();
        if (result->issues.size() > uint64_t(limit)) result->issues.resize(size_t(limit));
        for (const auto &path : stage->GetPopulationMask().GetPaths()) result->mask.push_back(path.GetString());
        auto loaded = stage->GetLoadSet();
        for (const auto &path : stage->FindLoadable()) if (!loaded.count(path)) result->unloaded.push_back(path.GetString());
        result->muted = stage->GetMutedLayers();
        return result;
    });
}
USDM_API void usdm_validation_close(uint64_t h) noexcept { delete reinterpret_cast<ValidationOwner *>(h); }
USDM_API int32_t usdm_validation_info(uint64_t h, uint64_t *info, int64_t count) noexcept {
    return protect([&] {
        require(info && count == 5, "Validation metadata extent mismatch");
        auto &o = validation_owner(h);
        info[0] = o.total; info[1] = o.errors; info[2] = o.warnings; info[3] = o.infos; info[4] = o.issues.size();
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_validation_strings(uint64_t h, int32_t kind) noexcept {
    return protect_owned([&] {
        require(kind >= 0 && kind <= 3, "Invalid validation string selector");
        auto &o = validation_owner(h);
        auto result = std::make_unique<StringsOwner>();
        result->values = kind == 0 ? o.validators : kind == 1 ? o.mask : kind == 2 ? o.unloaded : o.muted;
        return result;
    });
}
USDM_API uint64_t usdm_validation_issue(uint64_t h, int64_t index) noexcept {
    return protect_owned([&] {
        const auto &issues = validation_owner(h).issues;
        require(index >= 0 && uint64_t(index) < issues.size(), "Validation issue index out of range");
        const auto &issue = issues[size_t(index)];
        auto result = std::make_unique<StringsOwner>();
        result->values = {issue.identifier, issue.severity, issue.message};
        for (const auto &site : issue.sites)
            result->values.insert(result->values.end(), {site.layer, site.stage, site.path, site.valid ? "1" : "0"});
        return result;
    });
}
