# Validation

Native macOS ARM64 and Linux x86-64 checks cover Mojo 1.1.0 and
1.2.0.dev2026100905. Development 0.2.0 packages pass fresh Pixi installation
on macOS ARM64 and Linux x86-64 with Mojo 1.1.0. The final Linux package check
ran on Ubuntu 22.04 under WSL2 (glibc 2.35). Its bridge symbol requirements fit
the declared glibc 2.28 floor; execution on glibc 2.28 was not tested.

Checks cover SDK comparisons, malformed roots, lifetimes, relocated packages,
scene inventory and world-space OBJ export. Linux package checks also compare
the bridge's glibc symbol requirements with the package's declared ABI floor.
Source and package hashes for the corrected Linux build: [Linux package record](evidence/020-linux.json).
Earlier source/SDK checks: [CI artifacts](https://github.com/henlamp/usd-mojo/actions/workflows/checks.yml).
