// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
namespace {
struct NativeArrayOwner {
    VtValue value;
    std::string type;
    uint64_t kind = 0, count = 0, width = 0, element_size = 0;
    const void *data = nullptr;
};
NativeArrayOwner &native_array_owner(uint64_t h) {
    require(h != 0, "Array snapshot is closed");
    return *reinterpret_cast<NativeArrayOwner *>(h);
}
template <class T> constexpr uint64_t component_kind() {
    if constexpr (std::is_same_v<T, bool> || std::is_same_v<T, uint8_t>) return 1;
    else if constexpr (std::is_same_v<T, int32_t>) return 2;
    else if constexpr (std::is_same_v<T, uint32_t>) return 3;
    else if constexpr (std::is_same_v<T, int64_t>) return 4;
    else if constexpr (std::is_same_v<T, uint64_t>) return 5;
    else if constexpr (std::is_same_v<T, GfHalf>) return 6;
    else if constexpr (std::is_same_v<T, float>) return 7;
    else {
        static_assert(std::is_same_v<T, double>, "Unknown native component type");
        return 8;
    }
}
template <class T> bool describe_array(NativeArrayOwner &owner) {
    if constexpr (!Wire<T>::native_view) return false;
    else {
        using Component = typename Wire<T>::Component;
        constexpr auto width = Wire<T>::width;
        static_assert(sizeof(T) == width * sizeof(Component), "Packed SDK component layout required");
        static_assert(alignof(T) >= alignof(Component), "Aligned SDK components required");
        if (!owner.value.IsHolding<VtArray<T>>()) return false;
        const auto &array = owner.value.UncheckedGet<VtArray<T>>();
        require(array.size() <= uint64_t(std::numeric_limits<int64_t>::max()) / width / sizeof(Component),
                "Array extent exceeds the host addressable range", ErrorKind::Resource);
        owner.kind = component_kind<Component>();
        owner.width = width;
        owner.count = array.size();
        owner.element_size = sizeof(Component);
        owner.data = array.cdata();
        return true;
    }
}
void describe_array(NativeArrayOwner &o) {
#define USDM_VALUE_TYPE(T, Width, Member) if (describe_array<T>(o)) return;
#include "value_types.inc"
#undef USDM_VALUE_TYPE
    throw BridgeError(ErrorKind::Unsupported, "No native component view for USD type " + o.type);
}
template <class T> bool fill_array(NativeArrayOwner &o, const void *data, uint64_t components) {
    if constexpr (!Wire<T>::native_view) return false;
    else {
        if (!o.value.IsHolding<VtArray<T>>()) return false;
        VtArray<T> array(size_t(components / o.width));
        if constexpr (std::is_same_v<T, bool>) {
            auto input = static_cast<const uint8_t *>(data);
            for (size_t i = 0; i < array.size(); ++i) array[i] = input[i] != 0;
        } else if (components) {
            std::memcpy(static_cast<void *>(array.data()), data, size_t(components * o.element_size));
        }
        o.value = VtValue(std::move(array));
        return true;
    }
}
void fill_array(NativeArrayOwner &o, const void *data, uint64_t components) {
#define USDM_VALUE_TYPE(T, Width, Member) if (fill_array<T>(o, data, components)) return;
#include "value_types.inc"
#undef USDM_VALUE_TYPE
    throw BridgeError(ErrorKind::Unsupported, "No native array writer for this USD type");
}
}
USDM_API int32_t usdm_native_array_write(uint64_t h, const char *path, const char *name, const char *type,
        const void *data, int64_t components, uint64_t kind, double time, int32_t is_default) noexcept {
    return protect([&] {
        require(type && *type && components >= 0 && (!components || data), "Invalid native array input");
        auto tc = time_code(time, is_default);
        auto t = SdfSchema::GetInstance().FindType(TfToken(type));
        require(t && t.IsArray(), "Expected a registered USD array type", ErrorKind::TypeMismatch);
        NativeArrayOwner input;
        input.type = type; input.value = t.GetDefaultValue();
        describe_array(input);
        require(kind == input.kind, "Input component dtype differs from the USD array type", ErrorKind::TypeMismatch);
        require(uint64_t(components) % input.width == 0, "Incomplete vector/matrix element");
        require(uint64_t(components) <= uint64_t(std::numeric_limits<int64_t>::max()) / input.element_size,
            "Native array extent exceeds the host addressable range", ErrorKind::Resource);
        if (input.value.IsHolding<VtArray<bool>>()) {
            const auto bytes = static_cast<const uint8_t *>(data);
            for (int64_t i = 0; i < components; ++i) require(bytes[i] <= 1, "Boolean components must be 0 or 1");
        }
        auto p = prim(h, path);
        auto n = attr_name(name);
        auto a = p.GetAttribute(n);
        require(!a || a.GetTypeName() == t, "Existing attribute has a different USD type");
        fill_array(input, data, uint64_t(components));
        if (!a) a = p.CreateAttribute(n, t, true);
        require(a.Set(input.value, tc), "Cannot author native array");
        return int32_t(0);
    }, int32_t(-1));
}
USDM_API uint64_t usdm_native_array(uint64_t h, const char *path, const char *name, double t, int32_t d) noexcept {
    return protect_owned([&] {
        auto a = attribute(h, path, name);
        require(a.GetTypeName().IsArray(), "Array snapshot requires an array attribute", ErrorKind::TypeMismatch);
        auto result = std::make_unique<NativeArrayOwner>();
        result->type = a.GetTypeName().GetAsToken().GetString();
        require(a.Get(&result->value, time_code(t, d)), "Array attribute has no value", ErrorKind::NotFound);
        describe_array(*result);
        return result;
    });
}
USDM_API void usdm_native_array_close(uint64_t h) noexcept { delete reinterpret_cast<NativeArrayOwner *>(h); }
USDM_API uint64_t usdm_native_array_type(uint64_t h) noexcept {
    return protect_owned([&] { return editor_text(native_array_owner(h).type); });
}
USDM_API int32_t usdm_native_array_info(uint64_t h, uint64_t *info, int64_t count) noexcept {
    return protect([&] {
        require(info && count == 7, "Native array metadata extent mismatch");
        const auto &o = native_array_owner(h);
        info[0] = o.kind; info[1] = o.count; info[2] = o.width;
        info[3] = o.count * o.width; info[4] = o.count * o.width * o.element_size;
        info[5] = reinterpret_cast<uint64_t>(o.data); info[6] = o.element_size;
        return int32_t(0);
    }, int32_t(-1));
}
