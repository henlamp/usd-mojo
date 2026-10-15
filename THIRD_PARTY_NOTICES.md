# Third-party dependencies

The Mojo API and the C ABI bridge in this repository are original work by
henlamp, licensed under MIT. No OpenUSD implementation sources are vendored.

The bridge dynamically links the official **OpenUSD 26.08** SDK:
https://github.com/PixarAnimationStudios/OpenUSD/tree/v26.08
OpenUSD is distributed under the Tomorrow Open Source Technology License 1.0;
the SDK also includes third-party components with their own notices.
Unmodified upstream license and notices are retained under `licenses/` and
in compiled packages, including notices relevant to SDK headers. See the upstream
`LICENSE.txt` and `NOTICE.txt`. Distributors bundling that
SDK must retain its license and dependency notices.

Mojo 1.1.0, Mojo 1.2.0.dev2026100905 and the development environment have their own dependency terms.
The Mojo API performs no Python calls. The selected SDK requires its matching
CPython shared library at runtime. Python also runs build tools and independent
verification through the SDK reference API. SDK/compiler binaries are external
dependencies, not included in the compiled library archives.
