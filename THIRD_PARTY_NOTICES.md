# Third-party dependencies

The Mojo API and the C ABI bridge in this repository are original work by
henlamp, licensed under MIT. The two headers in `native/openusd/` come from
OpenUSD 26.08 (`pxr/usd/usdUtils`); their original copyright and OpenUSD terms
are retained. One include path is adjusted; trailing whitespace is normalized.
They expose the pinned SDK package writer so empty asset-array slots survive
localization; SDK implementations remain dynamically linked. An SDK version
change requires reviewing these declarations.

The bridge dynamically links the official **OpenUSD 26.08** SDK:
https://github.com/PixarAnimationStudios/OpenUSD/tree/v26.08
OpenUSD is distributed under the Tomorrow Open Source Technology License 1.0;
the SDK also includes third-party components with their own notices.
Unmodified upstream license and notices are retained under `licenses/` and
in compiled packages, including notices relevant to SDK headers. See the upstream
`LICENSE.txt` and `NOTICE.txt`. Distributors bundling that
SDK must retain its license and dependency notices.

Mojo 1.2.0, Mojo 1.2.0.dev2026100905 and the development environment have their own dependency terms.
The Mojo API performs no Python calls. The Conda SDK requires its matching
CPython shared library at runtime. Python also runs build tools and independent
verification through the SDK reference API. SDK/compiler binaries are external
dependencies, not included in the compiled library archives.

The optional MaterialX adapter links **MaterialX 1.39.5** dynamically:
https://github.com/AcademySoftwareFoundation/MaterialX/tree/v1.39.5
MaterialX is Apache-2.0; its unmodified license is in
`licenses/MaterialX-LICENSE.txt`. SDK binaries and standard libraries remain
external. The bootstrap tool verifies upstream source archive checksums.

The optional OpenUSD bootstrap applies the version-bound MaterialX-unlit patch
in `tools/patches/`. That patch modifies OpenUSD code under the OpenUSD license;
its original license and notices remain applicable. Archive, patch and patched
file checksums are recorded in `tools/optional_sdks.json` and the SDK identity.
