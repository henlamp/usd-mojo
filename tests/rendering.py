"""Reject misleading render identities and keep custom SDKs out of the oracle."""
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from render_support import render_metadata, renderer_environment


class RenderingIdentity(unittest.TestCase):
    def test_actual_api_overrides_host_platform(self):
        result = render_metadata(
            "RENDER_BACKEND OpenGL\nRENDERER_PLUGIN HdStormRendererPlugin\n"
            "GPU_RENDERER NVIDIA test\nGPU_VERSION 4.6 test\n"
        )
        self.assertEqual(result["hgi_api"], "OpenGL")
        self.assertEqual(result["gpu_renderer"], "NVIDIA test")

    def test_no_platform_guess_when_identity_is_missing(self):
        for output in ("", "RENDER_BACKEND Metal\n", "RENDER_BACKEND \nRENDERER_PLUGIN storm\n"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                render_metadata(output)

    def test_reject_mixed_source_and_installed_backends(self):
        with self.assertRaises(ValueError):
            render_metadata(
                "RENDER_BACKEND Metal\nRENDER_BACKEND OpenGL\n"
                "RENDERER_PLUGIN storm\n"
            )

    def test_native_environment_is_separate_and_respects_explicit_values(self):
        with patch.dict(os.environ, {"USD_MOJO_SDK_PREFIX": "/old-sdk"}, clear=True):
            before = os.environ.copy()
            env = renderer_environment({
                "USD_MOJO_SDK_PREFIX": "/selected-sdk",
                "PXR_PLUGINPATH_NAME": "/custom-plugin",
            })
            self.assertEqual(os.environ, before)
        variable = "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
        self.assertEqual(env[variable].split(":")[0], "/selected-sdk/lib")
        self.assertEqual(env["PXR_PLUGINPATH_NAME"], "/selected-sdk/lib/usd:/custom-plugin")


if __name__ == "__main__":
    unittest.main()
