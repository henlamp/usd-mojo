# usd-mojo compiled package

This archive contains a compiler/platform-specific Mojo module and the native
OpenUSD bridge. It is consumed by another Mojo project; it has no physics engine
or renderer dependency.

Activate the matching Mojo/OpenUSD environment, unpack the package as
`vendor/usd-mojo`, and compile a program in your project:

```sh
python vendor/usd-mojo/compile.py consumer.mojo -o bin/consumer
./bin/consumer scene.usda
```

To provision dependencies, use the pinned Pixi environment from the
[usd-mojo repository](https://github.com/henlamp/usd-mojo). This archive does not
bundle OpenUSD or the compiler. Their exact versions and the platform are in
`manifest.json`. A custom SDK prefix can be passed with `--sdk-prefix` or
`USD_MOJO_SDK_PREFIX`; otherwise the active Python environment supplies it.
The current SDK also requires its matching CPython shared library.

The helper rejects compiler/platform/SDK mismatches and modified components.
Executables and packages can relocate together; the matching external SDK must
remain available. See [API](docs/API.md), [validation](docs/VALIDATION.md) and
[benchmarks](docs/BENCHMARKS.md) for supported operations and limits. The full
source checkout's development commands are not included in this compiled archive.

Original library/bridge code: [MIT](LICENSE). External dependencies retain their
own terms and attribution: [third-party notices](THIRD_PARTY_NOTICES.md),
[OpenUSD license](licenses/OpenUSD-LICENSE.txt) and
[OpenUSD notices](licenses/OpenUSD-NOTICE.txt).
