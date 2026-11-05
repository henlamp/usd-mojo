// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
// Optional Hydra module. Core scene consumers do not link this library.
#include <pxr/pxr.h>
#include "error_bridge.h"
#include <pxr/base/gf/half.h>
#include <pxr/base/tf/errorMark.h>
#include <pxr/base/tf/diagnosticMgr.h>
#include <pxr/base/tf/warning.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/usdGeom/camera.h>
#include <pxr/usdImaging/usdImagingGL/engine.h>
#include <pxr/imaging/hgi/hgi.h>
#include <pxr/imaging/cameraUtil/conformWindow.h>
#include <pxr/imaging/hgi/tokens.h>
#include <pxr/imaging/hd/renderBuffer.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

PXR_NAMESPACE_USING_DIRECTIVE
UsdStageRefPtr usdm_internal_stage(uint64_t handle);
#define USDM_IMAGE_API extern "C" __attribute__((visibility("default")))
namespace {
using usd_mojo_native::ErrorKind;
using usd_mojo_native::BridgeError;
using usd_mojo_native::require;
thread_local usd_mojo_native::ErrorState image_error;
class RenderWarnings final : public TfDiagnosticMgr::Delegate {
    std::mutex mutex;
    std::string message;
public:
    RenderWarnings() { TfDiagnosticMgr::GetInstance().AddDelegate(this); }
    ~RenderWarnings() override { TfDiagnosticMgr::GetInstance().RemoveDelegate(this); }
    void IssueError(const TfError &) override {}
    void IssueStatus(const TfStatus &) override {}
    void IssueFatalError(const TfCallContext &, const std::string &) override { std::abort(); }
    void IssueWarning(const TfWarning &warning) override {
        std::lock_guard<std::mutex> guard(mutex);
        message += warning.GetCommentary() + "\n";
    }
    std::string text() { std::lock_guard<std::mutex> guard(mutex); return message; }
};
struct ImageOwner {
    int width, height;
    bool converged;
    std::vector<float> pixels;
};
struct RenderSessionOwner {
    UsdStageRefPtr stage;
    HgiUniquePtr hgi;
    // Destroy the engine before its Hgi driver and source stage.
    std::unique_ptr<UsdImagingGLEngine> engine;
    std::thread::id thread = std::this_thread::get_id();
    int width, height;
    uint64_t frame = 0;
    bool has_frame = false, converged = false;
};
template<class F, class T> T image_protect(F &&f, T failure) noexcept {
    return image_error.protect([&]() {
        TfErrorMark mark;
        RenderWarnings warnings;
        auto result = f();
        if (!mark.IsClean()) {
            std::string message;
            for (const auto &error : mark) message += error.GetCommentary() + "\n";
            mark.Clear();
            throw BridgeError(ErrorKind::Sdk, message);
        }
        const auto message = warnings.text();
        if (!message.empty()) throw BridgeError(ErrorKind::Sdk, message);
        return result;
    }, std::move(failure));
}
template<class F> uint64_t image_owned(F &&f) noexcept {
    using Owner = decltype(f());
    auto result = image_protect(std::forward<F>(f), Owner{});
    return reinterpret_cast<uint64_t>(result.release());
}
RenderSessionOwner &session_owner(uint64_t h) {
    require(h != 0, "Render session is closed");
    auto &session = *reinterpret_cast<RenderSessionOwner *>(h);
    require(session.thread == std::this_thread::get_id(),
                  "Render session must be used on its creating thread");
    return session;
}
std::unique_ptr<RenderSessionOwner> open_session(uint64_t stage, const char *renderer,
                                               int width, int height) {
    require(renderer != nullptr, "Renderer argument is required");
    require(width > 0 && height > 0 && width <= 8192 && height <= 8192 &&
                  int64_t(width) * height <= 16777216, "Render size exceeds the 16 megapixel limit");
    if (*renderer) {
        const auto plugins = UsdImagingGLEngine::GetRendererPlugins();
        require(std::find(plugins.begin(), plugins.end(), TfToken(renderer)) != plugins.end(),
                      "Requested renderer plugin is not installed", ErrorKind::NotFound);
    }
    auto result = std::make_unique<RenderSessionOwner>();
    result->stage = usdm_internal_stage(stage);
    result->width = width; result->height = height;
    require(Hgi::IsSupported(), "No supported platform Hgi device; the OpenGL backend requires a current OpenGL 4.5+ context", ErrorKind::Unsupported);
    result->hgi = Hgi::CreatePlatformDefaultHgi();
    require(bool(result->hgi), "Cannot create platform Hgi device", ErrorKind::Unsupported);
    UsdImagingGLEngine::Parameters config;
    config.driver = HdDriver{HgiTokens->renderDriver, VtValue(result->hgi.get())};
    config.rendererPluginId = TfToken(renderer);
    config.gpuEnabled = true;
    config.allowAsynchronousSceneProcessing = false;
    result->engine = std::make_unique<UsdImagingGLEngine>(config);
    result->engine->SetEnablePresentation(false);
    result->engine->SetRenderBufferSize(GfVec2i(width, height));
    result->engine->SetRenderViewport(GfVec4d(0, 0, width, height));
    require(result->engine->SetRendererAov(TfToken("color")), "Renderer has no color AOV", ErrorKind::Unsupported);
    return result;
}
void render_frame(RenderSessionOwner &session, const char *camera, double time,
                  int default_time, int iterations, int lighting) {
    session.has_frame = false;
    session.converged = false;
    require(camera && *camera, "Camera argument is required");
    require(iterations > 0 && iterations <= 256, "Render iteration limit must be 1..256");
    require((default_time == 0 || default_time == 1) &&
                  (default_time || std::isfinite(time)) && (lighting == 0 || lighting == 1),
                  "Invalid render time or flags");
    require(SdfPath::IsValidPathString(camera), "Invalid camera path");
    const SdfPath camera_path(camera);
    require(camera_path.IsAbsolutePath() && camera_path.IsPrimPath(), "Expected an absolute camera prim path");
    const auto camera_prim = session.stage->GetPrimAtPath(camera_path);
    require(bool(camera_prim), "Render camera does not exist", ErrorKind::NotFound);
    const auto cam = UsdGeomCamera(camera_prim);
    require(bool(cam), "Render prim is not a Camera", ErrorKind::TypeMismatch);
    const auto tc = default_time ? UsdTimeCode::Default() : UsdTimeCode(time);
    // Use the scene camera rather than duplicating its state in a free camera.
    // Hydra tracks time, transforms and clip-plane removal through USD notices.
    session.engine->SetCameraPath(cam.GetPath());
    session.engine->SetWindowPolicy(CameraUtilMatchVertically);
    UsdImagingGLRenderParams params;
    params.frame = tc;
    params.enableLighting = lighting != 0;
    params.enableSceneLights = lighting != 0;
    params.enableSceneMaterials = true;
    params.clearColor = GfVec4f(0, 0, 0, 0);
    params.colorCorrectionMode = TfToken("disabled");
    for (int i = 0; i < iterations; ++i) {
        session.engine->Render(session.stage->GetPseudoRoot(), params);
        if (session.engine->IsConverged()) break;
    }
    session.converged = session.engine->IsConverged();
    session.has_frame = true;
}
void read_pixels(RenderSessionOwner &session, float *output, int64_t count) {
    require(session.has_frame, "Render a frame before readback");
    const auto expected = int64_t(session.width) * session.height * 4;
    require(output && count == expected, "Image output extent mismatch");
    auto buffer = session.engine->GetAovRenderBuffer(TfToken("color"));
    require(buffer != nullptr, "Renderer did not expose its color buffer", ErrorKind::Sdk);
    require(buffer->GetWidth() == unsigned(session.width) &&
                  buffer->GetHeight() == unsigned(session.height), "Renderer returned a different image size", ErrorKind::InvalidData);
    const auto format = buffer->GetFormat();
    require(format == HdFormatFloat32Vec4 || format == HdFormatFloat16Vec4 ||
                  format == HdFormatUNorm8Vec4, "Unsupported renderer color format", ErrorKind::Unsupported);
    buffer->Resolve();
    const auto data = buffer->Map();
    struct Unmap { HdRenderBuffer *buffer; ~Unmap() { buffer->Unmap(); } } unmap{buffer};
    require(data != nullptr, "Cannot map renderer color buffer", ErrorKind::Sdk);
    const auto src = reinterpret_cast<uintptr_t>(data);
    const auto dst = reinterpret_cast<uintptr_t>(output);
    const auto source_bytes = uint64_t(count) * (format == HdFormatFloat32Vec4 ? 4 :
                                                format == HdFormatFloat16Vec4 ? 2 : 1);
    const auto output_bytes = uint64_t(count) * sizeof(float);
    require(dst >= src ? dst - src >= source_bytes : src - dst >= output_bytes,
                  "Image output aliases renderer storage");
    auto component = [&](int64_t i) {
        return format == HdFormatFloat32Vec4 ? static_cast<const float *>(data)[i] :
               format == HdFormatFloat16Vec4 ? float(static_cast<const GfHalf *>(data)[i]) :
               float(static_cast<const uint8_t *>(data)[i]) / 255.0f;
    };
    // Validate before touching caller memory, including a nonfinite component.
    for (int64_t i = 0; i < count; ++i)
        require(std::isfinite(component(i)), "Renderer returned a nonfinite color component", ErrorKind::InvalidData);
    for (int64_t i = 0; i < count; ++i) output[i] = component(i);
}
std::unique_ptr<ImageOwner> capture_image(RenderSessionOwner &session) {
    require(session.has_frame, "Render a frame before readback");
    auto result = std::make_unique<ImageOwner>();
    result->width = session.width; result->height = session.height;
    result->converged = session.converged;
    result->pixels.resize(size_t(session.width) * session.height * 4);
    read_pixels(session, result->pixels.data(), int64_t(result->pixels.size()));
    return result;
}
}
USDM_IMAGE_API int64_t usdm_image_error(char *buffer, int64_t size) noexcept {
    if (size < 0 || (size && !buffer)) return -1;
    auto n = int64_t(image_error.message.size());
    if (size) {
        if (size <= n) return -1;
        std::memcpy(buffer, image_error.message.c_str(), size_t(n + 1));
    }
    return n;
}
USDM_IMAGE_API int32_t usdm_image_error_kind() noexcept {
    return static_cast<int32_t>(image_error.kind);
}
USDM_IMAGE_API int64_t usdm_render_session_text(uint64_t h, int32_t field, char *out, int64_t size) noexcept {
    return image_protect([&] {
        require(size >= 0 && (!size || out) && (field == 0 || field == 1), "Invalid render metadata query");
        const auto &session = session_owner(h);
        const auto text = field == 0 ? session.hgi->GetAPIName().GetString()
                                    : session.engine->GetCurrentRendererId().GetString();
        const auto needed = int64_t(text.size()) + 1;
        if (size) {
            require(size >= needed, "Render metadata buffer is too small");
            std::memcpy(out, text.c_str(), size_t(needed));
        }
        return needed;
    }, int64_t(-1));
}
USDM_IMAGE_API uint64_t usdm_render_session_open(uint64_t stage, const char *renderer,
                                               int32_t width, int32_t height) noexcept {
    return image_owned([&] { return open_session(stage, renderer, width, height); });
}
USDM_IMAGE_API void usdm_render_session_close(uint64_t h) noexcept {
    delete reinterpret_cast<RenderSessionOwner *>(h);
}
USDM_IMAGE_API int32_t usdm_render_session_render(uint64_t h, const char *camera,
        double time, int32_t default_time, int32_t iterations, int32_t lighting) noexcept {
    RenderSessionOwner *attempted = nullptr;
    const auto result = image_protect([&] {
        attempted = &session_owner(h);
        render_frame(*attempted, camera, time, default_time, iterations, lighting);
        return int32_t(0);
    }, int32_t(-1));
    if (attempted) {
        if (result == 0) ++attempted->frame;
        else { attempted->has_frame = false; attempted->converged = false; }
    }
    return result;
}
USDM_IMAGE_API int32_t usdm_render_session_info(uint64_t h, uint64_t *info, int64_t count) noexcept {
    return image_protect([&] {
        require(info && count == 5, "Invalid render session metadata buffer");
        const auto &session = session_owner(h);
        info[0] = session.width; info[1] = session.height; info[2] = session.frame;
        info[3] = session.has_frame; info[4] = session.converged;
        return int32_t(0);
    }, int32_t(-1));
}
USDM_IMAGE_API uint64_t usdm_render_session_readback(uint64_t h) noexcept {
    return image_owned([&] { return capture_image(session_owner(h)); });
}
USDM_IMAGE_API int32_t usdm_render_session_read_into(uint64_t h, float *output, int64_t count) noexcept {
    return image_protect([&] {
        read_pixels(session_owner(h), output, count);
        return int32_t(0);
    }, int32_t(-1));
}
USDM_IMAGE_API uint64_t usdm_image_render(uint64_t stage_handle, const char *camera,
        const char *renderer, int32_t width, int32_t height, double time,
        int32_t default_time, int32_t iterations, int32_t lighting) noexcept {
    return image_owned([&] {
        auto session = open_session(stage_handle, renderer, width, height);
        render_frame(*session, camera, time, default_time, iterations, lighting);
        return capture_image(*session);
    });
}
USDM_IMAGE_API int32_t usdm_image_info(uint64_t handle, uint64_t *info, int64_t count) noexcept {
    return image_protect([&] {
        require(handle && info && count == 5, "Invalid image metadata buffer");
        auto &image = *reinterpret_cast<ImageOwner *>(handle);
        info[0] = image.width; info[1] = image.height; info[2] = image.converged;
        info[3] = image.pixels.size(); info[4] = reinterpret_cast<uint64_t>(image.pixels.data());
        return int32_t(0);
    }, int32_t(-1));
}
USDM_IMAGE_API void usdm_image_close(uint64_t handle) noexcept { delete reinterpret_cast<ImageOwner *>(handle); }
USDM_IMAGE_API int64_t usdm_image_plugins(char *buffer, int64_t size) noexcept {
    return image_protect([&] {
        require(size >= 0 && (!size || buffer), "Invalid plugin-list buffer");
        std::string names;
        for (const auto &plugin : UsdImagingGLEngine::GetRendererPlugins()) names += plugin.GetString() + "\n";
        if (size) {
            require(size > int64_t(names.size()), "Plugin-list buffer is too small");
            std::memcpy(buffer, names.c_str(), names.size() + 1);
        }
        return int64_t(names.size());
    }, int64_t(-1));
}
