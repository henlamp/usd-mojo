// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
#pragma once
#include <cstdint>
#include <new>
#include <stdexcept>
#include <string>
#include <utility>

namespace usd_mojo_native {
enum class ErrorKind : int32_t {
    InvalidArgument = 1, NotFound = 2, TypeMismatch = 3, Unsupported = 4,
    InvalidData = 5, Io = 6, Sdk = 7, Incompatible = 8, Internal = 9, Resource = 10
};
struct BridgeError : std::runtime_error {
    ErrorKind kind;
    BridgeError(ErrorKind category, const std::string &message)
        : std::runtime_error(message), kind(category) {}
};
inline void require(bool condition, const std::string &message,
                    ErrorKind kind = ErrorKind::InvalidArgument) {
    if (!condition) throw BridgeError(kind, message);
}
inline void require(bool condition, const char *message,
                    ErrorKind kind = ErrorKind::InvalidArgument) {
    if (!condition) throw BridgeError(kind, message);
}
struct ErrorState {
    std::string message;
    ErrorKind kind = ErrorKind::Internal;

    template<class F, class T> T protect(F &&action, T failure) noexcept {
        try {
            message.clear();
            kind = ErrorKind::Internal;
            return action();
        } catch (const BridgeError &error) {
            kind = error.kind;
            message = error.what();
        } catch (const std::bad_alloc &error) {
            kind = ErrorKind::Resource;
            message = error.what();
        } catch (const std::exception &error) {
            kind = ErrorKind::Sdk;
            message = error.what();
        } catch (...) {
            message = "Unknown exception in native bridge";
        }
        return failure;
    }
};
}
