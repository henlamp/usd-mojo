// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
#include <pxr/base/ts/spline.h>
#include <pxr/base/ts/knot.h>

namespace {
struct SplineOwner {
    TsSpline value;
    std::string type;
};
SplineOwner &spline_owner(uint64_t h) {
    require(h != 0, "Spline is closed");
    return *reinterpret_cast<SplineOwner *>(h);
}
VtValue spline_number(const SplineOwner &s, double x) {
    require(std::isfinite(x), "Spline components must be finite");
    if (s.type == "double")
        return VtValue(x);
    if (s.type == "float")
        return VtValue(checked_number<float>(x));
    if (s.type == "half")
        return VtValue(checked_number<GfHalf>(x));
    return VtValue(GfTimeCode(x));
}
double spline_number(const VtValue &v) {
    if (v.IsHolding<double>())
        return v.UncheckedGet<double>();
    if (v.IsHolding<float>())
        return v.UncheckedGet<float>();
    if (v.IsHolding<GfHalf>())
        return double(v.UncheckedGet<GfHalf>());
    require(v.IsHolding<GfTimeCode>(), "Invalid spline value", ErrorKind::Internal);
    return v.UncheckedGet<GfTimeCode>().GetValue();
}
TsKnot spline_knot(const SplineOwner &s, double time) {
    require(std::isfinite(time), "Spline time must be finite");
    TsKnot knot(s.value.GetValueType());
    require(s.value.GetKnot(time, &knot), "Spline knot does not exist",
            ErrorKind::NotFound);
    return knot;
}
} // namespace
USDM_API uint64_t usdm_spline_new(const char *type, int32_t curve) noexcept {
    return protect_owned([&] {
        require(type && (curve == 0 || curve == 1), "Invalid spline type/curve");
        auto t = SdfSchema::GetInstance().FindType(TfToken(type));
        require(t && !t.IsArray() && TsSpline::IsSupportedValueType(t.GetType()),
                "Unsupported spline value type", ErrorKind::Unsupported);
        auto s = std::make_unique<SplineOwner>();
        s->type = type;
        s->value = TsSpline(t.GetType());
        s->value.SetCurveType(TsCurveType(curve));
        return s;
    });
}
USDM_API uint64_t usdm_spline_read(uint64_t h, const char *path,
                                   const char *name) noexcept {
    return protect_owned([&] {
        auto a = attribute(h, path, name);
        require(a.HasSpline(), "Attribute has no resolved spline", ErrorKind::NotFound);
        auto s = std::make_unique<SplineOwner>();
        s->type = a.GetTypeName().GetAsToken().GetString();
        s->value = a.GetSpline();
        return s;
    });
}
USDM_API uint64_t usdm_spline_copy(uint64_t h) noexcept {
    return protect_owned(
        [&] { return std::make_unique<SplineOwner>(spline_owner(h)); });
}
USDM_API void usdm_spline_close(uint64_t h) noexcept {
    delete reinterpret_cast<SplineOwner *>(h);
}
USDM_API uint64_t usdm_spline_info(uint64_t h) noexcept {
    return protect_owned([&] {
        const auto &s = spline_owner(h);
        auto info = std::make_unique<StringsOwner>();
        info->values = {
            s.type, s.value.GetCurveType() == TsCurveTypeBezier ? "bezier" : "hermite"};
        return info;
    });
}
USDM_API int32_t usdm_spline_set_knot(uint64_t h, const double *data, int64_t size,
                                      const int32_t *modes,
                                      int64_t mode_count) noexcept {
    return protect(
        [&] {
            require(data && size == 8 && modes && mode_count == 3,
                    "Spline knot extent mismatch");
            for (int i = 0; i < 8; ++i)
                require(std::isfinite(data[i]), "Spline knot must be finite");
            require(data[7] == 0 || data[7] == 1, "Invalid dual-value flag");
            require(data[5] >= 0 && data[6] >= 0, "Negative tangent width");
            require(modes[0] >= 0 && modes[0] <= 3 && modes[1] >= 0 && modes[1] <= 2 &&
                        modes[2] >= 0 && modes[2] <= 2,
                    "Invalid knot mode");
            auto &s = spline_owner(h);
            TsKnot knot(s.value.GetValueType());
            // Preserve opaque knot metadata when replacing an existing knot.
            auto previous = s.value.GetKnots();
            auto found = previous.find(data[0]);
            if (found != previous.end())
                knot = *found;
            require(knot.SetTime(data[0]) && knot.SetValue(spline_number(s, data[1])),
                    "Invalid knot value");
            if (data[7])
                require(knot.SetPreValue(spline_number(s, data[2])),
                        "Invalid pre-value");
            else
                require(knot.ClearPreValue(), "Cannot clear dual value");
            require(knot.SetNextInterpolation(TsInterpMode(modes[0])),
                    "Invalid knot interpolation");
            require(knot.SetPreTanSlope(spline_number(s, data[3])) &&
                        knot.SetPostTanSlope(spline_number(s, data[4])),
                    "Invalid tangent slope");
            if (s.value.GetCurveType() == TsCurveTypeBezier)
                require(knot.SetPreTanWidth(data[5]) && knot.SetPostTanWidth(data[6]),
                        "Invalid tangent width");
            require(knot.SetPreTanAlgorithm(TsTangentAlgorithm(modes[1])) &&
                        knot.SetPostTanAlgorithm(TsTangentAlgorithm(modes[2])),
                    "Invalid tangent algorithm");
            std::string why;
            require(s.value.CanSetKnot(knot, &why), why);
            auto copy = s.value;
            TfErrorMark diagnostics;
            require(copy.SetKnot(knot), "Cannot set spline knot");
            check_diagnostics(diagnostics);
            s.value = std::move(copy);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API uint64_t usdm_spline_times(uint64_t h) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<ValueOwner>();
        result->type = "double[]";
        for (const auto &entry : spline_owner(h).value.GetKnots())
            result->numbers.push_back(entry.GetTime());
        return result;
    });
}
USDM_API int32_t usdm_spline_knot(uint64_t h, double time, double *data, int64_t size,
                                  int32_t *modes, int64_t mode_count) noexcept {
    return protect(
        [&] {
            require(data && size == 8 && modes && mode_count == 3,
                    "Spline knot output extent mismatch");
            const auto &s = spline_owner(h);
            auto knot = spline_knot(s, time);
            VtValue value, pre, left, right;
            require(knot.GetValue(&value) && knot.GetPreValue(&pre) &&
                        knot.GetPreTanSlope(&left) && knot.GetPostTanSlope(&right),
                    "Cannot inspect spline knot");
            double output[] = {
                time,
                spline_number(value),
                spline_number(pre),
                spline_number(left),
                spline_number(right),
                s.value.GetCurveType() == TsCurveTypeBezier ? knot.GetPreTanWidth() : 0,
                s.value.GetCurveType() == TsCurveTypeBezier ? knot.GetPostTanWidth()
                                                            : 0,
                double(knot.IsDualValued())};
            std::copy(output, output + 8, data);
            modes[0] = knot.GetNextInterpolation();
            modes[1] = knot.GetPreTanAlgorithm();
            modes[2] = knot.GetPostTanAlgorithm();
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_spline_remove(uint64_t h, double time) noexcept {
    return protect(
        [&] {
            require(std::isfinite(time), "Spline time must be finite");
            spline_owner(h).value.RemoveKnot(time);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API uint64_t usdm_spline_eval(uint64_t h, double time, int32_t mode) noexcept {
    return protect_owned([&] {
        require(std::isfinite(time) && mode >= 0 && mode <= 5,
                "Invalid spline evaluation");
        const auto &s = spline_owner(h).value;
        double value = 0;
        bool ok;
        if (mode == 0)
            ok = s.Eval(time, &value);
        else if (mode == 1)
            ok = s.EvalPreValue(time, &value);
        else if (mode == 2)
            ok = s.EvalDerivative(time, &value);
        else if (mode == 3)
            ok = s.EvalPreDerivative(time, &value);
        else if (mode == 4)
            ok = s.EvalHeld(time, &value);
        else
            ok = s.EvalPreValueHeld(time, &value);
        require(ok, "Spline has no value at this time", ErrorKind::NotFound);
        return domain_value(VtValue(value), "double");
    });
}
USDM_API int32_t usdm_spline_extrapolate(uint64_t h, int32_t side, int32_t mode,
                                         double slope, double boundary,
                                         int32_t has_boundary) noexcept {
    return protect(
        [&] {
            require((side == 0 || side == 1) && mode >= 0 && mode <= 6 &&
                        std::isfinite(slope) &&
                        (has_boundary == 0 || has_boundary == 1) &&
                        (!has_boundary || std::isfinite(boundary)),
                    "Invalid spline extrapolation");
            TsExtrapolation extrap{TsExtrapMode(mode)};
            extrap.slope = slope;
            if (has_boundary)
                extrap.loopBoundaryTime = boundary;
            auto copy = spline_owner(h).value;
            TfErrorMark diagnostics;
            if (side == 0)
                copy.SetPreExtrapolation(extrap);
            else
                copy.SetPostExtrapolation(extrap);
            require(copy.IsPreExtrapolationValid() && copy.IsPostExtrapolationValid(),
                    "Invalid spline extrapolation/loop combination");
            check_diagnostics(diagnostics);
            spline_owner(h).value = std::move(copy);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API int32_t usdm_spline_author(uint64_t h, uint64_t spline, const char *path,
                                    const char *name) noexcept {
    return protect(
        [&] {
            const auto &s = spline_owner(spline);
            auto p = prim(h, path);
            auto n = attr_name(name);
            auto a = p.GetAttribute(n);
            auto t = SdfSchema::GetInstance().FindType(TfToken(s.type));
            require(!p.GetRelationship(n),
                    "Spline attribute conflicts with a relationship");
            require(!a || a.GetTypeName() == t, "Spline and attribute types differ",
                    ErrorKind::TypeMismatch);
            if (!a)
                a = p.CreateAttribute(n, t, true);
            require(a.SetSpline(s.value), "Cannot author spline");
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API uint64_t usdm_spline_options(uint64_t h, int32_t kind) noexcept {
    return protect_owned([&] {
        require(kind >= 0 && kind <= 2, "Invalid spline options selector");
        auto result = std::make_unique<ValueOwner>();
        result->type = "double[]";
        const auto &s = spline_owner(h).value;
        if (kind < 2) {
            auto e = kind == 0 ? s.GetPreExtrapolation() : s.GetPostExtrapolation();
            result->numbers = {double(e.mode), e.slope,
                               double(bool(e.loopBoundaryTime)),
                               e.loopBoundaryTime.value_or(0)};
        } else {
            auto l = s.GetInnerLoopParams();
            result->numbers = {l.protoStart, l.protoEnd, double(l.numPreLoops),
                               double(l.numPostLoops), l.valueOffset};
        }
        return result;
    });
}
USDM_API int32_t usdm_spline_loop(uint64_t h, double start, double end, int64_t before,
                                  int64_t after, double offset) noexcept {
    return protect(
        [&] {
            require(std::isfinite(start) && std::isfinite(end) &&
                        std::isfinite(offset) && before >= 0 && before <= INT32_MAX &&
                        after >= 0 && after <= INT32_MAX,
                    "Invalid spline inner loop");
            auto copy = spline_owner(h).value;
            TsLoopParams loop;
            loop.protoStart = start;
            loop.protoEnd = end;
            loop.numPreLoops = int32_t(before);
            loop.numPostLoops = int32_t(after);
            loop.valueOffset = offset;
            if (end > start) {
                TsKnot knot;
                require(copy.GetKnot(start, &knot), "Inner-loop start requires a knot");
            }
            TfErrorMark diagnostics;
            copy.SetInnerLoopParams(loop);
            require(copy.IsPreExtrapolationValid() && copy.IsPostExtrapolationValid(),
                    "Inner loop conflicts with extrapolation");
            check_diagnostics(diagnostics);
            spline_owner(h).value = std::move(copy);
            return int32_t(0);
        },
        int32_t(-1));
}
USDM_API uint64_t usdm_spline_knot_metadata(uint64_t h, double time) noexcept {
    return protect_owned([&] {
        auto result = std::make_unique<MetadataOwner>();
        result->value = VtValue(spline_knot(spline_owner(h), time).GetCustomData());
        return result;
    });
}
USDM_API int32_t usdm_spline_knot_metadata_set(uint64_t h, double time,
                                               uint64_t metadata) noexcept {
    return protect(
        [&] {
            const auto &m = meta_owner(metadata).value;
            require(m.IsHolding<VtDictionary>(), "Knot metadata must be a dictionary",
                    ErrorKind::TypeMismatch);
            auto &s = spline_owner(h);
            auto knot = spline_knot(s, time);
            auto copy = s.value;
            TfErrorMark diagnostics;
            require(knot.SetCustomData(m.UncheckedGet<VtDictionary>()) &&
                        copy.SetKnot(knot),
                    "Cannot set knot metadata");
            check_diagnostics(diagnostics);
            s.value = std::move(copy);
            return int32_t(0);
        },
        int32_t(-1));
}
