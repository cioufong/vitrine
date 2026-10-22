// Host-native checks for convert.h (no Windows needed):
//   zig c++ -std=c++17 -o /tmp/convert_test guest/windows-camera/convert_test.cpp && /tmp/convert_test
#include "convert.h"

#include <cstdio>
#include <cstdlib>
#include <vector>

static int failures = 0;
#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                 \
        }                                                               \
    } while (0)

// A YUYV frame whose Y encodes the pixel's column and row, and U/V its macropixel and row.
static std::vector<uint8_t> pattern(uint32_t w, uint32_t h) {
    std::vector<uint8_t> f(vc::yuyvFrameSize(w, h));
    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x += 2) {
            uint8_t* p = &f[(size_t(y) * w + x) * 2];
            p[0] = uint8_t(x + 10 * y);
            p[1] = uint8_t(100 + x / 2 + 20 * y);
            p[2] = uint8_t(x + 1 + 10 * y);
            p[3] = uint8_t(200 - x / 2 - 20 * y);
        }
    return f;
}

static void testHeader() {
    uint32_t w, h;
    const uint8_t ok[8] = {0x00, 0x05, 0, 0, 0xd0, 0x02, 0, 0};  // 1280×720
    CHECK(vc::parseFrameHeader(ok, w, h) && w == 1280 && h == 720);
    const uint8_t odd[8] = {3, 0, 0, 0, 2, 0, 0, 0};
    CHECK(!vc::parseFrameHeader(odd, w, h));
    const uint8_t zero[8] = {0};
    CHECK(!vc::parseFrameHeader(zero, w, h));
    const uint8_t huge[8] = {0, 0, 1, 0, 2, 0, 0, 0};  // 65536 wide
    CHECK(!vc::parseFrameHeader(huge, w, h));
    CHECK(vc::yuyvFrameSize(1280, 720) == 1280 * 720 * 2);
}

static void testNV12SameSize() {
    const uint32_t w = 4, h = 2;
    auto src = pattern(w, h);
    const size_t pitch = 8;  // padded rows
    std::vector<uint8_t> dst(pitch * h * 3 / 2, 0xee);
    vc::yuyvToNV12(src.data(), w, h, dst.data(), pitch, w, h);
    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x++) CHECK(dst[y * pitch + x] == uint8_t(x + 10 * y));
    CHECK(dst[4] == 0xee);  // padding untouched
    const uint8_t* uv = &dst[pitch * h];
    // One chroma row averaging source rows 0 and 1: U = 100 + m + 10, V = 200 - m - 10.
    CHECK(uv[0] == 110 && uv[1] == 190);
    CHECK(uv[2] == 111 && uv[3] == 189);
}

static void testNV12Downscale() {
    auto src = pattern(8, 4);
    std::vector<uint8_t> dst(4 * 2 * 3 / 2);
    vc::yuyvToNV12(src.data(), 8, 4, dst.data(), 4, 4, 2);
    // Dest pixel (x, y) samples source (2x, 2y).
    CHECK(dst[0] == 0 && dst[1] == 2 && dst[3] == 6);
    CHECK(dst[4] == uint8_t(0 + 20) && dst[5] == uint8_t(2 + 20));
    // Chroma block (0,0) covers source rows 0 and 2 → U avg(100, 140), V avg(200, 160).
    CHECK(dst[8] == 120 && dst[9] == 180);
    // Chroma block (1,0): dest x 2 → source x 4, macropixel 2.
    CHECK(dst[10] == 122 && dst[11] == 178);
}

static void testYUY2() {
    auto src = pattern(4, 2);
    std::vector<uint8_t> same(src.size());
    vc::yuyvToYUY2(src.data(), 4, 2, same.data(), 8, 4, 2);
    CHECK(same == src);

    std::vector<uint8_t> up(8 * 2 * 2);
    vc::yuyvToYUY2(src.data(), 4, 2, up.data(), 16, 8, 2);
    // Doubling width: dest pixels 0,1 both come from source pixel 0 (Y 0), macropixel 0's U/V.
    CHECK(up[0] == 0 && up[1] == 100 && up[2] == 0 && up[3] == 200);
    // Dest pixels 6,7 → source pixel 3 (Y 3), macropixel 1.
    CHECK(up[12] == 3 && up[13] == 101 && up[14] == 3 && up[15] == 199);
}

static void testBlack() {
    std::vector<uint8_t> nv(6 * 2 * 3 / 2, 0);
    vc::blackNV12(nv.data(), 6, 4, 2);
    CHECK(nv[0] == 16 && nv[3] == 16 && nv[4] == 0 && nv[6] == 16);
    CHECK(nv[12] == 128 && nv[15] == 128 && nv[16] == 0);
    std::vector<uint8_t> yuy2(8, 0);
    vc::blackYUY2(yuy2.data(), 8, 4, 1);
    CHECK(yuy2[0] == 16 && yuy2[1] == 128 && yuy2[6] == 16 && yuy2[7] == 128);
}

int main() {
    testHeader();
    testNV12SameSize();
    testNV12Downscale();
    testYUY2();
    testBlack();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("convert_test: ok");
    return 0;
}
