// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
// Original bridge code. OpenUSD implementation remains an external dependency.
#if defined(__GNUC__) && !defined(__clang__)
// OpenUSD 26.08 uses GNU <ext/hash_set>, whose header emits #warning.
// Scope the suppression to external SDK includes; our code keeps -Werror.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wcpp"
#endif
#include <pxr/pxr.h>
#include <pxr/base/gf/matrix4d.h>
#include <pxr/base/gf/vec3f.h>
#include <pxr/base/gf/vec3d.h>
#include <pxr/base/gf/quatf.h>
#include <pxr/base/gf/quatd.h>
#include <pxr/base/gf/transform.h>
#include <pxr/base/tf/errorMark.h>
#include <pxr/base/vt/array.h>
#include <pxr/usd/sdf/path.h>
#include <pxr/usd/sdf/types.h>
#include <pxr/usd/usd/attribute.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/usdGeom/mesh.h>
#include <pxr/usd/usdGeom/primvar.h>
#include <pxr/usd/usd/payloads.h>
#include <pxr/usd/pcp/errors.h>
#include <pxr/base/vt/dictionary.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdGeom/xformCache.h>
#include <pxr/usd/usdPhysics/metrics.h>
#include <pxr/usd/usdPhysics/tokens.h>
#include <pxr/usd/usdShade/materialBindingAPI.h>
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic pop
#endif
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <utility>

#define USDM_API extern "C" __attribute__((visibility("default")))
PXR_NAMESPACE_USING_DIRECTIVE
static_assert(sizeof(int) == sizeof(int32_t), "32-bit SDK topology required");
static_assert(sizeof(uintptr_t) == sizeof(uint64_t), "64-bit targets required");
namespace {
enum class ErrorKind : int32_t {
    InvalidArgument = 1,
    NotFound = 2,
    TypeMismatch = 3,
    Unsupported = 4,
    InvalidData = 5,
    Io = 6,
    Sdk = 7,
    Incompatible = 8,
    Internal = 9,
    Resource = 10
};
struct BridgeError : std::runtime_error {
    ErrorKind kind;
    BridgeError(ErrorKind category, const std::string &message)
        : std::runtime_error(message), kind(category) {}
};
thread_local std::string last_error;
thread_local ErrorKind last_error_kind = ErrorKind::Internal;
struct StageOwner {
    UsdStageRefPtr stage;
};
struct MeshOwner {
    VtVec3fArray points;
    VtIntArray counts, indices;
};
struct ArrayOwner {
    std::vector<double> values;
};
template <class F, class T> T protect(F &&action, T failure) noexcept {
    try {
        last_error.clear();
        last_error_kind = ErrorKind::Internal;
        TfErrorMark errors;
        auto result = action();
        if (!errors.IsClean()) {
            std::string message;
            for (const auto &error : errors)
                message += error.GetCommentary() + "\n";
            errors.Clear();
            throw std::runtime_error(message);
        }
        return result;
    } catch (const BridgeError &error) {
        last_error_kind = error.kind;
        last_error = error.what();
    } catch (const std::bad_alloc &error) {
        last_error_kind = ErrorKind::Resource;
        last_error = error.what();
    } catch (const std::exception &error) {
        last_error_kind = ErrorKind::Sdk;
        last_error = error.what();
    } catch (...) {
        last_error = "Unknown exception in OpenUSD bridge";
    }
    return failure;
}
// Hold snapshots until SDK diagnostics have also passed the exception boundary.
template <class F> uint64_t protect_owned(F &&action) noexcept {
    using Owner = decltype(action());
    auto result = protect(std::forward<F>(action), Owner{});
    return reinterpret_cast<uint64_t>(result.release());
}
void require(bool condition, const std::string &message,
             ErrorKind kind = ErrorKind::InvalidArgument) {
    if (!condition)
        throw BridgeError(kind, message);
}
// Avoid allocating an error string on every successful numeric element check.
void require(bool condition, const char *message,
             ErrorKind kind = ErrorKind::InvalidArgument) {
    if (!condition)
        throw BridgeError(kind, message);
}
void check_diagnostics(TfErrorMark &errors) {
    if (errors.IsClean())
        return;
    std::string message;
    for (const auto &error : errors)
        message += error.GetCommentary() + "\n";
    errors.Clear();
    throw std::runtime_error(message);
}
StageOwner &owner(uint64_t handle) {
    require(handle != 0, "Stage is closed");
    return *reinterpret_cast<StageOwner *>(handle);
}
MeshOwner &mesh_owner(uint64_t handle) {
    require(handle != 0, "Mesh snapshot is closed");
    return *reinterpret_cast<MeshOwner *>(handle);
}
SdfPath prim_path(const char *value) {
    require(value != nullptr, "Null prim path");
    std::string reason;
    const bool valid = SdfPath::IsValidPathString(value, &reason);
    require(valid, "Invalid prim path: " + reason);
    SdfPath path(value);
    require(path.IsAbsolutePath() && path.IsAbsoluteRootOrPrimPath(),
            "Expected an absolute prim path");
    return path;
}
UsdPrim prim(uint64_t handle, const char *path) {
    auto result = owner(handle).stage->GetPrimAtPath(prim_path(path));
    require(bool(result), std::string("Prim does not exist: ") + path,
            ErrorKind::NotFound);
    return result;
}
TfToken attr_name(const char *name) {
    require(name && SdfPath::IsValidNamespacedIdentifier(name),
            "Invalid attribute name");
    return TfToken(name);
}
UsdAttribute attribute(uint64_t handle, const char *path, const char *name) {
    auto result = prim(handle, path).GetAttribute(attr_name(name));
    require(bool(result), std::string("Attribute does not exist: ") + name,
            ErrorKind::NotFound);
    return result;
}
UsdTimeCode time_code(double time, int32_t is_default) {
    if (is_default)
        return UsdTimeCode::Default();
    require(std::isfinite(time), "Time code must be finite");
    return UsdTimeCode(time);
}
template <class T> T read(const UsdAttribute &attr, const UsdTimeCode &time) {
    T value{};
    require(attr.Get(&value, time),
            "Attribute has no readable value of the requested type",
            ErrorKind::TypeMismatch);
    return value;
}
int64_t copy_text(const std::string &text, char *destination, int64_t capacity) {
    require(text.find('\0') == std::string::npos,
            "USD text contains an embedded NUL; cannot represent it as UTF8 text");
    auto needed = static_cast<int64_t>(text.size() + 1);
    require(capacity >= 0, "Negative text buffer capacity");
    if (!destination && capacity == 0)
        return needed;
    require(destination && capacity >= needed, "Text buffer is too small");
    std::memcpy(destination, text.c_str(), static_cast<size_t>(needed));
    return needed;
}
void validate_topology(const MeshOwner &mesh) {
    std::string reason;
    const bool valid = UsdGeomMesh::ValidateTopology(mesh.indices, mesh.counts,
                                                     mesh.points.size(), &reason);
    require(valid, "Invalid mesh topology: " + reason, ErrorKind::InvalidData);
    for (const auto &point : mesh.points)
        for (int axis = 0; axis < 3; ++axis)
            require(std::isfinite(point[axis]), "Mesh contains non-finite points",
                    ErrorKind::InvalidData);
}
} // namespace

#include "preflight.h"

USDM_API int64_t usdm_error_text(char *destination, int64_t capacity) noexcept {
    // Preserve the last failing call's error while the client copies it.
    try {
        return copy_text(last_error, destination, capacity);
    } catch (...) {
        return -1;
    }
}
USDM_API int64_t usdm_error_size() noexcept {
    return static_cast<int64_t>(last_error.size() + 1);
}
USDM_API int32_t usdm_error_kind() noexcept {
    return static_cast<int32_t>(last_error_kind);
}
USDM_API int32_t usdm_abi_version() noexcept {
    return 2;
}
USDM_API int32_t usdm_sdk_version() noexcept {
    return PXR_VERSION;
}
USDM_API uint64_t usdm_stage_open(const char *path, int32_t create) noexcept {
    return protect_owned([&]() {
        TfErrorMark diagnostics;
        require(path && *path, "Empty stage filename");
        if (!create)
            preflight_local_crate(path);
        auto stage = create ? UsdStage::CreateNew(path) : UsdStage::Open(path);
        require(bool(stage), std::string("Cannot open/create USD stage: ") + path,
                ErrorKind::Io);
        check_diagnostics(diagnostics);
        auto result = std::make_unique<StageOwner>();
        result->stage = stage;
        return result;
    });
}
USDM_API void usdm_stage_close(uint64_t handle) noexcept {
    delete reinterpret_cast<StageOwner *>(handle);
}
USDM_API int32_t usdm_stage_save(uint64_t handle) noexcept {
    return protect(
        [&]() {
            require(owner(handle).stage->GetRootLayer()->Save(),
                    "Cannot save root layer", ErrorKind::Io);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_stage_export(uint64_t handle, const char *path) noexcept {
    return protect(
        [&]() {
            require(path && *path, "Empty export filename");
            require(owner(handle).stage->Export(path),
                    "Cannot export composed USD stage", ErrorKind::Io);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_define_prim(uint64_t handle, const char *path,
                                  const char *type) noexcept {
    return protect(
        [&]() {
            require(!type || !*type || SdfPath::IsValidIdentifier(type),
                    "Invalid prim type name");
            require(bool(owner(handle).stage->DefinePrim(prim_path(path),
                                                         TfToken(type ? type : ""))),
                    "Cannot define prim");
            return int32_t(0);
        },
        int32_t(-1));
}
// Text query: 0=default traversal paths, 1=prim type, 2=attribute names,
// 3=string/token value, 4=up axis. Counts include the trailing NUL byte.
namespace {
std::string text_query(uint64_t handle, const char *path, int32_t kind,
                       const char *name, double time, int32_t is_default) {
    std::string result;
    if (kind == 0) {
        for (const auto &item : owner(handle).stage->Traverse())
            result += item.GetPath().GetString() + "\n";
    } else if (kind == 1) {
        result = prim(handle, path).GetTypeName().GetString();
    } else if (kind == 2) {
        for (const auto &attr : prim(handle, path).GetAttributes())
            result += attr.GetName().GetString() + "\n";
    } else if (kind == 3) {
        auto attr = attribute(handle, path, name);
        auto tc = time_code(time, is_default);
        if (attr.GetTypeName() == SdfValueTypeNames->String)
            result = read<std::string>(attr, tc);
        else if (attr.GetTypeName() == SdfValueTypeNames->Token)
            result = read<TfToken>(attr, tc).GetString();
        else
            throw BridgeError(ErrorKind::TypeMismatch,
                              "Expected a string or token attribute");
    } else if (kind == 4) {
        result = UsdGeomGetStageUpAxis(owner(handle).stage).GetString();
    } else if (kind == 5) {
        auto item = prim(handle, path);
        auto schemas = item.GetAppliedSchemas();
        for (const auto &schema : schemas)
            result += schema.GetString() + "\n";
    } else if (kind == 6) {
        auto item = prim(handle, path);
        auto relationships = item.GetRelationships();
        for (const auto &relationship : relationships)
            result += relationship.GetName().GetString() + "\n";
    } else if (kind == 7) {
        auto rel = prim(handle, path).GetRelationship(attr_name(name));
        require(bool(rel), "Relationship does not exist", ErrorKind::NotFound);
        SdfPathVector targets;
        const bool resolved = rel.GetForwardedTargets(&targets);
        require(resolved || !rel.HasAuthoredTargets(),
                "Cannot resolve relationship targets");
        for (const auto &target : targets)
            result += target.GetString() + "\n";
    } else if (kind == 8) {
        auto material = UsdShadeMaterialBindingAPI(prim(handle, path))
                            .ComputeBoundMaterial(TfToken("physics"));
        if (material)
            result = material.GetPath().GetString();
    } else if (kind == 9) {
        auto item = prim(handle, path);
        auto requested = attr_name(name);
        while (item && !item.IsPseudoRoot()) {
            bool found = false;
            for (const auto &schema : item.GetAppliedSchemas())
                if (schema == requested)
                    found = true;
            if (found) {
                result = item.GetPath().GetString();
                break;
            }
            item = item.GetParent();
        }
    } else if (kind == 10) {
        auto material = UsdShadeMaterialBindingAPI(prim(handle, path))
                            .ComputeBoundMaterial(TfToken(name ? name : ""));
        if (material)
            result = material.GetPath().GetString();
    } else if (kind == 11) {
        auto a = attribute(handle, path, name);
        TfToken value;
        if (a.GetMetadata(TfToken("interpolation"), &value))
            result = value.GetString();
    } else if (kind == 12) {
        auto p = owner(handle).stage->GetDefaultPrim();
        if (p)
            result = p.GetPath().GetString();
    } else
        throw BridgeError(ErrorKind::Internal, "Unknown text query");
    return result;
}
struct TextOwner {
    std::string text;
};
} // namespace
// ABI 1 compatibility for previously compiled source consumers.
USDM_API int64_t usdm_text(uint64_t handle, const char *path, int32_t kind,
                           const char *name, double time, int32_t is_default,
                           char *destination, int64_t capacity) noexcept {
    return protect(
        [&]() {
            return copy_text(text_query(handle, path, kind, name, time, is_default),
                             destination, capacity);
        },
        int64_t(-1));
}
USDM_API uint64_t usdm_text_snapshot(uint64_t h, const char *path, int32_t kind,
                                     const char *name, double time,
                                     int32_t is_default) noexcept {
    return protect_owned([&]() {
        auto o = std::make_unique<TextOwner>();
        o->text = text_query(h, path, kind, name, time, is_default);
        return o;
    });
}
USDM_API int64_t usdm_snapshot_text(uint64_t h, char *data, int64_t capacity) noexcept {
    return protect(
        [&]() {
            require(h != 0, "Text snapshot is closed");
            return copy_text(reinterpret_cast<TextOwner *>(h)->text, data, capacity);
        },
        int64_t(-1));
}
USDM_API int64_t usdm_snapshot_text_size(uint64_t h) noexcept {
    return usdm_snapshot_text(h, nullptr, 0);
}
USDM_API void usdm_text_close(uint64_t h) noexcept {
    delete reinterpret_cast<TextOwner *>(h);
}
USDM_API int64_t usdm_text_size(uint64_t handle, const char *path, int32_t kind,
                                const char *name, double time,
                                int32_t is_default) noexcept {
    return usdm_text(handle, path, kind, name, time, is_default, nullptr, 0);
}
USDM_API int32_t usdm_read_float(uint64_t handle, const char *path, const char *name,
                                 double time, int32_t is_default,
                                 double *result) noexcept {
    return protect(
        [&]() {
            require(result != nullptr, "Null float destination");
            auto attr = attribute(handle, path, name);
            auto tc = time_code(time, is_default);
            if (attr.GetTypeName() == SdfValueTypeNames->Double)
                *result = read<double>(attr, tc);
            else if (attr.GetTypeName() == SdfValueTypeNames->Float)
                *result = read<float>(attr, tc);
            else
                throw BridgeError(ErrorKind::TypeMismatch,
                                  "Expected a float or double attribute");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_read_bool(uint64_t handle, const char *path, const char *name,
                                double time, int32_t is_default,
                                int32_t *result) noexcept {
    return protect(
        [&]() {
            require(result != nullptr, "Null bool destination");
            auto attr = attribute(handle, path, name);
            require(attr.GetTypeName() == SdfValueTypeNames->Bool,
                    "Expected a bool attribute", ErrorKind::TypeMismatch);
            *result = read<bool>(attr, time_code(time, is_default)) ? 1 : 0;
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_set_float(uint64_t handle, const char *path, const char *name,
                                double time, int32_t is_default,
                                double value) noexcept {
    return protect(
        [&]() {
            require(std::isfinite(value), "Float value must be finite");
            auto item = prim(handle, path);
            auto token = attr_name(name);
            auto attr = item.GetAttribute(token);
            if (!attr)
                attr = item.CreateAttribute(token, SdfValueTypeNames->Double, true);
            auto tc = time_code(time, is_default);
            if (attr.GetTypeName() == SdfValueTypeNames->Double)
                require(attr.Set(value, tc), "Cannot set double attribute");
            else if (attr.GetTypeName() == SdfValueTypeNames->Float) {
                require(std::abs(value) <= std::numeric_limits<float>::max(),
                        "Value overflows Float32");
                require(attr.Set(static_cast<float>(value), tc),
                        "Cannot set float attribute");
            } else
                throw BridgeError(ErrorKind::TypeMismatch,
                                  "Expected a float or double attribute");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_set_bool(uint64_t handle, const char *path, const char *name,
                               double time, int32_t is_default,
                               int32_t value) noexcept {
    return protect(
        [&]() {
            auto item = prim(handle, path);
            auto token = attr_name(name);
            auto attr = item.GetAttribute(token);
            if (!attr)
                attr = item.CreateAttribute(token, SdfValueTypeNames->Bool, true);
            require(attr.GetTypeName() == SdfValueTypeNames->Bool,
                    "Expected a bool attribute", ErrorKind::TypeMismatch);
            require(attr.Set(bool(value), time_code(time, is_default)),
                    "Cannot set bool attribute");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_set_text(uint64_t handle, const char *path, const char *name,
                               double time, int32_t is_default,
                               const char *value) noexcept {
    return protect(
        [&]() {
            value = value ? value : "";
            auto item = prim(handle, path);
            auto token = attr_name(name);
            auto attr = item.GetAttribute(token);
            if (!attr)
                attr = item.CreateAttribute(token, SdfValueTypeNames->String, true);
            auto tc = time_code(time, is_default);
            if (attr.GetTypeName() == SdfValueTypeNames->String)
                require(attr.Set(std::string(value), tc),
                        "Cannot set string attribute");
            else if (attr.GetTypeName() == SdfValueTypeNames->Token)
                require(attr.Set(TfToken(value), tc), "Cannot set token attribute");
            else
                throw BridgeError(ErrorKind::TypeMismatch,
                                  "Expected a string or token attribute");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_world_transform(uint64_t handle, const char *path, double time,
                                      int32_t is_default, double *result,
                                      int64_t capacity) noexcept {
    return protect(
        [&]() {
            require(result && capacity >= 16, "Transform buffer needs 16 doubles");
            UsdGeomXformCache cache(time_code(time, is_default));
            auto matrix = cache.GetLocalToWorldTransform(prim(handle, path));
            for (int row = 0; row < 4; ++row)
                for (int column = 0; column < 4; ++column)
                    result[row * 4 + column] = matrix[row][column];
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_meters_per_unit(uint64_t handle, double *result) noexcept {
    return protect(
        [&]() {
            require(result != nullptr, "Null units destination");
            *result = UsdGeomGetStageMetersPerUnit(owner(handle).stage);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API uint64_t usdm_mesh_snapshot(uint64_t handle, const char *path, double time,
                                     int32_t is_default) noexcept {
    return protect_owned([&]() {
        TfErrorMark diagnostics;
        UsdGeomMesh source(prim(handle, path));
        require(bool(source), "Prim is not a Mesh", ErrorKind::TypeMismatch);
        auto tc = time_code(time, is_default);
        auto result = std::make_unique<MeshOwner>();
        result->points = read<VtVec3fArray>(source.GetPointsAttr(), tc);
        result->counts = read<VtIntArray>(source.GetFaceVertexCountsAttr(), tc);
        result->indices = read<VtIntArray>(source.GetFaceVertexIndicesAttr(), tc);
        validate_topology(*result);
        check_diagnostics(diagnostics);
        return result;
    });
}
USDM_API int32_t usdm_time_codes_per_second(uint64_t handle, double *result) noexcept {
    return protect(
        [&]() {
            require(result != nullptr, "Null time-rate destination");
            *result = owner(handle).stage->GetTimeCodesPerSecond();
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_kilograms_per_unit(uint64_t handle, double *result) noexcept {
    return protect(
        [&]() {
            require(result != nullptr, "Null mass-unit destination");
            *result = UsdPhysicsGetStageKilogramsPerUnit(owner(handle).stage);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_attr_state(uint64_t handle, const char *path, const char *name,
                                 int32_t authored) noexcept {
    return protect(
        [&]() {
            auto attr = prim(handle, path).GetAttribute(attr_name(name));
            return int32_t(attr && (!authored || attr.HasAuthoredValueOpinion()));
        },
        int32_t(-1));
}
USDM_API int32_t usdm_prim_instance(uint64_t handle, const char *path) noexcept {
    return protect([&]() { return int32_t(prim(handle, path).IsInstance()); },
                   int32_t(-1));
}
USDM_API int32_t usdm_components(uint64_t handle, const char *path, const char *name,
                                 double time, int32_t is_default, int32_t kind,
                                 double *result, int64_t capacity) noexcept {
    return protect(
        [&]() {
            require(result && capacity >= (kind == 0   ? 3
                                           : kind == 1 ? 4
                                                       : 16),
                    "Component buffer is too small");
            auto attr = attribute(handle, path, name);
            auto value = read<VtValue>(attr, time_code(time, is_default));
            if (kind == 0) {
                if (value.IsHolding<GfVec3f>()) {
                    auto v = value.UncheckedGet<GfVec3f>();
                    for (int i = 0; i < 3; ++i)
                        result[i] = v[i];
                } else if (value.IsHolding<GfVec3d>()) {
                    auto v = value.UncheckedGet<GfVec3d>();
                    for (int i = 0; i < 3; ++i)
                        result[i] = v[i];
                } else
                    throw BridgeError(ErrorKind::TypeMismatch,
                                      "Expected a float3 or double3 vector");
            } else if (kind == 1) {
                if (value.IsHolding<GfQuatf>()) {
                    auto q = value.UncheckedGet<GfQuatf>();
                    result[0] = q.GetReal();
                    for (int i = 0; i < 3; ++i)
                        result[i + 1] = q.GetImaginary()[i];
                } else if (value.IsHolding<GfQuatd>()) {
                    auto q = value.UncheckedGet<GfQuatd>();
                    result[0] = q.GetReal();
                    for (int i = 0; i < 3; ++i)
                        result[i + 1] = q.GetImaginary()[i];
                } else
                    throw BridgeError(ErrorKind::TypeMismatch,
                                      "Expected a quatf or quatd attribute");
            } else if (kind == 2 && value.IsHolding<GfMatrix4d>()) {
                auto m = value.UncheckedGet<GfMatrix4d>();
                for (int r = 0; r < 4; ++r)
                    for (int c = 0; c < 4; ++c)
                        result[r * 4 + c] = m[r][c];
            } else
                throw BridgeError(ErrorKind::TypeMismatch,
                                  "Expected a matrix4d attribute");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_transform(uint64_t handle, const char *path, double time,
                                int32_t is_default, double *result,
                                int64_t capacity) noexcept {
    return protect(
        [&]() {
            require(result && capacity >= 10, "Transform buffer needs ten doubles");
            UsdGeomXformCache cache(time_code(time, is_default));
            auto m = cache.GetLocalToWorldTransform(prim(handle, path));
            require(std::abs(m[3][3] - 1) < 1e-10 &&
                        std::abs(m[0][3]) + std::abs(m[1][3]) + std::abs(m[2][3]) <
                            1e-10,
                    "TRS accessor requires an affine matrix");
            GfVec3d rows[3] = {{m[0][0], m[0][1], m[0][2]},
                               {m[1][0], m[1][1], m[1][2]},
                               {m[2][0], m[2][1], m[2][2]}};
            for (int i = 0; i < 3; ++i) {
                require(rows[i].GetLength() > 1e-12,
                        "TRS accessor rejects singular scale");
                for (int j = i + 1; j < 3; ++j)
                    require(std::abs(GfDot(rows[i], rows[j])) <=
                                1e-9 * rows[i].GetLength() * rows[j].GetLength(),
                            "TRS accessor rejects shear; use world_transform for a "
                            "full matrix");
            }
            require(m.GetDeterminant() > 0,
                    "TRS accessor rejects reflected transforms");
            GfTransform transform(m);
            auto p = transform.GetTranslation();
            auto q = transform.GetRotation().GetQuat();
            auto s = transform.GetScale();
            for (int i = 0; i < 3; ++i) {
                result[i] = p[i];
                result[7 + i] = s[i];
            }
            result[3] = q.GetReal();
            for (int i = 0; i < 3; ++i)
                result[4 + i] = q.GetImaginary()[i];
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API uint64_t usdm_array_snapshot(uint64_t handle, const char *path,
                                      const char *name, double time, int32_t is_default,
                                      int32_t kind) noexcept {
    return protect_owned([&]() {
        TfErrorMark diagnostics;
        auto value =
            read<VtValue>(attribute(handle, path, name), time_code(time, is_default));
        auto result = std::make_unique<ArrayOwner>();
        if (kind == 0 && value.IsHolding<VtFloatArray>()) {
            for (auto v : value.UncheckedGet<VtFloatArray>())
                result->values.push_back(v);
        } else if (kind == 0 && value.IsHolding<VtDoubleArray>()) {
            for (auto v : value.UncheckedGet<VtDoubleArray>())
                result->values.push_back(v);
        } else if (kind == 1 && value.IsHolding<VtIntArray>()) {
            for (auto v : value.UncheckedGet<VtIntArray>())
                result->values.push_back(v);
        } else if (kind == 2 && value.IsHolding<VtVec3fArray>()) {
            for (auto v : value.UncheckedGet<VtVec3fArray>())
                for (int i = 0; i < 3; ++i)
                    result->values.push_back(v[i]);
        } else if (kind == 2 && value.IsHolding<VtVec3dArray>()) {
            for (auto v : value.UncheckedGet<VtVec3dArray>())
                for (int i = 0; i < 3; ++i)
                    result->values.push_back(v[i]);
        } else
            throw BridgeError(ErrorKind::Unsupported, "Unsupported numeric array type");
        check_diagnostics(diagnostics);
        return result;
    });
}
USDM_API void usdm_array_close(uint64_t handle) noexcept {
    delete reinterpret_cast<ArrayOwner *>(handle);
}
USDM_API int64_t usdm_array_size(uint64_t handle) noexcept {
    return protect(
        [&]() -> int64_t {
            require(handle != 0, "Array snapshot is closed");
            return static_cast<int64_t>(
                reinterpret_cast<ArrayOwner *>(handle)->values.size());
        },
        int64_t(-1));
}
USDM_API int32_t usdm_array_copy(uint64_t handle, double *result,
                                 int64_t capacity) noexcept {
    return protect(
        [&]() {
            require(handle != 0, "Array snapshot is closed");
            auto &values = reinterpret_cast<ArrayOwner *>(handle)->values;
            require(capacity == static_cast<int64_t>(values.size()) &&
                        (capacity == 0 || result),
                    "Array extent mismatch");
            for (int64_t i = 0; i < capacity; ++i)
                result[i] = values[i];
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API void usdm_mesh_close(uint64_t handle) noexcept {
    delete reinterpret_cast<MeshOwner *>(handle);
}
USDM_API int64_t usdm_mesh_size(uint64_t handle, int32_t field) noexcept {
    return protect(
        [&]() -> int64_t {
            const auto &mesh = mesh_owner(handle);
            if (field == 0)
                return static_cast<int64_t>(mesh.points.size()) * 3;
            if (field == 1)
                return static_cast<int64_t>(mesh.counts.size());
            if (field == 2)
                return static_cast<int64_t>(mesh.indices.size());
            throw std::runtime_error("Unknown mesh field");
        },
        int64_t(-1));
}
USDM_API int32_t usdm_mesh_metadata(uint64_t handle, uint64_t *fields,
                                    int64_t size) noexcept {
    return protect(
        [&]() {
            require(fields && size == 6, "Mesh metadata extent mismatch");
            const auto &mesh = mesh_owner(handle);
            require(mesh.points.size() <=
                            uint64_t(std::numeric_limits<int64_t>::max()) / 3 &&
                        mesh.counts.size() <=
                            uint64_t(std::numeric_limits<int64_t>::max()) &&
                        mesh.indices.size() <=
                            uint64_t(std::numeric_limits<int64_t>::max()),
                    "Mesh extent exceeds native index range", ErrorKind::InvalidData);
            static_assert(sizeof(GfVec3f) == 3 * sizeof(float),
                          "Packed xyz layout required");
            fields[0] = uint64_t(mesh.points.size()) * 3;
            fields[1] = uint64_t(mesh.counts.size());
            fields[2] = uint64_t(mesh.indices.size());
            fields[3] = reinterpret_cast<uintptr_t>(mesh.points.cdata());
            fields[4] = reinterpret_cast<uintptr_t>(mesh.counts.cdata());
            fields[5] = reinterpret_cast<uintptr_t>(mesh.indices.cdata());
            return int32_t(0);
        },
        int32_t(-1));
}

// Borrowed addresses are valid only while their owning snapshot remains alive.
USDM_API uint64_t usdm_mesh_data(uint64_t handle, int32_t kind) noexcept {
    return protect(
        [&]() {
            const auto &mesh = mesh_owner(handle);
            static_assert(sizeof(GfVec3f) == 3 * sizeof(float),
                          "Packed xyz layout required");
            const void *data = nullptr;
            if (kind == 0)
                data = mesh.points.cdata();
            else if (kind == 1)
                data = mesh.counts.cdata();
            else if (kind == 2)
                data = mesh.indices.cdata();
            else
                throw BridgeError(ErrorKind::Internal, "Unknown mesh field");
            return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(data));
        },
        uint64_t(0));
}

namespace {
struct BufferRegion {
    uintptr_t begin, end;
};
BufferRegion buffer_region(const void *pointer, int64_t count, size_t width) {
    require(count >= 0 &&
                uint64_t(count) <= std::numeric_limits<uintptr_t>::max() / width,
            "Buffer byte extent overflow");
    const uintptr_t begin = reinterpret_cast<uintptr_t>(pointer);
    const uintptr_t bytes = uintptr_t(count) * width;
    require(begin <= std::numeric_limits<uintptr_t>::max() - bytes,
            "Buffer address extent overflow");
    return {begin, begin + bytes};
}
bool overlap(BufferRegion a, BufferRegion b) {
    return a.begin != a.end && b.begin != b.end && a.begin < b.end && b.begin < a.end;
}
} // namespace

USDM_API int32_t usdm_mesh_copy(uint64_t handle, float *points, int64_t np,
                                int32_t *counts, int64_t nc, int32_t *indices,
                                int64_t ni) noexcept {
    return protect(
        [&]() {
            const auto &mesh = mesh_owner(handle);
            require(np == static_cast<int64_t>(mesh.points.size()) * 3 &&
                        nc == static_cast<int64_t>(mesh.counts.size()) &&
                        ni == static_cast<int64_t>(mesh.indices.size()),
                    "Mesh buffer sizes do not match");
            require((np == 0 || points) && (nc == 0 || counts) && (ni == 0 || indices),
                    "Null mesh buffer");
            const auto p = buffer_region(points, np, sizeof(float));
            const auto c = buffer_region(counts, nc, sizeof(int32_t));
            const auto i = buffer_region(indices, ni, sizeof(int32_t));
            require(!overlap(p, c) && !overlap(p, i) && !overlap(c, i),
                    "Mesh output buffers overlap");
            const BufferRegion inputs[] = {
                buffer_region(mesh.points.cdata(), np, sizeof(float)),
                buffer_region(mesh.counts.cdata(), nc, sizeof(int32_t)),
                buffer_region(mesh.indices.cdata(), ni, sizeof(int32_t))};
            for (const auto input : inputs)
                require(!overlap(p, input) && !overlap(c, input) && !overlap(i, input),
                        "Mesh output aliases snapshot storage");
            for (int64_t p = 0; p < np / 3; ++p)
                for (int axis = 0; axis < 3; ++axis)
                    points[p * 3 + axis] = mesh.points[p][axis];
            for (int64_t i = 0; i < nc; ++i)
                counts[i] = mesh.counts[i];
            for (int64_t i = 0; i < ni; ++i)
                indices[i] = mesh.indices[i];
            return int32_t(0);
        },
        int32_t(-1));
}

#include "value_bridge.h"

#include "scene_bridge.h"
