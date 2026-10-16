# Validation

Native macOS ARM64 and Linux x86-64 checks cover Mojo 1.1.0 and
1.2.0.dev2026100905. Development 0.2.0 packages pass the macOS ARM64 fresh-install
check. The Linux x86-64 package targets glibc 2.28; its final fresh-install gate is pending.

Checks cover SDK comparisons, malformed roots, lifetimes, relocated packages,
scene inventory and world-space OBJ export. Linux package checks also compare
the bridge's glibc symbol requirements with the package's declared ABI floor.
Exact source identities, compiler versions and reports: [CI artifacts](https://github.com/henlamp/usd-mojo/actions/workflows/checks.yml).
