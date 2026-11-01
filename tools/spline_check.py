"""SDK/analytic spline comparisons, authored roundtrips and retained owners."""

import json, math, subprocess, tempfile
from pathlib import Path
from pxr import Ts, Usd, Sdf
from build import BUILD, ROOT, build, require_compile
from evidence import source_hash


def check(directory, compiler, imports):
    work = directory / "splines"
    work.mkdir()
    fixture = work / "input.usda"
    stage = Usd.Stage.CreateNew(str(fixture))
    p = stage.DefinePrim("/Animation")
    modes = {
        "value": "Eval",
        "pre_value": "EvalPreValue",
        "derivative": "EvalDerivative",
        "held": "EvalHeld",
    }
    for kind in ("double", "float", "half", "timecode"):
        s = Ts.Spline(kind)
        for time, value in ((0, 0), (1, 2), (2, 1)):
            k = Ts.Knot(kind)
            k.SetTime(time)
            k.SetValue(value)
            k.SetNextInterpolation(Ts.InterpCurve)
            k.SetPreTanSlope(0.5)
            k.SetPostTanSlope(0.5)
            k.SetPreTanWidth(0.2)
            k.SetPostTanWidth(0.2)
            s.SetKnot(k)
        p.CreateAttribute("curve_" + kind, Sdf.ValueTypeNames.Find(kind)).SetSpline(s)
    stage.GetRootLayer().Save()
    binary = work / "splines"
    out = work / "output.usda"
    flat = work / "output.usdc"
    compiler(ROOT / "tests/splines.mojo", binary, imports)
    raw = subprocess.check_output(
        [str(binary), str(fixture), str(out), str(flat)], text=True
    )
    count = 0
    for line in raw.splitlines():
        if not line.startswith("SAMPLE "):
            continue
        _, kind, time, mode, value = line.split()
        s = p.GetAttribute("curve_" + kind).GetSpline()
        expected = float(getattr(s, modes[mode])(float(time)))
        assert math.isclose(float(value), expected, rel_tol=2e-6, abs_tol=2e-6), (
            line,
            expected,
        )
        count += 1
    assert count == 4 * 33 * 4
    for filename in (out, flat):
        # SDK prims borrow their stage.
        result = Usd.Stage.Open(str(filename))
        q = result.GetPrimAtPath("/Animation")
        for kind in ("double", "float", "half", "timecode"):
            a = q.GetAttribute("curve_" + kind)
            assert (
                a.HasSpline()
                and a.GetSpline() == p.GetAttribute("curve_" + kind).GetSpline()
            )
            edited = q.GetAttribute("authored_" + kind).GetSpline()
            assert edited.GetKnot(0).GetCustomDataByKey("label") == "retained"
    return {
        "status": "passed",
        "sdk_samples": count,
        "typed_roundtrips": ["double", "float", "half", "timecode"],
        "hermite_analytic": True,
        "source_sha256": source_hash(ROOT),
    }


if __name__ == "__main__":
    build()
    work = Path(tempfile.mkdtemp(prefix="splines-", dir=BUILD))
    report = check(work, require_compile, ROOT / "src")
    (BUILD / "splines.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
