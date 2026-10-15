// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
// All storage crossing the ABI is owned; no SDK objects escape.
#include <pxr/base/gf/half.h>
#include <pxr/usd/sdf/assetPath.h>
#include <pxr/usd/sdf/timeCode.h>
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
template <class T> struct Wire;
template <> struct Wire<bool> {
    static constexpr size_t width = 1;
    static bool get(const ValueOwner &o, size_t i) {
        return checked_number<bool>(o.unsigned_values.at(i));
    }
    static void put(ValueOwner &o, const bool &v) {
        o.unsigned_values.push_back(v);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.unsigned_values.size(),
                "Wrong value storage channel");
        return o.unsigned_values.size();
    }
};
template <> struct Wire<uint8_t> {
    static constexpr size_t width = 1;
    static uint8_t get(const ValueOwner &o, size_t i) {
        return checked_number<uint8_t>(o.unsigned_values.at(i));
    }
    static void put(ValueOwner &o, const uint8_t &v) {
        o.unsigned_values.push_back(v);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.unsigned_values.size(),
                "Wrong value storage channel");
        return o.unsigned_values.size();
    }
};
template <> struct Wire<int32_t> {
    static constexpr size_t width = 1;
    static int32_t get(const ValueOwner &o, size_t i) {
        return checked_number<int32_t>(o.signed_values.at(i));
    }
    static void put(ValueOwner &o, const int32_t &v) {
        o.signed_values.push_back(v);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.signed_values.size(),
                "Wrong value storage channel");
        return o.signed_values.size();
    }
};
template <> struct Wire<uint32_t> {
    static constexpr size_t width = 1;
    static uint32_t get(const ValueOwner &o, size_t i) {
        return checked_number<uint32_t>(o.unsigned_values.at(i));
    }
    static void put(ValueOwner &o, const uint32_t &v) {
        o.unsigned_values.push_back(v);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.unsigned_values.size(),
                "Wrong value storage channel");
        return o.unsigned_values.size();
    }
};
template <> struct Wire<int64_t> {
    static constexpr size_t width = 1;
    static int64_t get(const ValueOwner &o, size_t i) {
        return checked_number<int64_t>(o.signed_values.at(i));
    }
    static void put(ValueOwner &o, const int64_t &v) {
        o.signed_values.push_back(v);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.signed_values.size(),
                "Wrong value storage channel");
        return o.signed_values.size();
    }
};
template <> struct Wire<uint64_t> {
    static constexpr size_t width = 1;
    static uint64_t get(const ValueOwner &o, size_t i) {
        return checked_number<uint64_t>(o.unsigned_values.at(i));
    }
    static void put(ValueOwner &o, const uint64_t &v) {
        o.unsigned_values.push_back(v);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.unsigned_values.size(),
                "Wrong value storage channel");
        return o.unsigned_values.size();
    }
};
template <> struct Wire<GfHalf> {
    static constexpr size_t width = 1;
    static GfHalf get(const ValueOwner &o, size_t i) {
        return checked_number<GfHalf>(o.numbers.at(i));
    }
    static void put(ValueOwner &o, const GfHalf &v) {
        o.numbers.push_back(v);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<float> {
    static constexpr size_t width = 1;
    static float get(const ValueOwner &o, size_t i) {
        return checked_number<float>(o.numbers.at(i));
    }
    static void put(ValueOwner &o, const float &v) {
        o.numbers.push_back(v);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<double> {
    static constexpr size_t width = 1;
    static double get(const ValueOwner &o, size_t i) {
        return checked_number<double>(o.numbers.at(i));
    }
    static void put(ValueOwner &o, const double &v) {
        o.numbers.push_back(v);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<SdfTimeCode> {
    static constexpr size_t width = 1;
    static SdfTimeCode get(const ValueOwner &o, size_t i) {
        return SdfTimeCode(o.numbers.at(i));
    }
    static void put(ValueOwner &o, const SdfTimeCode &v) {
        o.numbers.push_back(v.GetValue());
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<std::string> {
    static constexpr size_t width = 1;
    static std::string get(const ValueOwner &o, size_t i) {
        return o.texts.at(i);
    }
    static void put(ValueOwner &o, const std::string &v) {
        o.texts.push_back(v);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.texts.size(),
                "Wrong value storage channel");
        return o.texts.size();
    }
};
template <> struct Wire<TfToken> {
    static constexpr size_t width = 1;
    static TfToken get(const ValueOwner &o, size_t i) {
        return TfToken(o.texts.at(i));
    }
    static void put(ValueOwner &o, const TfToken &v) {
        o.texts.push_back(v.GetString());
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.texts.size(),
                "Wrong value storage channel");
        return o.texts.size();
    }
};
template <> struct Wire<SdfAssetPath> {
    static constexpr size_t width = 1;
    static SdfAssetPath get(const ValueOwner &o, size_t i) {
        return SdfAssetPath(o.texts.at(i));
    }
    static void put(ValueOwner &o, const SdfAssetPath &v) {
        o.texts.push_back(v.GetAuthoredPath());
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.texts.size(),
                "Wrong value storage channel");
        return o.texts.size();
    }
};
template <> struct Wire<GfMatrix2d> {
    static constexpr size_t width = 4;
    static GfMatrix2d get(const ValueOwner &o, size_t i) {
        GfMatrix2d v(0.0);
        for (int a = 0; a < 2; ++a)
            for (int b = 0; b < 2; ++b)
                v[a][b] = o.numbers.at(i + a * 2 + b);
        return v;
    }
    static void put(ValueOwner &o, const GfMatrix2d &v) {
        for (int a = 0; a < 2; ++a)
            for (int b = 0; b < 2; ++b)
                o.numbers.push_back(v[a][b]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfMatrix3d> {
    static constexpr size_t width = 9;
    static GfMatrix3d get(const ValueOwner &o, size_t i) {
        GfMatrix3d v(0.0);
        for (int a = 0; a < 3; ++a)
            for (int b = 0; b < 3; ++b)
                v[a][b] = o.numbers.at(i + a * 3 + b);
        return v;
    }
    static void put(ValueOwner &o, const GfMatrix3d &v) {
        for (int a = 0; a < 3; ++a)
            for (int b = 0; b < 3; ++b)
                o.numbers.push_back(v[a][b]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfMatrix4d> {
    static constexpr size_t width = 16;
    static GfMatrix4d get(const ValueOwner &o, size_t i) {
        GfMatrix4d v(0.0);
        for (int a = 0; a < 4; ++a)
            for (int b = 0; b < 4; ++b)
                v[a][b] = o.numbers.at(i + a * 4 + b);
        return v;
    }
    static void put(ValueOwner &o, const GfMatrix4d &v) {
        for (int a = 0; a < 4; ++a)
            for (int b = 0; b < 4; ++b)
                o.numbers.push_back(v[a][b]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfQuatd> {
    static constexpr size_t width = 4;
    static GfQuatd get(const ValueOwner &o, size_t i) {
        return GfQuatd(checked_number<double>(o.numbers.at(i)),
                       GfVec3d(checked_number<double>(o.numbers.at(i + 1)),
                               checked_number<double>(o.numbers.at(i + 2)),
                               checked_number<double>(o.numbers.at(i + 3))));
    }
    static void put(ValueOwner &o, const GfQuatd &v) {
        o.numbers.push_back(v.GetReal());
        for (int k = 0; k < 3; ++k)
            o.numbers.push_back(v.GetImaginary()[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfQuatf> {
    static constexpr size_t width = 4;
    static GfQuatf get(const ValueOwner &o, size_t i) {
        return GfQuatf(checked_number<float>(o.numbers.at(i)),
                       GfVec3f(checked_number<float>(o.numbers.at(i + 1)),
                               checked_number<float>(o.numbers.at(i + 2)),
                               checked_number<float>(o.numbers.at(i + 3))));
    }
    static void put(ValueOwner &o, const GfQuatf &v) {
        o.numbers.push_back(v.GetReal());
        for (int k = 0; k < 3; ++k)
            o.numbers.push_back(v.GetImaginary()[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfQuath> {
    static constexpr size_t width = 4;
    static GfQuath get(const ValueOwner &o, size_t i) {
        return GfQuath(checked_number<GfHalf>(o.numbers.at(i)),
                       GfVec3h(checked_number<GfHalf>(o.numbers.at(i + 1)),
                               checked_number<GfHalf>(o.numbers.at(i + 2)),
                               checked_number<GfHalf>(o.numbers.at(i + 3))));
    }
    static void put(ValueOwner &o, const GfQuath &v) {
        o.numbers.push_back(v.GetReal());
        for (int k = 0; k < 3; ++k)
            o.numbers.push_back(v.GetImaginary()[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfVec2d> {
    static constexpr size_t width = 2;
    static GfVec2d get(const ValueOwner &o, size_t i) {
        GfVec2d v;
        for (int k = 0; k < 2; ++k)
            v[k] = checked_number<double>(o.numbers.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec2d &v) {
        for (int k = 0; k < 2; ++k)
            o.numbers.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfVec2f> {
    static constexpr size_t width = 2;
    static GfVec2f get(const ValueOwner &o, size_t i) {
        GfVec2f v;
        for (int k = 0; k < 2; ++k)
            v[k] = checked_number<float>(o.numbers.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec2f &v) {
        for (int k = 0; k < 2; ++k)
            o.numbers.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfVec2h> {
    static constexpr size_t width = 2;
    static GfVec2h get(const ValueOwner &o, size_t i) {
        GfVec2h v;
        for (int k = 0; k < 2; ++k)
            v[k] = checked_number<GfHalf>(o.numbers.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec2h &v) {
        for (int k = 0; k < 2; ++k)
            o.numbers.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfVec2i> {
    static constexpr size_t width = 2;
    static GfVec2i get(const ValueOwner &o, size_t i) {
        GfVec2i v;
        for (int k = 0; k < 2; ++k)
            v[k] = checked_number<int32_t>(o.signed_values.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec2i &v) {
        for (int k = 0; k < 2; ++k)
            o.signed_values.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.signed_values.size(),
                "Wrong value storage channel");
        return o.signed_values.size();
    }
};
template <> struct Wire<GfVec3d> {
    static constexpr size_t width = 3;
    static GfVec3d get(const ValueOwner &o, size_t i) {
        GfVec3d v;
        for (int k = 0; k < 3; ++k)
            v[k] = checked_number<double>(o.numbers.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec3d &v) {
        for (int k = 0; k < 3; ++k)
            o.numbers.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfVec3f> {
    static constexpr size_t width = 3;
    static GfVec3f get(const ValueOwner &o, size_t i) {
        GfVec3f v;
        for (int k = 0; k < 3; ++k)
            v[k] = checked_number<float>(o.numbers.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec3f &v) {
        for (int k = 0; k < 3; ++k)
            o.numbers.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfVec3h> {
    static constexpr size_t width = 3;
    static GfVec3h get(const ValueOwner &o, size_t i) {
        GfVec3h v;
        for (int k = 0; k < 3; ++k)
            v[k] = checked_number<GfHalf>(o.numbers.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec3h &v) {
        for (int k = 0; k < 3; ++k)
            o.numbers.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfVec3i> {
    static constexpr size_t width = 3;
    static GfVec3i get(const ValueOwner &o, size_t i) {
        GfVec3i v;
        for (int k = 0; k < 3; ++k)
            v[k] = checked_number<int32_t>(o.signed_values.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec3i &v) {
        for (int k = 0; k < 3; ++k)
            o.signed_values.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.signed_values.size(),
                "Wrong value storage channel");
        return o.signed_values.size();
    }
};
template <> struct Wire<GfVec4d> {
    static constexpr size_t width = 4;
    static GfVec4d get(const ValueOwner &o, size_t i) {
        GfVec4d v;
        for (int k = 0; k < 4; ++k)
            v[k] = checked_number<double>(o.numbers.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec4d &v) {
        for (int k = 0; k < 4; ++k)
            o.numbers.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfVec4f> {
    static constexpr size_t width = 4;
    static GfVec4f get(const ValueOwner &o, size_t i) {
        GfVec4f v;
        for (int k = 0; k < 4; ++k)
            v[k] = checked_number<float>(o.numbers.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec4f &v) {
        for (int k = 0; k < 4; ++k)
            o.numbers.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfVec4h> {
    static constexpr size_t width = 4;
    static GfVec4h get(const ValueOwner &o, size_t i) {
        GfVec4h v;
        for (int k = 0; k < 4; ++k)
            v[k] = checked_number<GfHalf>(o.numbers.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec4h &v) {
        for (int k = 0; k < 4; ++k)
            o.numbers.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.numbers.size(),
                "Wrong value storage channel");
        return o.numbers.size();
    }
};
template <> struct Wire<GfVec4i> {
    static constexpr size_t width = 4;
    static GfVec4i get(const ValueOwner &o, size_t i) {
        GfVec4i v;
        for (int k = 0; k < 4; ++k)
            v[k] = checked_number<int32_t>(o.signed_values.at(i + k));
        return v;
    }
    static void put(ValueOwner &o, const GfVec4i &v) {
        for (int k = 0; k < 4; ++k)
            o.signed_values.push_back(v[k]);
    }
    static size_t count(const ValueOwner &o) {
        require(o.numbers.size() + o.signed_values.size() + o.unsigned_values.size() +
                        o.texts.size() ==
                    o.signed_values.size(),
                "Wrong value storage channel");
        return o.signed_values.size();
    }
};
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
        if constexpr (std::is_same_v<T, std::string> || std::is_same_v<T, TfToken> ||
                      std::is_same_v<T, SdfAssetPath>)
            o.texts.reserve(size);
        else if constexpr (std::is_integral_v<T> && std::is_unsigned_v<T>)
            o.unsigned_values.reserve(size);
        else if constexpr (std::is_integral_v<T> || std::is_same_v<T, GfVec2i> ||
                           std::is_same_v<T, GfVec3i> || std::is_same_v<T, GfVec4i>)
            o.signed_values.reserve(size);
        else
            o.numbers.reserve(size);
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
    if (base == TfType::Find<bool>())
        return pack_value<bool>(o, array);
    if (base == TfType::Find<uint8_t>())
        return pack_value<uint8_t>(o, array);
    if (base == TfType::Find<int32_t>())
        return pack_value<int32_t>(o, array);
    if (base == TfType::Find<uint32_t>())
        return pack_value<uint32_t>(o, array);
    if (base == TfType::Find<int64_t>())
        return pack_value<int64_t>(o, array);
    if (base == TfType::Find<uint64_t>())
        return pack_value<uint64_t>(o, array);
    if (base == TfType::Find<GfHalf>())
        return pack_value<GfHalf>(o, array);
    if (base == TfType::Find<float>())
        return pack_value<float>(o, array);
    if (base == TfType::Find<double>())
        return pack_value<double>(o, array);
    if (base == TfType::Find<SdfTimeCode>())
        return pack_value<SdfTimeCode>(o, array);
    if (base == TfType::Find<std::string>())
        return pack_value<std::string>(o, array);
    if (base == TfType::Find<TfToken>())
        return pack_value<TfToken>(o, array);
    if (base == TfType::Find<SdfAssetPath>())
        return pack_value<SdfAssetPath>(o, array);
    if (base == TfType::Find<GfMatrix2d>())
        return pack_value<GfMatrix2d>(o, array);
    if (base == TfType::Find<GfMatrix3d>())
        return pack_value<GfMatrix3d>(o, array);
    if (base == TfType::Find<GfMatrix4d>())
        return pack_value<GfMatrix4d>(o, array);
    if (base == TfType::Find<GfQuatd>())
        return pack_value<GfQuatd>(o, array);
    if (base == TfType::Find<GfQuatf>())
        return pack_value<GfQuatf>(o, array);
    if (base == TfType::Find<GfQuath>())
        return pack_value<GfQuath>(o, array);
    if (base == TfType::Find<GfVec2d>())
        return pack_value<GfVec2d>(o, array);
    if (base == TfType::Find<GfVec2f>())
        return pack_value<GfVec2f>(o, array);
    if (base == TfType::Find<GfVec2h>())
        return pack_value<GfVec2h>(o, array);
    if (base == TfType::Find<GfVec2i>())
        return pack_value<GfVec2i>(o, array);
    if (base == TfType::Find<GfVec3d>())
        return pack_value<GfVec3d>(o, array);
    if (base == TfType::Find<GfVec3f>())
        return pack_value<GfVec3f>(o, array);
    if (base == TfType::Find<GfVec3h>())
        return pack_value<GfVec3h>(o, array);
    if (base == TfType::Find<GfVec3i>())
        return pack_value<GfVec3i>(o, array);
    if (base == TfType::Find<GfVec4d>())
        return pack_value<GfVec4d>(o, array);
    if (base == TfType::Find<GfVec4f>())
        return pack_value<GfVec4f>(o, array);
    if (base == TfType::Find<GfVec4h>())
        return pack_value<GfVec4h>(o, array);
    if (base == TfType::Find<GfVec4i>())
        return pack_value<GfVec4i>(o, array);
    throw BridgeError(ErrorKind::Unsupported, "Unsupported USD value type");
}
void decode(ValueOwner &o, const VtValue &v) {
    auto t = SdfSchema::GetInstance().FindType(TfToken(o.type));
    require(bool(t), "Unknown USD value type: " + o.type, ErrorKind::Unsupported);
    bool array = t.IsArray();
    auto base = t.GetScalarType().GetType();
    if (base == TfType::Find<bool>()) {
        unpack_value<bool>(o, v, array);
        return;
    }
    if (base == TfType::Find<uint8_t>()) {
        unpack_value<uint8_t>(o, v, array);
        return;
    }
    if (base == TfType::Find<int32_t>()) {
        unpack_value<int32_t>(o, v, array);
        return;
    }
    if (base == TfType::Find<uint32_t>()) {
        unpack_value<uint32_t>(o, v, array);
        return;
    }
    if (base == TfType::Find<int64_t>()) {
        unpack_value<int64_t>(o, v, array);
        return;
    }
    if (base == TfType::Find<uint64_t>()) {
        unpack_value<uint64_t>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfHalf>()) {
        unpack_value<GfHalf>(o, v, array);
        return;
    }
    if (base == TfType::Find<float>()) {
        unpack_value<float>(o, v, array);
        return;
    }
    if (base == TfType::Find<double>()) {
        unpack_value<double>(o, v, array);
        return;
    }
    if (base == TfType::Find<SdfTimeCode>()) {
        unpack_value<SdfTimeCode>(o, v, array);
        return;
    }
    if (base == TfType::Find<std::string>()) {
        unpack_value<std::string>(o, v, array);
        return;
    }
    if (base == TfType::Find<TfToken>()) {
        unpack_value<TfToken>(o, v, array);
        return;
    }
    if (base == TfType::Find<SdfAssetPath>()) {
        unpack_value<SdfAssetPath>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfMatrix2d>()) {
        unpack_value<GfMatrix2d>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfMatrix3d>()) {
        unpack_value<GfMatrix3d>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfMatrix4d>()) {
        unpack_value<GfMatrix4d>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfQuatd>()) {
        unpack_value<GfQuatd>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfQuatf>()) {
        unpack_value<GfQuatf>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfQuath>()) {
        unpack_value<GfQuath>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec2d>()) {
        unpack_value<GfVec2d>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec2f>()) {
        unpack_value<GfVec2f>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec2h>()) {
        unpack_value<GfVec2h>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec2i>()) {
        unpack_value<GfVec2i>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec3d>()) {
        unpack_value<GfVec3d>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec3f>()) {
        unpack_value<GfVec3f>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec3h>()) {
        unpack_value<GfVec3h>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec3i>()) {
        unpack_value<GfVec3i>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec4d>()) {
        unpack_value<GfVec4d>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec4f>()) {
        unpack_value<GfVec4f>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec4h>()) {
        unpack_value<GfVec4h>(o, v, array);
        return;
    }
    if (base == TfType::Find<GfVec4i>()) {
        unpack_value<GfVec4i>(o, v, array);
        return;
    }
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
