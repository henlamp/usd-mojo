// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
namespace {
bool supported_value_type(const TfType &base) {
#define USDM_VALUE_TYPE(T, Width, Member)                                                             \
    if (base == TfType::Find<T>())                                                     \
        return true;
#include "value_types.inc"
#undef USDM_VALUE_TYPE
    return false;
}
} // namespace
USDM_API uint64_t usdm_value_types() noexcept {
    return protect_owned([] {
        auto result = std::make_unique<StringsOwner>();
        auto types = SdfSchema::GetInstance().GetAllTypes();
        std::sort(types.begin(), types.end(), [](const auto &a, const auto &b) {
            return a.GetAsToken().GetString() < b.GetAsToken().GetString();
        });
        for (const auto &type : types) {
            bool view = false;
            if (type.IsArray()) {
                NativeArrayOwner array;
                array.type = type.GetAsToken().GetString();
                array.value = type.GetDefaultValue();
                try {
                    describe_array(array);
                    view = true;
                } catch (const BridgeError &e) {
                    if (e.kind != ErrorKind::Unsupported)
                        throw;
                }
            }
            const auto base = type.GetScalarType().GetType();
            result->values.insert(
                result->values.end(),
                {type.GetAsToken().GetString(), base.GetTypeName(),
                 type.GetRole().GetString(), type.IsArray() ? "1" : "0",
                 supported_value_type(base) ? "1" : "0", view ? "1" : "0"});
        }
        return result;
    });
}
