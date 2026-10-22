// Pixel conversion and pipe framing for the Vitrine Camera media source. Platform-neutral (no
// Windows headers) so convert_test.cpp can run on the build machine.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace vc {

// Largest frame the agent may send (both dimensions); anything bigger is a framing error.
constexpr uint32_t kMaxDimension = 4096;
constexpr size_t kFrameHeaderSize = 8;

// A frame message on \\.\pipe\vitrine-camera: u32 width, u32 height (little-endian), then
// width*height*2 bytes of packed YUYV 4:2:2. Returns false for a size no camera sends, which
// means the stream is out of step and the connection should be dropped.
inline bool parseFrameHeader(const uint8_t* h, uint32_t& width, uint32_t& height) {
    width = uint32_t(h[0]) | uint32_t(h[1]) << 8 | uint32_t(h[2]) << 16 | uint32_t(h[3]) << 24;
    height = uint32_t(h[4]) | uint32_t(h[5]) << 8 | uint32_t(h[6]) << 16 | uint32_t(h[7]) << 24;
    return width >= 2 && height >= 2 && width <= kMaxDimension && height <= kMaxDimension && width % 2 == 0;
}

inline size_t yuyvFrameSize(uint32_t width, uint32_t height) { return size_t(width) * height * 2; }

// Scales (nearest neighbour) and converts a packed YUYV frame to NV12: a dw×dh Y plane, then the
// interleaved UV plane at dst + pitch*dh with the same pitch (MF's NV12 layout). Each UV sample
// averages the two source rows its 2×2 block covers. dw and dh must be even.
inline void yuyvToNV12(const uint8_t* src, uint32_t sw, uint32_t sh, uint8_t* dst, size_t pitch,
                       uint32_t dw, uint32_t dh) {
    const size_t srcPitch = size_t(sw) * 2;
    for (uint32_t y = 0; y < dh; y++) {
        const uint8_t* s = src + size_t(uint64_t(y) * sh / dh) * srcPitch;
        uint8_t* d = dst + y * pitch;
        if (sw == dw) {
            for (uint32_t x = 0; x < dw; x++) d[x] = s[x * 2];
        } else {
            for (uint32_t x = 0; x < dw; x++) d[x] = s[size_t(uint64_t(x) * sw / dw) * 2];
        }
    }
    uint8_t* uv = dst + pitch * dh;
    for (uint32_t cy = 0; cy < dh / 2; cy++) {
        const uint8_t* s0 = src + size_t(uint64_t(2 * cy) * sh / dh) * srcPitch;
        const uint8_t* s1 = src + size_t(uint64_t(2 * cy + 1) * sh / dh) * srcPitch;
        uint8_t* d = uv + cy * pitch;
        for (uint32_t cx = 0; cx < dw / 2; cx++) {
            // The YUYV macropixel (Y0 U Y1 V) holding the block's top-left source pixel.
            size_t m = (size_t(uint64_t(2 * cx) * sw / dw) & ~size_t(1)) * 2;
            d[cx * 2] = uint8_t((s0[m + 1] + s1[m + 1] + 1) / 2);
            d[cx * 2 + 1] = uint8_t((s0[m + 3] + s1[m + 3] + 1) / 2);
        }
    }
}

// Scales (nearest neighbour) a packed YUYV frame into a dw×dh YUY2 image (the same layout) with
// the given pitch. dw must be even.
inline void yuyvToYUY2(const uint8_t* src, uint32_t sw, uint32_t sh, uint8_t* dst, size_t pitch,
                       uint32_t dw, uint32_t dh) {
    const size_t srcPitch = size_t(sw) * 2;
    for (uint32_t y = 0; y < dh; y++) {
        const uint8_t* s = src + size_t(uint64_t(y) * sh / dh) * srcPitch;
        uint8_t* d = dst + y * pitch;
        if (sw == dw) {
            memcpy(d, s, srcPitch);
            continue;
        }
        for (uint32_t x = 0; x < dw; x += 2) {
            size_t x0 = size_t(uint64_t(x) * sw / dw), x1 = size_t(uint64_t(x + 1) * sw / dw);
            size_t m = (x0 & ~size_t(1)) * 2;
            d[x * 2] = s[x0 * 2];
            d[x * 2 + 1] = s[m + 1];
            d[x * 2 + 2] = s[x1 * 2];
            d[x * 2 + 3] = s[m + 3];
        }
    }
}

// Black in video range: Y 16, U and V 128.
inline void blackNV12(uint8_t* dst, size_t pitch, uint32_t dw, uint32_t dh) {
    for (uint32_t y = 0; y < dh; y++) memset(dst + y * pitch, 16, dw);
    for (uint32_t y = 0; y < dh / 2; y++) memset(dst + (dh + y) * pitch, 128, dw);
}

inline void blackYUY2(uint8_t* dst, size_t pitch, uint32_t dw, uint32_t dh) {
    for (uint32_t y = 0; y < dh; y++) {
        uint8_t* d = dst + y * pitch;
        for (uint32_t x = 0; x < dw * 2; x += 2) {
            d[x] = 16;
            d[x + 1] = 128;
        }
    }
}

}  // namespace vc
