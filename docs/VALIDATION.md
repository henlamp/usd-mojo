# Validation

Native macOS ARM64 and Linux x86-64 checks cover Mojo 1.1.0 and
1.2.0.dev2026100905. Prebuilt packages currently target macOS ARM64.

Checks cover SDK comparisons, malformed roots, lifetimes, relocated packages,
scene inventory and world-space OBJ export. The installed three-library consumer
compares 288 coordinates and 32 faces with OpenUSD.
Exact source identities, compiler versions and reports: [CI artifacts](https://github.com/henlamp/usd-mojo/actions/workflows/checks.yml).
