// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
// Exercise the real SDK diagnostic boundary with a deterministic failing call.
#include "../native/bridge.cpp"
#include <cassert>
namespace {
int destroyed = 0;
struct DiagnosticProbe {
    ~DiagnosticProbe() {
        ++destroyed;
    }
};

void reject_value(ValueOwner value) {
    assert(protect([&] { encode(value); return 0; }, -1) == -1);
    assert(core_error.kind == ErrorKind::InvalidArgument);
}

void check_value_layouts() {
    ValueOwner value;
    value.type = "int";
    value.signed_values = {std::numeric_limits<int32_t>::lowest()};
    assert(encode(value).UncheckedGet<int32_t>() == std::numeric_limits<int32_t>::lowest());
    value.numbers = {0};
    reject_value(value);
    value.numbers.clear();
    value.signed_values = {int64_t(std::numeric_limits<int32_t>::max()) + 1};
    reject_value(value);
    value.signed_values.clear();
    for (const auto &item : std::vector<std::pair<std::string, uint64_t>>{
             {"bool", 2}, {"uchar", 256}, {"uint", uint64_t(1) << 32}}) {
        value.type = item.first;
        value.unsigned_values = {item.second};
        reject_value(value);
    }
    value.type = "uint64";
    value.unsigned_values = {std::numeric_limits<uint64_t>::max()};
    assert(encode(value).UncheckedGet<uint64_t>() == std::numeric_limits<uint64_t>::max());
    value.unsigned_values.clear();
    for (const char *type : {"half", "float"}) {
        value.type = type;
        value.numbers = {std::numeric_limits<double>::max()};
        reject_value(value);
    }
    value.type = "float3";
    value.numbers = {1, 2, std::numeric_limits<double>::max()};
    reject_value(value);
    value.type = "matrix3d";
    value.numbers = {1, 2, 3, 4, 5, 6, 7, 8};
    reject_value(value);
    value.type = "quatf";
    value.numbers = {1, 2, 3, 4};
    const auto rotation = encode(value).UncheckedGet<GfQuatf>();
    assert(rotation.GetReal() == 1 && rotation.GetImaginary() == GfVec3f(2, 3, 4));
    value.type = "double[]";
    value.numbers = {std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()};
    const auto floats = encode(value).UncheckedGet<VtDoubleArray>();
    assert(std::isinf(floats[0]) && std::isnan(floats[1]));
    assert(protect([&] { encode(value); return 0; }, -1) == 0 && core_error.message.empty());
}
} // namespace
int main() {
    check_value_layouts();
    const auto rejected = protect_owned([]() {
        auto result = std::make_unique<DiagnosticProbe>();
        TF_RUNTIME_ERROR("Injected SDK failure after snapshot allocation");
        return result;
    });
    assert(rejected == 0 && destroyed == 1);
    assert(core_error.message.find("Injected SDK failure") != std::string::npos);
    const auto accepted =
        protect_owned([]() { return std::make_unique<DiagnosticProbe>(); });
    assert(accepted != 0 && destroyed == 1 && core_error.message.empty());
    delete reinterpret_cast<DiagnosticProbe *>(accepted);
    assert(destroyed == 2);
    assert(protect([]() -> int { throw BridgeError(ErrorKind::Io, "write failed"); }, -1) == -1);
    assert(core_error.kind == ErrorKind::Io && core_error.message == "write failed");
    assert(protect([]() -> int { throw std::bad_alloc(); }, -1) == -1);
    assert(core_error.kind == ErrorKind::Resource);
    assert(protect([]() -> int { throw 42; }, -1) == -1);
    assert(core_error.kind == ErrorKind::Internal);
    assert(protect([] { return 0; }, -1) == 0 && core_error.message.empty());
}
