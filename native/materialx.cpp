// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
#include "error_bridge.h"
#include <MaterialXCore/Document.h>
#include <MaterialXFormat/XmlIo.h>
#include <MaterialXFormat/Util.h>
#include <MaterialXGenShader/Util.h>
#include <MaterialXGenShader/GenContext.h>
#include <MaterialXGenGlsl/GlslShaderGenerator.h>
#include <MaterialXGenMsl/MslShaderGenerator.h>
#ifdef __APPLE__
#include <MaterialXRenderMsl/MslRenderer.h>
#include <MaterialXRender/StbImageLoader.h>
#include <pthread.h>
#endif
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
namespace mx = MaterialX;
#define USDM_MX_API extern "C" __attribute__((visibility("default")))
namespace {
using usd_mojo_native::ErrorKind;
using usd_mojo_native::BridgeError;
using usd_mojo_native::require;
thread_local usd_mojo_native::ErrorState mx_error;
template <class F, class T> T mx_protect(F &&f, T failure) noexcept {
    return mx_error.protect([&]() {
        try { return f(); }
        catch (const mx::ExceptionFileMissing &error) { throw BridgeError(ErrorKind::Io, error.what()); }
        catch (const mx::ExceptionParseError &error) { throw BridgeError(ErrorKind::InvalidData, error.what()); }
        catch (const mx::ExceptionTypeError &error) { throw BridgeError(ErrorKind::TypeMismatch, error.what()); }
    }, std::move(failure));
}
template <class F> uint64_t mx_owned(F &&f) noexcept {
    auto owner = mx_protect(std::forward<F>(f), decltype(f()){});
    return reinterpret_cast<uint64_t>(owner.release());
}
struct MxDocument {
    mx::DocumentPtr value;
    mx::FileSearchPath search;
};
struct MxShader {
    mx::ShaderPtr value;
    mx::FileSearchPath search;
    std::string target;
    bool requires_shading = false;
};
struct MxStrings {
    std::vector<std::string> values;
};
struct MxImage {
    int width, height;
    std::vector<float> pixels;
};
template <class T> T &mx_owner(uint64_t h) {
    require(h != 0, "MaterialX owner is closed");
    return *reinterpret_cast<T *>(h);
}
mx::ShaderPtr mx_shader(const MxDocument &d, const char *path, const char *target) {
    require(path && *path && target, "Missing shader path/target");
    mx::ShaderGeneratorPtr generator;
    if (std::string(target) == "msl")
        generator = mx::MslShaderGenerator::create();
    else {
        require(std::string(target) == "glsl", "Shader target must be glsl or msl");
        generator = mx::GlslShaderGenerator::create();
    }
    std::string why;
    require(d.value->validate(&why), why, ErrorKind::InvalidData);
    auto element = d.value->getDescendant(path);
    require(bool(element), "MaterialX shader element does not exist", ErrorKind::NotFound);
    mx::GenContext context(generator);
    context.registerSourceCodeSearchPath(d.search);
    auto shader = generator->generate("usd_mojo_material", element, context);
    require(bool(shader), "Cannot generate MaterialX shader", ErrorKind::Sdk);
    return shader;
}
} // namespace
USDM_MX_API int64_t usdm_mx_error(char *out, int64_t size) noexcept {
    if (size < 0 || (size && !out))
        return -1;
    auto needed = int64_t(mx_error.message.size()) + 1;
    if (size) {
        if (size < needed)
            return -1;
        std::memcpy(out, mx_error.message.c_str(), size_t(needed));
    }
    return needed;
}
USDM_MX_API int32_t usdm_mx_error_kind() noexcept {
    return static_cast<int32_t>(mx_error.kind);
}
USDM_MX_API uint64_t usdm_mx_open(const char *filename,
                                  const char *libraries) noexcept {
    return mx_owned([&] {
        require(filename && *filename && libraries && *libraries,
                   "Document and library search paths are required");
        auto result = std::make_unique<MxDocument>();
        result->search = mx::FileSearchPath(libraries);
        result->search.append(mx::FilePath(filename).getParentPath());
        auto library = mx::createDocument();
        auto loaded = mx::loadLibraries({"libraries"}, result->search, library);
        require(!loaded.empty(), "No MaterialX standard libraries found", ErrorKind::NotFound);
        result->value = mx::createDocument();
        mx::readFromXmlFile(result->value, filename, result->search);
        result->value->setDataLibrary(library);
        return result;
    });
}
USDM_MX_API void usdm_mx_close(uint64_t h) noexcept {
    delete reinterpret_cast<MxDocument *>(h);
}
USDM_MX_API uint64_t usdm_mx_query(uint64_t h, int32_t kind) noexcept {
    return mx_owned([&] {
        const auto &d = mx_owner<MxDocument>(h);
        auto result = std::make_unique<MxStrings>();
        if (kind == 0) {
            std::string why;
            if (!d.value->validate(&why))
                result->values.push_back(why);
        } else if (kind == 1)
            for (const auto &element : mx::findRenderableElements(d.value))
                result->values.push_back(element->getNamePath());
        else if (kind == 2)
            result->values.push_back(mx::writeToXmlString(d.value));
        else {
            require(kind == 3, "Invalid MaterialX query");
            for (auto element : d.value->traverseTree())
                if (element->isA<mx::Node>())
                    result->values.push_back(element->getNamePath());
        }
        return result;
    });
}
USDM_MX_API int32_t usdm_mx_set_input(uint64_t h, const char *node, const char *name,
                                      const char *type, const char *value) noexcept {
    return mx_protect(
        [&] {
            require(node && name && *name && type && *type && value,
                       "Invalid MaterialX input");
            auto &d = mx_owner<MxDocument>(h);
            auto copy = d.value->copy();
            auto element = copy->getDescendant(node);
            auto target = element ? element->asA<mx::Node>() : nullptr;
            require(bool(target), "MaterialX node does not exist", ErrorKind::NotFound);
            auto definition = target->getNodeDef();
            require(bool(definition), "MaterialX node definition is unresolved", ErrorKind::NotFound);
            auto declared = definition->getActiveInput(name);
            require(declared && declared->getType() == type,
                       "MaterialX input type differs from its node definition", ErrorKind::TypeMismatch);
            require(bool(mx::Value::createValueFromStrings(value, type)),
                       "Invalid MaterialX typed value");
            auto input = target->getInput(name);
            if (!input)
                input = target->addInput(name, type);
            require(input->getType() == type,
                       "Existing MaterialX input has a different type", ErrorKind::TypeMismatch);
            for (const char *key : {"nodename", "nodegraph", "output", "interfacename"})
                input->removeAttribute(key);
            input->setValueString(value);
            std::string why;
            require(copy->validate(&why), why, ErrorKind::InvalidData);
            d.value = std::move(copy);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_MX_API int32_t usdm_mx_save(uint64_t h, const char *filename) noexcept {
    return mx_protect(
        [&] {
            require(filename && *filename, "Missing MaterialX filename");
            const auto &document = mx_owner<MxDocument>(h).value;
            std::ofstream output(filename);
            require(bool(output), "Cannot open MaterialX output file", ErrorKind::Io);
            mx::writeToXmlStream(document, output);
            output.close();
            require(bool(output), "Cannot write MaterialX output file", ErrorKind::Io);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_MX_API uint64_t usdm_mx_shader(uint64_t h, const char *path,
                                    const char *target) noexcept {
    return mx_owned([&] {
        const auto &d = mx_owner<MxDocument>(h);
        auto result = std::make_unique<MxShader>();
        result->value = mx_shader(d, path, target);
        result->search = d.search;
        result->target = target;
        auto element = d.value->getDescendant(path)->asA<mx::TypedElement>();
        require(bool(element), "MaterialX shader element has no value type", ErrorKind::TypeMismatch);
        result->requires_shading = mx::elementRequiresShading(element);
        return result;
    });
}
USDM_MX_API void usdm_mx_shader_close(uint64_t h) noexcept {
    delete reinterpret_cast<MxShader *>(h);
}
USDM_MX_API uint64_t usdm_mx_shader_source(uint64_t h, const char *stage) noexcept {
    return mx_owned([&] {
        require(
            stage && (std::string(stage) == "vertex" || std::string(stage) == "pixel"),
            "Shader stage must be vertex or pixel");
        auto result = std::make_unique<MxStrings>();
        result->values.push_back(
            mx_owner<MxShader>(h).value->getStage(stage).getSourceCode());
        return result;
    });
}
USDM_MX_API uint64_t usdm_mx_render(uint64_t h, int32_t width,
                                    int32_t height) noexcept {
    return mx_owned([&] {
        require(width > 0 && height > 0 && width <= 8192 && height <= 8192 &&
                       int64_t(width) * height <= 16777216,
                   "Image exceeds 16 megapixels");
        const auto &s = mx_owner<MxShader>(h);
        require(!s.requires_shading,
                   "Texture-space readback requires a value output; surface materials "
                   "use the MaterialX-enabled Hydra path", ErrorKind::Unsupported);
#ifdef __APPLE__
        require(pthread_main_np(), "Metal rendering requires the main thread");
        require(s.target == "msl", "Metal rendering requires an MSL shader", ErrorKind::Unsupported);
        @autoreleasepool {
            auto renderer =
                mx::MslRenderer::create(width, height, mx::Image::BaseType::FLOAT);
            renderer->initialize();
            renderer->getCamera()->setWorldMatrix(mx::Matrix44::IDENTITY);
            renderer->getCamera()->setViewMatrix(mx::Matrix44::IDENTITY);
            renderer->getCamera()->setProjectionMatrix(mx::Matrix44::IDENTITY);
            renderer->getFramebuffer()->setEncodeSrgb(false);
            auto handler = renderer->createImageHandler(mx::StbImageLoader::create());
            handler->setSearchPath(s.search);
            renderer->setImageHandler(handler);
            renderer->createProgram(s.value);
            renderer->validateInputs();
            renderer->renderTextureSpace(mx::Vector2(0), mx::Vector2(1));
            auto image = renderer->captureImage();
            require(bool(image), "Cannot capture MaterialX image", ErrorKind::Sdk);
            auto result = std::make_unique<MxImage>();
            result->width = width;
            result->height = height;
            result->pixels.reserve(size_t(width) * height * 4);
            for (int y = 0; y < height; ++y)
                for (int x = 0; x < width; ++x) {
                    auto color = image->getTexelColor(x, y);
                    for (int c = 0; c < 4; ++c) {
                        require(std::isfinite(color[c]),
                                   "Nonfinite MaterialX pixel", ErrorKind::InvalidData);
                        result->pixels.push_back(color[c]);
                    }
                }
            return result;
        }
#else
        (void)s;
        throw BridgeError(ErrorKind::Unsupported, "Texture-space MaterialX rendering requires Metal; use Hydra for GLSL surfaces");
        return std::unique_ptr<MxImage>();
#endif
    });
}
USDM_MX_API void usdm_mx_image_close(uint64_t h) noexcept {
    delete reinterpret_cast<MxImage *>(h);
}
USDM_MX_API int32_t usdm_mx_image_info(uint64_t h, uint64_t *out,
                                       int64_t count) noexcept {
    return mx_protect(
        [&] {
            require(out && count == 4, "Image metadata extent mismatch");
            const auto &i = mx_owner<MxImage>(h);
            out[0] = i.width;
            out[1] = i.height;
            out[2] = i.pixels.size();
            out[3] = reinterpret_cast<uint64_t>(i.pixels.data());
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_MX_API int64_t usdm_mx_result_count(uint64_t h) noexcept {
    return mx_protect([&] { return int64_t(mx_owner<MxStrings>(h).values.size()); },
                      int64_t(-1));
}
USDM_MX_API int64_t usdm_mx_result_text(uint64_t h, int64_t index, char *out,
                                        int64_t size) noexcept {
    return mx_protect(
        [&] {
            const auto &v = mx_owner<MxStrings>(h).values;
            require(index >= 0 && uint64_t(index) < v.size() && size >= 0 &&
                           (!size || out),
                       "Invalid MaterialX text buffer");
            const auto &text = v[size_t(index)];
            require(text.find('\0') == std::string::npos, "NUL in MaterialX text");
            auto needed = int64_t(text.size()) + 1;
            if (size) {
                require(size >= needed, "MaterialX text buffer too small");
                std::memcpy(out, text.c_str(), size_t(needed));
            }
            return needed;
        },
        int64_t(-1));
}
USDM_MX_API void usdm_mx_result_close(uint64_t h) noexcept {
    delete reinterpret_cast<MxStrings *>(h);
}
