// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
// All storage crossing the ABI is owned; no SDK objects escape.
#include <pxr/base/gf/half.h>
#include <pxr/base/gf/traits.h>
#include <pxr/usd/sdf/assetPath.h>
#include <pxr/usd/sdf/timeCode.h>
#include <pxr/usd/sdf/pathExpression.h>
#include <pxr/usd/usd/references.h>
#include <pxr/usd/usd/variantSets.h>
#include <pxr/usd/usd/editTarget.h>
#include <pxr/usd/usd/relationship.h>
#include <pxr/base/gf/matrix2d.h>
#include <pxr/base/gf/matrix3d.h>
#include <pxr/base/gf/matrix4d.h>
#include <pxr/base/gf/quatd.h>
#include <pxr/base/gf/quatf.h>
#include <pxr/base/gf/quath.h>
#include <pxr/base/gf/vec2d.h>
#include <pxr/base/gf/vec2f.h>
#include <pxr/base/gf/vec2h.h>
#include <pxr/base/gf/vec2i.h>
#include <pxr/base/gf/vec3d.h>
#include <pxr/base/gf/vec3f.h>
#include <pxr/base/gf/vec3h.h>
#include <pxr/base/gf/vec3i.h>
#include <pxr/base/gf/vec4d.h>
#include <pxr/base/gf/vec4f.h>
#include <pxr/base/gf/vec4h.h>
#include <pxr/base/gf/vec4i.h>
#include <type_traits>
namespace {
struct ValueOwner {
    std::string type;
    std::vector<double> numbers;
    std::vector<int64_t> signed_values;
    std::vector<uint64_t> unsigned_values;
    std::vector<std::string> texts;
};
ValueOwner &value_owner(uint64_t h) {
    require(h != 0, "Value is closed");
    return *reinterpret_cast<ValueOwner *>(h);
}
template <class T, class S> T checked_number(S x) {
    if constexpr (std::is_integral_v<T>) {
        if constexpr (std::is_same_v<T, bool>)
            require(x <= 1, "Boolean must be 0 or 1");
        else
            require(
                static_cast<long double>(x) >=
                        static_cast<long double>(std::numeric_limits<T>::lowest()) &&
                    static_cast<long double>(x) <=
                        static_cast<long double>(std::numeric_limits<T>::max()),
                "Integer outside USD type range");
    } else {
        require(!std::isfinite(static_cast<double>(x)) ||
                    std::abs(static_cast<double>(x)) <=
                        static_cast<double>(std::numeric_limits<T>::max()),
                "Floating value outside USD type range");
    }
    return T(x);
}
template <auto Member> struct WireStorage {
    static constexpr size_t width = 1;
    static auto &values(ValueOwner &o) { return o.*Member; }
    static const auto &values(const ValueOwner &o) { return o.*Member; }
    static size_t count(const ValueOwner &o) {
        const auto size = values(o).size();
        require(o.numbers.size() + o.signed_values.size() +
                    o.unsigned_values.size() + o.texts.size() == size,
                "Wrong value storage channel");
        return size;
    }
};
using NumberStorage = WireStorage<&ValueOwner::numbers>;
using SignedStorage = WireStorage<&ValueOwner::signed_values>;
using UnsignedStorage = WireStorage<&ValueOwner::unsigned_values>;
using TextStorage = WireStorage<&ValueOwner::texts>;

template <class T> using NumericStorage = std::conditional_t<
    std::is_integral_v<T>,
    std::conditional_t<std::is_unsigned_v<T>, UnsignedStorage, SignedStorage>,
    NumberStorage>;

template <class T> struct Wire;
template <class T> struct ScalarWire : NumericStorage<T> {
    static_assert(std::is_arithmetic_v<T> || std::is_same_v<T, GfHalf>,
                  "USD values require an explicitly supported wire layout");
    using Component = std::conditional_t<std::is_same_v<T, bool>, uint8_t, T>;
    static constexpr bool native_view = true;
    static T get(const ValueOwner &o, size_t i) {
        return checked_number<T>(NumericStorage<T>::values(o).at(i));
    }
    static void put(ValueOwner &o, const T &v) {
        NumericStorage<T>::values(o).push_back(v);
    }
};
template <class T> struct VectorWire : NumericStorage<typename T::ScalarType> {
    using Component = typename T::ScalarType;
    static constexpr size_t width = T::dimension;
    static constexpr bool native_view = true;
    static T get(const ValueOwner &o, size_t i) {
        T value;
        for (size_t k = 0; k < width; ++k)
            value[k] = Wire<Component>::get(o, i + k);
        return value;
    }
    static void put(ValueOwner &o, const T &v) {
        for (size_t k = 0; k < width; ++k)
            Wire<Component>::put(o, v[k]);
    }
};
template <class T> struct MatrixWire : NumberStorage {
    using Component = typename T::ScalarType;
    static constexpr size_t width = T::numRows * T::numColumns;
    static constexpr bool native_view = true;
    static T get(const ValueOwner &o, size_t i) {
        T value(0.0);
        for (size_t r = 0; r < T::numRows; ++r)
            for (size_t c = 0; c < T::numColumns; ++c)
                value[r][c] = o.numbers.at(i + r * T::numColumns + c);
        return value;
    }
    static void put(ValueOwner &o, const T &v) {
        for (size_t r = 0; r < T::numRows; ++r)
            for (size_t c = 0; c < T::numColumns; ++c)
                o.numbers.push_back(v[r][c]);
    }
};
template <class T> struct QuaternionWire : NumberStorage {
    static constexpr size_t width = 4;
    static constexpr bool native_view = false;
    static T get(const ValueOwner &o, size_t i) {
        return T(Wire<typename T::ScalarType>::get(o, i),
                 Wire<typename T::ImaginaryType>::get(o, i + 1));
    }
    static void put(ValueOwner &o, const T &v) {
        Wire<typename T::ScalarType>::put(o, v.GetReal());
        Wire<typename T::ImaginaryType>::put(o, v.GetImaginary());
    }
};
template <class T> struct Wire : std::conditional_t<
    GfIsGfVec<T>::value, VectorWire<T>,
    std::conditional_t<GfIsGfMatrix<T>::value, MatrixWire<T>,
    std::conditional_t<GfIsGfQuat<T>::value, QuaternionWire<T>, ScalarWire<T>>>> {};

template <> struct Wire<SdfTimeCode> : NumberStorage {
    static constexpr bool native_view = false;
    static SdfTimeCode get(const ValueOwner &o, size_t i) {
        return SdfTimeCode(o.numbers.at(i));
    }
    static void put(ValueOwner &o, const SdfTimeCode &v) {
        o.numbers.push_back(v.GetValue());
    }
};
template <> struct Wire<std::string> : TextStorage {
    static constexpr bool native_view = false;
    static std::string get(const ValueOwner &o, size_t i) { return o.texts.at(i); }
    static void put(ValueOwner &o, const std::string &v) { o.texts.push_back(v); }
};
template <> struct Wire<TfToken> : TextStorage {
    static constexpr bool native_view = false;
    static TfToken get(const ValueOwner &o, size_t i) { return TfToken(o.texts.at(i)); }
    static void put(ValueOwner &o, const TfToken &v) { o.texts.push_back(v.GetString()); }
};
template <> struct Wire<SdfAssetPath> : TextStorage {
    static constexpr bool native_view = false;
    static SdfAssetPath get(const ValueOwner &o, size_t i) { return SdfAssetPath(o.texts.at(i)); }
    static void put(ValueOwner &o, const SdfAssetPath &v) { o.texts.push_back(v.GetAuthoredPath()); }
};
template <> struct Wire<SdfPathExpression> : TextStorage {
    static constexpr bool native_view = false;
    static SdfPathExpression get(const ValueOwner &o, size_t i) {
        SdfPathExpression result(o.texts.at(i));
        require(result.GetParseError().empty(), result.GetParseError());
        return result;
    }
    static void put(ValueOwner &o, const SdfPathExpression &v) { o.texts.push_back(v.GetText()); }
};
#define USDM_VALUE_TYPE(T, Width, Member) \
    static_assert(Wire<T>::width == Width, "Reviewed USD component width changed"); \
    static_assert(std::is_base_of_v<WireStorage<&ValueOwner::Member>, Wire<T>>, \
                  "Reviewed USD storage channel changed");
#include "value_types.inc"
#undef USDM_VALUE_TYPE

template <class T> VtValue pack_value(const ValueOwner &o, bool array) {
    const size_t size = Wire<T>::count(o), width = Wire<T>::width;
    require(size % width == 0, "Invalid component count");
    if (!array) {
        require(size == width, "Scalar requires exactly one element");
        return VtValue(Wire<T>::get(o, 0));
    }
    VtArray<T> result(size / width);
    for (size_t i = 0; i < result.size(); ++i)
        result[i] = Wire<T>::get(o, i * width);
    return VtValue(result);
}
template <class T> void unpack_value(ValueOwner &o, const VtValue &v, bool array) {
    if (array) {
        require(v.IsHolding<VtArray<T>>(), "Wrong USD array value type: " + o.type,
                ErrorKind::TypeMismatch);
        const auto &values = v.UncheckedGet<VtArray<T>>();
        const size_t size = values.size() * Wire<T>::width;
        Wire<T>::values(o).reserve(size);
        for (const auto &item : values)
            Wire<T>::put(o, item);
    } else {
        require(v.IsHolding<T>(), "Wrong USD scalar value type: " + o.type,
                ErrorKind::TypeMismatch);
        Wire<T>::put(o, v.UncheckedGet<T>());
    }
}

VtValue encode(const ValueOwner &o) {
    auto t = SdfSchema::GetInstance().FindType(TfToken(o.type));
    require(bool(t), "Unknown USD value type: " + o.type, ErrorKind::Unsupported);
    bool array = t.IsArray();
    auto base = t.GetScalarType().GetType();
#define USDM_VALUE_TYPE(T, Width, Member) if (base == TfType::Find<T>()) return pack_value<T>(o, array);
#include "value_types.inc"
#undef USDM_VALUE_TYPE
    throw BridgeError(ErrorKind::Unsupported, "Unsupported USD value type");
}
void decode(ValueOwner &o, const VtValue &v) {
    auto t = SdfSchema::GetInstance().FindType(TfToken(o.type));
    require(bool(t), "Unknown USD value type: " + o.type, ErrorKind::Unsupported);
    bool array = t.IsArray();
    auto base = t.GetScalarType().GetType();
#define USDM_VALUE_TYPE(T, Width, Member) if (base == TfType::Find<T>()) { unpack_value<T>(o, v, array); return; }
#include "value_types.inc"
#undef USDM_VALUE_TYPE
    throw BridgeError(ErrorKind::Unsupported, "Unsupported USD value type");
}
} // namespace
USDM_API uint64_t usdm_value_new(const char *type) noexcept {
    return protect_owned([&]() {
        require(type && *type, "Empty value type");
        auto o = std::make_unique<ValueOwner>();
        o->type = type;
        require(bool(SdfSchema::GetInstance().FindType(TfToken(type))),
                std::string("Unknown USD type: ") + type);
        return o;
    });
}
USDM_API void usdm_value_close(uint64_t h) noexcept {
    delete reinterpret_cast<ValueOwner *>(h);
}
USDM_API int32_t usdm_value_fill(uint64_t h, const double *n, int64_t nc,
                                 const int64_t *i, int64_t ic, const uint64_t *u,
                                 int64_t uc) noexcept {
    return protect(
        [&]() {
            require(nc >= 0 && ic >= 0 && uc >= 0, "Negative component count");
            auto &o = value_owner(h);
            require(!nc || n, "Null numbers");
            require(!ic || i, "Null integers");
            require(!uc || u, "Null unsigned values");
            if (nc)
                o.numbers.assign(n, n + nc);
            else
                o.numbers.clear();
            if (ic)
                o.signed_values.assign(i, i + ic);
            else
                o.signed_values.clear();
            if (uc)
                o.unsigned_values.assign(u, u + uc);
            else
                o.unsigned_values.clear();
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_value_add_text(uint64_t h, const char *text) noexcept {
    return protect(
        [&]() {
            value_owner(h).texts.emplace_back(text ? text : "");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API uint64_t usdm_value_read(uint64_t h, const char *path, const char *name,
                                  double time, int32_t default_time) noexcept {
    return protect_owned([&]() {
        auto a = attribute(h, path, name);
        VtValue v;
        require(a.Get(&v, time_code(time, default_time)), "No readable USD value",
                ErrorKind::TypeMismatch);
        auto o = std::make_unique<ValueOwner>();
        o->type = a.GetTypeName().GetAsToken().GetString();
        decode(*o, v);
        return o;
    });
}
USDM_API int32_t usdm_value_write(uint64_t h, const char *path, const char *name,
                                  double time, int32_t default_time,
                                  uint64_t v) noexcept {
    return protect(
        [&]() {
            const auto &o = value_owner(v);
            auto value = encode(o);
            auto p = prim(h, path);
            auto a = p.GetAttribute(attr_name(name));
            auto t = SdfSchema::GetInstance().FindType(TfToken(o.type));
            if (a)
                require(a.GetTypeName() == t,
                        "Existing attribute has a different USD type");
            else
                a = p.CreateAttribute(attr_name(name), t, true);
            require(a.Set(value, time_code(time, default_time)),
                    "Cannot author USD value");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int64_t usdm_value_count(uint64_t h, int32_t channel) noexcept {
    return protect(
        [&]() -> int64_t {
            const auto &o = value_owner(h);
            switch (channel) {
            case 0:
                return o.numbers.size();
            case 1:
                return o.signed_values.size();
            case 2:
                return o.unsigned_values.size();
            case 3:
                return o.texts.size();
            default:
                throw std::runtime_error("Invalid channel");
            }
        },
        int64_t(-1));
}
USDM_API int32_t usdm_value_copy(uint64_t h, double *n, int64_t nc, int64_t *i,
                                 int64_t ic, uint64_t *u, int64_t uc) noexcept {
    return protect(
        [&]() {
            const auto &o = value_owner(h);
            require(nc >= 0 && ic >= 0 && uc >= 0 && size_t(nc) == o.numbers.size() &&
                        size_t(ic) == o.signed_values.size() &&
                        size_t(uc) == o.unsigned_values.size(),
                    "Value buffer extent mismatch");
            require(!nc || n, "Null numeric buffer");
            require(!ic || i, "Null integer buffer");
            require(!uc || u, "Null unsigned buffer");
            if (nc)
                std::copy(o.numbers.begin(), o.numbers.end(), n);
            if (ic)
                std::copy(o.signed_values.begin(), o.signed_values.end(), i);
            if (uc)
                std::copy(o.unsigned_values.begin(), o.unsigned_values.end(), u);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int64_t usdm_value_text(uint64_t h, int64_t index, char *dst,
                                 int64_t capacity) noexcept {
    return protect(
        [&]() {
            const auto &o = value_owner(h);
            require(index >= -1 && (index < 0 || size_t(index) < o.texts.size()),
                    "Text index out of range");
            return copy_text(index < 0 ? o.type : o.texts[size_t(index)], dst,
                             capacity);
        },
        int64_t(-1));
}
USDM_API int32_t usdm_add_reference(uint64_t h, const char *path, const char *asset,
                                    const char *target, double offset,
                                    double scale) noexcept {
    return protect(
        [&]() {
            asset = asset ? asset : "";
            target = target ? target : "";
            require(std::isfinite(offset) && std::isfinite(scale) && scale != 0,
                    "Invalid layer offset");
            auto p = prim(h, path);
            SdfPath t;
            if (*target)
                t = prim_path(target);
            require(p.GetReferences().AddReference(
                        SdfReference(asset, t, SdfLayerOffset(offset, scale))),
                    "Cannot add reference");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_add_sublayer(uint64_t h, const char *asset, double offset,
                                   double scale) noexcept {
    return protect(
        [&]() {
            require(asset && *asset, "Empty sublayer path");
            require(std::isfinite(offset) && std::isfinite(scale) && scale != 0,
                    "Invalid layer offset");
            auto layer = owner(h).stage->GetEditTarget().GetLayer();
            auto paths = layer->GetSubLayerPaths();
            layer->InsertSubLayerPath(asset);
            layer->SetSubLayerOffset(SdfLayerOffset(offset, scale), paths.size());
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_default_prim(uint64_t h, const char *path) noexcept {
    return protect(
        [&]() {
            auto p = prim(h, path);
            require(p.GetPath().IsRootPrimPath(), "Default prim must be at the root");
            owner(h).stage->SetDefaultPrim(p);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_variant(uint64_t h, const char *path, const char *set,
                              const char *choice, int32_t create) noexcept {
    return protect(
        [&]() {
            require(set && *set && choice && *choice, "Empty variant/set");
            auto p = prim(h, path);
            auto v =
                create ? p.GetVariantSets().AddVariantSet(set) : p.GetVariantSet(set);
            if (create)
                require(v.AddVariant(choice), "Cannot add variant");
            else {
                auto names = v.GetVariantNames();
                require(std::find(names.begin(), names.end(), choice) != names.end(),
                        "Unknown variant selection");
            }
            require(v.SetVariantSelection(choice), "Cannot select variant");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_variant_edit(uint64_t h, const char *path,
                                   const char *set) noexcept {
    return protect(
        [&]() {
            auto v = prim(h, path).GetVariantSet(set);
            require(!v.GetVariantSelection().empty(),
                    "Select a variant before editing");
            auto target = v.GetVariantEditTarget();
            require(target.IsValid(), "Invalid variant edit target");
            owner(h).stage->SetEditTarget(target);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_root_edit(uint64_t h) noexcept {
    return protect(
        [&]() {
            auto stage = owner(h).stage;
            stage->SetEditTarget(stage->GetRootLayer());
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_relationship(uint64_t h, const char *path, const char *name,
                                   const char *target, int32_t clear) noexcept {
    return protect(
        [&]() {
            auto p = prim(h, path);
            auto rel = p.CreateRelationship(attr_name(name), true);
            if (clear)
                require(rel.SetTargets({}), "Cannot clear targets");
            else {
                require(target && SdfPath::IsValidPathString(target),
                        "Invalid relationship target");
                SdfPath t(target);
                require(t.IsAbsolutePath() && (t.IsPrimPath() || t.IsPropertyPath()),
                        "Expected absolute prim/property target");
                require(rel.AddTarget(t), "Cannot add target");
            }
            return int32_t(0);
        },
        int32_t(-1));
}

USDM_API int64_t usdm_value_text_size(uint64_t h, int64_t index) noexcept {
    return usdm_value_text(h, index, nullptr, 0);
}

USDM_API int32_t usdm_apply_schema(uint64_t h, const char *path, const char *schema,
                                   const char *instance) noexcept {
    return protect(
        [&]() {
            auto p = prim(h, path);
            require(schema && *schema, "Invalid schema name");
            instance = instance ? instance : "";
            std::string why;
            bool can = *instance
                           ? p.CanApplyAPI(TfToken(schema), TfToken(instance), &why)
                           : p.CanApplyAPI(TfToken(schema), &why);
            require(can, "Cannot apply schema: " + why);
            require(*instance ? p.ApplyAPI(TfToken(schema), TfToken(instance))
                              : p.ApplyAPI(TfToken(schema)),
                    "Cannot apply schema");
            return int32_t(0);
        },
        int32_t(-1));
}
