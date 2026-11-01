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
USDM_API uint64_t usdm_schema_types() noexcept {
    return protect_owned([] {
        auto result = std::make_unique<StringsOwner>();
        std::set<TfType> types;
        PlugRegistry::GetAllDerivedTypes(TfType::Find<UsdSchemaBase>(), &types);
        const auto &registry = UsdSchemaRegistry::GetInstance();
        std::map<std::string, std::pair<std::string, const UsdPrimDefinition *>>
            entries;
        for (const auto &type : types) {
            auto name = UsdSchemaRegistry::GetSchemaTypeName(type);
            if (name.IsEmpty())
                continue;
            const auto *definition = registry.FindConcretePrimDefinition(name);
            std::string kind = "typed";
            if (!definition) {
                definition = registry.FindAppliedAPIPrimDefinition(name);
                kind = "api";
            }
            if (!definition) {
                definition = registry.FindAbstractPrimDefinition(name);
                kind = "abstract";
            }
            if (!definition)
                kind = "unapplied";
            entries.emplace(name.GetString(), std::make_pair(kind, definition));
        }
        for (const auto &entry : entries) {
            std::string names;
            if (entry.second.second)
                for (const auto &name : entry.second.second->GetPropertyNames())
                    names += name.GetString() + "\n";
            result->values.insert(result->values.end(),
                                  {entry.first, entry.second.first, names});
        }
        return result;
    });
}
