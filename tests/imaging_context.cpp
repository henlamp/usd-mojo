// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
// Test-process context only. Applications supply their own OpenGL context.
#include <pxr/pxr.h>
#include <pxr/imaging/glf/testGLContext.h>
#include <pxr/imaging/glf/glContext.h>
#include <pxr/imaging/garch/glApi.h>
#include <cstdio>
#include <cstdlib>

PXR_NAMESPACE_USING_DIRECTIVE

__attribute__((constructor)) static void test_context() {
    if (!std::getenv("USD_MOJO_TEST_GL_CONTEXT")) return;
    // Driver helper subprocesses must not create another test context.
    unsetenv("LD_PRELOAD");
    GlfTestGLContext::RegisterGLContextCallbacks();
    static auto context = GlfGLContext::GetSharedGLContext();
    if (!context || !context->IsValid()) std::abort();
    GlfGLContext::MakeCurrent(context);
    GarchGLApiLoad();
    const auto renderer = glGetString(GL_RENDERER);
    const auto version = glGetString(GL_VERSION);
    if (!renderer || !version) std::abort();
    std::fprintf(stderr, "GPU_RENDERER %s\nGPU_VERSION %s\n", renderer, version);
}
