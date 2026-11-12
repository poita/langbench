#include <gtest/gtest.h>

#include <string>

#include "qrcode/matrix.hpp"
#include "qrcode/qrcode.hpp"

using namespace qrcode;

namespace {

const char* kHelloWorld =
    "#######...#.#.#######\n"
    "#.....#.###...#.....#\n"
    "#.###.#...#.#.#.###.#\n"
    "#.###.#...#.#.#.###.#\n"
    "#.###.#.#.###.#.###.#\n"
    "#.....#..###..#.....#\n"
    "#######.#.#.#.#######\n"
    ".....................\n"
    "#.#.#.#..#..#...#..#.\n"
    ".####...#..#....#...#\n"
    "...#######.#..#.##...\n"
    "####.#.##..###.#.###.\n"
    ".#..####.#.#..###.#.#\n"
    "........#.#...#...#.#\n"
    "#######.....#..#.##..\n"
    "#.....#..##...##.#...\n"
    "#.###.#.##..#.#######\n"
    "#.###.#...##.#.#...#.\n"
    "#.###.#.####.###.#..#\n"
    "#.....#....###...#.##\n"
    "#######.##.#.###....#\n";

const char* kNumeric =
    "#######.##..#.#######\n"
    "#.....#..#..#.#.....#\n"
    "#.###.#.#.#.#.#.###.#\n"
    "#.###.#.#..#..#.###.#\n"
    "#.###.#.###...#.###.#\n"
    "#.....#.......#.....#\n"
    "#######.#.#.#.#######\n"
    ".........##..........\n"
    "####..#.#.#..#..###.#\n"
    "####...##...#..#.##..\n"
    "....######..#####..#.\n"
    "##..#..##.#.##...#.#.\n"
    "#..#..##..##.#..#....\n"
    "........##...#.#....#\n"
    "#######..##..##.#.##.\n"
    "#.....#....####...#.#\n"
    "#.###.#..#.#..#.....#\n"
    "#.###.#.#....#..#.##.\n"
    "#.###.#.#..#.#..#.#..\n"
    "#.....#.##.##.#.##.##\n"
    "#######.##.##..#...#.\n";

}  // namespace

TEST(Encode, HelloWorldFixedMask) {
    Symbol s = encode("HELLO WORLD", Ecl::M, 0);
    EXPECT_EQ(s.version(), 1);
    EXPECT_EQ(s.mask(), 0);
    EXPECT_EQ(s.size(), 21);
    EXPECT_EQ(s.toString(), kHelloWorld);
}

TEST(Encode, HelloWorldAutoPicksMask0) {
    Symbol s = encode("HELLO WORLD", Ecl::M);
    EXPECT_EQ(s.mask(), 0);
    EXPECT_EQ(s.toString(), kHelloWorld);
}

TEST(Encode, NumericAuto) {
    Symbol s = encode("01234567", Ecl::L, kAutoMask);
    EXPECT_EQ(s.version(), 1);
    EXPECT_EQ(s.mask(), 3);
    EXPECT_EQ(s.toString(), kNumeric);
}

TEST(Encode, Utf8IsByteMode) {
    Symbol s = encode("h\xC3\xA9llo", Ecl::H, 5);
    EXPECT_EQ(s.version(), 1);
    EXPECT_EQ(s.mask(), 5);
    // Spot check first row and last row of the expected output.
    std::string text = s.toString();
    EXPECT_EQ(text.substr(0, 22), "#######.####..#######\n");
    EXPECT_EQ(text.substr(text.size() - 22, 21), "#######...#.#.#.#..#.");
}

TEST(Encode, LargestVersion) {
    Symbol s = encode(std::string(7089, '7'), Ecl::L, 2);
    EXPECT_EQ(s.version(), 40);
    EXPECT_EQ(s.size(), 177);
    EXPECT_THROW(encode(std::string(7090, '7'), Ecl::L), std::length_error);
}

TEST(Encode, VersionInfoBitsPresent) {
    Symbol s = encode(std::string(200, 'a'), Ecl::M, 0);
    ASSERT_GE(s.version(), 7);
    const int n = s.size();
    const unsigned expected = versionBits(s.version());
    for (int i = 0; i < 18; ++i) {
        bool bit = (expected >> i) & 1;
        EXPECT_EQ(s.dark(n - 11 + i % 3, i / 3), bit) << i;
        EXPECT_EQ(s.dark(i / 3, n - 11 + i % 3), bit) << i;
    }
}

TEST(Encode, InvalidMaskThrows) {
    EXPECT_THROW(encode("A", Ecl::L, 8), std::invalid_argument);
    EXPECT_THROW(encode("A", Ecl::L, -2), std::invalid_argument);
}

TEST(Encode, FormatInformationReadBack) {
    for (Ecl e : {Ecl::L, Ecl::M, Ecl::Q, Ecl::H})
        for (int mask = 0; mask < 8; ++mask) {
            Symbol s = encode("TEST", e, mask);
            unsigned bits = 0;
            // Second copy: (n-1-i, 8) for i 0..7.
            for (int i = 0; i < 8; ++i) bits |= static_cast<unsigned>(s.dark(s.size() - 1 - i, 8)) << i;
            for (int i = 8; i < 15; ++i) bits |= static_cast<unsigned>(s.dark(8, s.size() - 15 + i)) << i;
            EXPECT_EQ(bits, formatBits(e, mask));
        }
}

TEST(Encode, AutoMaskIsDeterministicAndMatchesChosenFixedMask) {
    Symbol a = encode("Hello, world! 12345", Ecl::Q);
    Symbol b = encode("Hello, world! 12345", Ecl::Q, a.mask());
    EXPECT_EQ(a.toString(), b.toString());
}

TEST(Symbol, DarkOutOfRangeIsLight) {
    Symbol s = encode("1", Ecl::L, 0);
    EXPECT_FALSE(s.dark(-1, 0));
    EXPECT_FALSE(s.dark(0, 21));
    EXPECT_TRUE(s.dark(0, 0));
}
