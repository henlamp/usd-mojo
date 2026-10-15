// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic ignored "-Wcpp"
#endif
#include <pxr/pxr.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usdGeom/mesh.h>
#include <pxr/base/vt/array.h>
#include <chrono>
#include <cmath>
#include <iostream>
#include <vector>
#include <string>
PXR_NAMESPACE_USING_DIRECTIVE
int main(int argc, char **argv) {
    if (argc != 4)
        return 2;
    std::string operation(argv[1]);
    int repeats = std::stoi(argv[3]);
    long long total = 0;
    double checksum = 0;
    auto stage = operation == "open" ? UsdStageRefPtr() : UsdStage::Open(argv[2]);
    for (int i = 0; i < repeats + 3; ++i) {
        auto start = std::chrono::steady_clock::now();
        if (operation == "open") {
            auto s = UsdStage::Open(argv[2]);
            if (!s)
                return 3;
            auto end = std::chrono::steady_clock::now();
            if (i >= 3)
                total +=
                    std::chrono::duration_cast<std::chrono::nanoseconds>(end - start)
                        .count();
            checksum += 0.01;
        } else if (operation == "traverse") {
            std::vector<std::string> paths;
            for (const auto &p : stage->Traverse())
                paths.push_back(p.GetPath().GetString());
            auto end = std::chrono::steady_clock::now();
            if (i >= 3)
                total +=
                    std::chrono::duration_cast<std::chrono::nanoseconds>(end - start)
                        .count();
            checksum += paths.size();
            for (auto &p : paths)
                checksum += p.size();
        } else {
            UsdGeomMesh m(stage->GetPrimAtPath(SdfPath("/World/Mesh")));
            VtVec3fArray p;
            VtIntArray c, x;
            m.GetPointsAttr().Get(&p);
            if (operation == "mesh") {
                m.GetFaceVertexCountsAttr().Get(&c);
                m.GetFaceVertexIndicesAttr().Get(&x);
                std::string reason;
                if (!UsdGeomMesh::ValidateTopology(x, c, p.size(), &reason))
                    return 4;
                std::vector<float> points;
                points.reserve(p.size() * 3);
                for (auto &v : p)
                    for (int k = 0; k < 3; ++k) {
                        if (!std::isfinite(v[k]))
                            return 5;
                        points.push_back(v[k]);
                    }
                std::vector<int> counts(c.begin(), c.end()),
                    indices(x.begin(), x.end());
                auto end = std::chrono::steady_clock::now();
                if (i >= 3)
                    total += std::chrono::duration_cast<std::chrono::nanoseconds>(end -
                                                                                  start)
                                 .count();
                for (auto v : points)
                    checksum += v;
                for (auto v : counts)
                    checksum += v;
                for (auto v : indices)
                    checksum += v;
            } else {
                std::vector<double> values;
                values.reserve(p.size() * 3);
                for (auto &v : p)
                    for (int k = 0; k < 3; ++k)
                        values.push_back(v[k]);
                auto end = std::chrono::steady_clock::now();
                if (i >= 3)
                    total += std::chrono::duration_cast<std::chrono::nanoseconds>(end -
                                                                                  start)
                                 .count();
                for (auto v : values)
                    checksum += v;
            }
        }
    }
    std::cout.precision(17);
    std::cout << total << " " << checksum << "\n";
}
