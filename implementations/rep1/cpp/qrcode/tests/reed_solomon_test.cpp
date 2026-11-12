#include <gtest/gtest.h>

#include "qrcode/codewords.hpp"
#include "qrcode/reed_solomon.hpp"

using namespace qrcode;

TEST(ReedSolomon, GfMultiply) {
    EXPECT_EQ(gfMultiply(0, 77), 0);
    EXPECT_EQ(gfMultiply(1, 77), 77);
    EXPECT_EQ(gfMultiply(2, 0x80), 0x1D);  // 2^8 = 0x1D
    EXPECT_EQ(gfMultiply(0x57, 0x83), gfMultiply(0x83, 0x57));
}

TEST(ReedSolomon, HelloWorldEcc) {
    const std::vector<std::uint8_t> data = {32, 91, 11, 120, 209, 114, 220, 77,
                                            67, 64, 236, 17, 236, 17, 236, 17};
    const std::vector<std::uint8_t> ecc = {196, 35, 39, 119, 235, 215, 231, 226, 93, 23};
    EXPECT_EQ(ReedSolomon(10).remainder(data), ecc);
}

TEST(ReedSolomon, CodewordWithEccHasZeroRemainder) {
    const std::vector<std::uint8_t> data = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    ReedSolomon rs(7);
    auto ecc = rs.remainder(data);
    auto full = data;
    full.insert(full.end(), ecc.begin(), ecc.end());
    for (std::uint8_t b : rs.remainder(full)) EXPECT_EQ(b, 0);
}

TEST(ReedSolomon, InvalidDegree) { EXPECT_THROW(ReedSolomon(0), std::invalid_argument); }

TEST(Codewords, Version1Layout) {
    std::vector<std::uint8_t> data(16, 0);
    auto out = addEccAndInterleave(data, Ecl::M, 1);
    EXPECT_EQ(out.size(), 26u);
}

TEST(Codewords, InterleavesUnequalBlocks) {
    // v5-Q: 4 blocks (2 short of 15 data, 2 long of 16), 18 ECC each.
    const int v = 5;
    ASSERT_EQ(dataCodewords(Ecl::Q, v), 62);
    std::vector<std::uint8_t> data(62);
    for (std::size_t i = 0; i < data.size(); ++i) data[i] = static_cast<std::uint8_t>(i + 1);
    auto out = addEccAndInterleave(data, Ecl::Q, v);
    ASSERT_EQ(out.size(), 134u);
    // First round: first codeword of each block (blocks start at 0, 15, 30, 46).
    EXPECT_EQ(out[0], 1);
    EXPECT_EQ(out[1], 16);
    EXPECT_EQ(out[2], 31);
    EXPECT_EQ(out[3], 47);
    // Last data position holds only the long blocks' 16th codewords.
    EXPECT_EQ(out[60], 46);
    EXPECT_EQ(out[61], 62);
}

TEST(Codewords, WrongLengthThrows) {
    std::vector<std::uint8_t> data(5);
    EXPECT_THROW(addEccAndInterleave(data, Ecl::L, 1), std::invalid_argument);
}
