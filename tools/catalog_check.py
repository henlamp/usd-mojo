"""Compare registered SDK types, authored values and animation roundtrips."""

import ctypes
import json
import subprocess
from pathlib import Path
from pxr import Ar, Sdf, Usd, Tf
from build import BUILD, ROOT, build, require_compile
from evidence import source_hash
from generate import generate
from value_checks import samples


def native_catalog(bridge):
    lib = ctypes.CDLL(str(bridge))
    u = ctypes.c_uint64
    i = ctypes.c_int64
    declarations = [
        ("usdm_value_types", [], u),
        ("usdm_strings_count", [u], i),
        ("usdm_strings_text_size", [u, i], i),
        ("usdm_strings_text", [u, i, ctypes.c_void_p, i], i),
        ("usdm_strings_close", [u], None),
    ]
    for name, args, ret in declarations:
        f = getattr(lib, name)
        f.argtypes = args
        f.restype = ret
    handle = lib.usdm_value_types()
    assert handle
    try:
        fields = []
        for index in range(lib.usdm_strings_count(handle)):
            size = lib.usdm_strings_text_size(handle, index)
            assert size > 0
            data = ctypes.create_string_buffer(size)
            assert lib.usdm_strings_text(handle, index, data, size) == size
            fields.append(data.value.decode())
        assert len(fields) % 6 == 0
        return [fields[i : i + 6] for i in range(0, len(fields), 6)]
    finally:
        lib.usdm_strings_close(handle)


def check(directory, compiler, imports, bridge):
    generate(check=True)
    work = directory / "catalog"
    work.mkdir()
    rows = native_catalog(bridge)
    fixture = work / "types.usda"
    output = work / "roundtrip.usdc"
    ascii_output = work / "roundtrip.usda"
    package_output = work / "roundtrip.usdz"
    (work / "relative.asset").write_text("catalog asset dependency\n")
    stage = Usd.Stage.CreateNew(str(fixture))
    p = stage.DefinePrim("/Types")
    assert len({r[0] for r in rows}) == len(rows)
    catalog = []
    seeds = {
        Sdf.ValueTypeNames.Find(name).type: value for name, value in samples().items()
    }
    seeds.update(
        {
            Sdf.ValueTypeNames.Half.type: 65504.0,
            Sdf.ValueTypeNames.Float.type: 16777216.0,
            Sdf.ValueTypeNames.Double.type: 1.7976931348623157e308,
        }
    )
    for index, (name, cpp, role, array, supported, view) in enumerate(rows):
        t = Sdf.ValueTypeNames.Find(name)
        assert (
            t
            and t.scalarType.type.typeName == cpp
            and t.role == role
            and t.isArray == bool(int(array))
        ), name
        assert bool(int(supported)) == (cpp != "SdfOpaqueValue"), (
            name,
            cpp,
            "unhandled SDK type",
        )
        if supported == "1":
            attr = p.CreateAttribute("v" + str(index), t)
            attr.Set(t.defaultValue)
            scalar = t.scalarType
            seed = seeds[scalar.type]
            first = [seed, scalar.defaultValue, seed] if t.isArray else seed
            second = (
                [scalar.defaultValue, seed, scalar.defaultValue]
                if t.isArray
                else scalar.defaultValue
            )
            attr.Set(first, 1)
            attr.Set(second, 3)
            last = {
                Sdf.ValueTypeNames.Int.type: 2**31 - 1,
                Sdf.ValueTypeNames.Int64.type: 2**63 - 1,
            }.get(scalar.type, scalar.defaultValue)
            attr.Set([last] * 3 if t.isArray else last, 5)
        catalog.append(
            {
                "name": name,
                "cpp": cpp,
                "role": role,
                "array": bool(int(array)),
                "value_roundtrip": bool(int(supported)),
                "native_view": bool(int(view)),
            }
        )
    known = {
        str(getattr(Sdf.ValueTypeNames, n))
        for n in dir(Sdf.ValueTypeNames)
        if isinstance(getattr(Sdf.ValueTypeNames, n), Sdf.ValueTypeName)
    }
    assert known <= {r[0] for r in rows}
    stage.GetRootLayer().Save()
    binary = work / "catalog"
    compiler(ROOT / "tests/catalog.mojo", binary, imports)
    raw = subprocess.check_output(
        [
            str(binary),
            str(fixture),
            str(output),
            str(ascii_output),
            str(package_output),
        ],
        text=True,
    )
    emitted = [
        line.split("\t")[1:] for line in raw.splitlines() if line.startswith("TYPE\t")
    ]
    expected = [
        [name, cpp, role or "-", array, supported, view]
        for name, cpp, role, array, supported, view in rows
    ]
    assert len(emitted) == len(expected)
    for actual, wanted in zip(emitted, expected, strict=True):
        assert actual == wanted, (actual, wanted)
    registry = Usd.SchemaRegistry()
    schemas = {}
    for line in raw.splitlines():
        fields = line.split("\t")
        if fields[0] == "SCHEMA":
            schemas[fields[1]] = {"kind": fields[2], "properties": []}
        if fields[0] == "PROPERTY":
            schemas[fields[1]]["properties"].append(fields[2])
    expected_schemas = {
        str(registry.GetSchemaTypeName(t))
        for t in Tf.Type.Find(Usd.SchemaBase).GetAllDerivedTypes()
    } - {""}
    assert set(schemas) == expected_schemas
    for name, row in schemas.items():
        definition = None
        for kind, method in [
            ("typed", "FindConcretePrimDefinition"),
            ("api", "FindAppliedAPIPrimDefinition"),
            ("abstract", "FindAbstractPrimDefinition"),
        ]:
            definition = getattr(registry, method)(name)
            if definition:
                assert row["kind"] == kind and row["properties"] == list(
                    definition.GetPropertyNames()
                )
                break
        if not definition:
            assert row == {"kind": "unapplied", "properties": []}
    comparisons = 0

    def asset_contents(value):
        if isinstance(value, Sdf.AssetPath):
            if not value.path:
                return None
            assert value.resolvedPath, value
            asset = Ar.GetResolver().OpenAsset(Ar.ResolvedPath(value.resolvedPath))
            assert asset, value
            return bytes(asset.GetBuffer())
        return [asset_contents(item) for item in value]

    for filename in (output, ascii_output, package_output):
        after = Usd.Stage.Open(str(filename))
        for a in p.GetAuthoredAttributes():
            b = after.GetPrimAtPath("/Types").GetAttribute(a.GetName())
            assert b.GetTypeName() == a.GetTypeName(), a.GetName()

            def equivalent(actual, expected):
                if (
                    a.GetTypeName().scalarType.type == Sdf.ValueTypeNames.Asset.type
                    and filename != output
                ):
                    return asset_contents(actual) == asset_contents(expected)
                return actual == expected

            assert equivalent(b.Get(), a.Get(1)), (filename, a.GetName())
            assert b.GetTimeSamples() == [1, 3, 5], a.GetName()
            for time in (0, 1, 1.5, 2, 2.5, 3, 4, 4.5, 5, 6):
                assert equivalent(b.Get(time), a.Get(time)), (
                    filename,
                    a.GetName(),
                    time,
                    b.Get(time),
                    a.Get(time),
                )
                comparisons += 1
    return {
        "status": "passed",
        "registered_types": len(rows),
        "concrete_types_roundtripped": sum(r["value_roundtrip"] for r in catalog),
        "non_default_and_animated_types": sum(r["value_roundtrip"] for r in catalog),
        "persisted_sample_comparisons": comparisons,
        "formats": ["usda", "usdc", "usdz"],
        "schema_definitions": schemas,
        "non_value_markers": [r["name"] for r in catalog if not r["value_roundtrip"]],
        "types": catalog,
    }


if __name__ == "__main__":
    import tempfile

    BUILD.mkdir(parents=True, exist_ok=True)
    library = build()
    work = Path(tempfile.mkdtemp(prefix="catalog-", dir=BUILD))
    report = check(work, require_compile, ROOT / "src", library)
    report["source_sha256"] = source_hash(ROOT)
    (BUILD / "catalog.json").write_text(json.dumps(report, indent=2) + "\n")
    print(report["registered_types"], "registered types checked")
