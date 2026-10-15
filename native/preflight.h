// SPDX-FileCopyrightText: 2026 henlamp
// SPDX-License-Identifier: MIT
// Original bounds checks for local USDC bootstrap and section-directory data.
// Layout reference: OpenUSD v26.08 pxr/usd/sdf/crateFile.h, _BootStrap/_Section.
// https://github.com/PixarAnimationStudios/OpenUSD/blob/v26.08/pxr/usd/sdf/crateFile.h
// This checks structural extents, not compressed data or referenced assets.
#include <fstream>
namespace {
uint64_t little64(const unsigned char *bytes) {
    uint64_t result = 0;
    for (unsigned i = 0; i < 8; ++i)
        result |= uint64_t(bytes[i]) << (8 * i);
    return result;
}
void preflight_local_crate(const char *filename) {
    std::ifstream file(filename, std::ios::binary | std::ios::ate);
    // Non-filesystem resolver identifiers remain the SDK resolver's responsibility.
    if (!file)
        return;
    const auto end = file.tellg();
    if (end < 8)
        return;
    const uint64_t size = uint64_t(end);
    unsigned char header[24]{};
    file.seekg(0);
    file.read(reinterpret_cast<char *>(header), 8);
    if (std::memcmp(header, "PXR-USDC", 8) != 0)
        return;
    require(size >= 88, "Truncated USDC bootstrap", ErrorKind::InvalidData);
    file.read(reinterpret_cast<char *>(header + 8), 16);
    require(bool(file), "Cannot read USDC bootstrap", ErrorKind::Io);
    const uint64_t directory = little64(header + 16);
    require(directory >= 88 && directory <= size - 8,
            "USDC section directory is outside file", ErrorKind::InvalidData);
    file.seekg(std::streamoff(directory));
    unsigned char count_bytes[8]{};
    file.read(reinterpret_cast<char *>(count_bytes), 8);
    require(bool(file), "Cannot read USDC section count", ErrorKind::Io);
    const uint64_t count = little64(count_bytes);
    require(count <= (size - directory - 8) / 32,
            "USDC section count exceeds directory extent", ErrorKind::InvalidData);
    for (uint64_t i = 0; i < count; ++i) {
        unsigned char section[32]{};
        file.read(reinterpret_cast<char *>(section), 32);
        require(bool(file), "Truncated USDC section entry", ErrorKind::InvalidData);
        const uint64_t start = little64(section + 16), length = little64(section + 24);
        require(start <= size && length <= size - start,
                "USDC section extent is outside file", ErrorKind::InvalidData);
    }
}
} // namespace
