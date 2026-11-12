#include <gtest/gtest.h>

#include "qrcode/segment.hpp"

using namespace qrcode;

TEST(Segment, ModeSelection) {
    EXPECT_EQ(selectMode("0123456789"), Mode::Numeric);
    EXPECT_EQ(selectMode("HELLO WORLD $%*+-./:"), Mode::Alphanumeric);
    EXPECT_EQ(selectMode("Hello"), Mode::Byte);
    EXPECT_EQ(selectMode("h\xC3\xA9llo"), Mode::Byte);
    EXPECT_EQ(selectMode("12 34"), Mode::Alphanumeric);
}

TEST(Segment, BitLengths) {
    EXPECT_EQ(dataBitLength(Mode::Numeric, 8), 10u * 2 + 7);
    EXPECT_EQ(dataBitLength(Mode::Numeric, 7), 10u * 2 + 4);
    EXPECT_EQ(dataBitLength(Mode::Numeric, 6), 20u);
    EXPECT_EQ(dataBitLength(Mode::Alphanumeric, 11), 11u * 5 + 6);
    EXPECT_EQ(dataBitLength(Mode::Byte, 6), 48u);
}

TEST(Segment, CharCountWidths) {
    EXPECT_EQ(charCountBits(Mode::Numeric, 9), 10);
    EXPECT_EQ(charCountBits(Mode::Numeric, 10), 12);
    EXPECT_EQ(charCountBits(Mode::Numeric, 27), 14);
    EXPECT_EQ(charCountBits(Mode::Alphanumeric, 26), 11);
    EXPECT_EQ(charCountBits(Mode::Byte, 9), 8);
    EXPECT_EQ(charCountBits(Mode::Byte, 10), 16);
}

TEST(Segment, VersionSelectionCapacities) {
    EXPECT_EQ(chooseVersion(Mode::Numeric, 41, Ecl::L), 1);
    EXPECT_EQ(chooseVersion(Mode::Numeric, 42, Ecl::L), 2);
    EXPECT_EQ(chooseVersion(Mode::Numeric, 7089, Ecl::L), 40);
    EXPECT_EQ(chooseVersion(Mode::Numeric, 7090, Ecl::L), 0);
    EXPECT_EQ(chooseVersion(Mode::Alphanumeric, 4296, Ecl::L), 40);
    EXPECT_EQ(chooseVersion(Mode::Byte, 2953, Ecl::L), 40);
    EXPECT_EQ(chooseVersion(Mode::Byte, 1273, Ecl::H), 40);
    EXPECT_EQ(chooseVersion(Mode::Byte, 1274, Ecl::H), 0);
}

TEST(Segment, HelloWorldDataCodewords) {
    BitBuffer bits;
    appendSegment(bits, Mode::Alphanumeric, "HELLO WORLD", 1);
    terminateAndPad(bits, Ecl::M, 1);
    const std::vector<std::uint8_t> expected = {32, 91, 11, 120, 209, 114, 220, 77,
                                                67, 64, 236, 17, 236, 17, 236, 17};
    EXPECT_EQ(bits.bytes(), expected);
}

TEST(Segment, TerminatorIsTruncatedWhenFull) {
    // v1-L holds 19 codewords = 152 bits; 41 digits need 4 + 10 + 137 = 151,
    // leaving room for only a 1-bit terminator.
    BitBuffer bits;
    appendSegment(bits, Mode::Numeric, std::string(41, '1'), 1);
    EXPECT_EQ(bits.size(), 151u);
    terminateAndPad(bits, Ecl::L, 1);
    EXPECT_EQ(bits.size(), 152u);
}
