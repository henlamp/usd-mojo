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
} // namespace
int main() {
    const auto rejected = protect_owned([]() {
        auto result = std::make_unique<DiagnosticProbe>();
        TF_RUNTIME_ERROR("Injected SDK failure after snapshot allocation");
        return result;
    });
    assert(rejected == 0 && destroyed == 1);
    assert(last_error.find("Injected SDK failure") != std::string::npos);
    const auto accepted =
        protect_owned([]() { return std::make_unique<DiagnosticProbe>(); });
    assert(accepted != 0 && destroyed == 1 && last_error.empty());
    delete reinterpret_cast<DiagnosticProbe *>(accepted);
    assert(destroyed == 2);
}
