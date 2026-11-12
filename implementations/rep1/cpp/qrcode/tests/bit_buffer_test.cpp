#include <gtest/gtest.h>

#include "qrcode/bit_buffer.hpp"

using qrcode::BitBuffer;

TEST(BitBuffer, AppendsMsbFirst) {
    BitBuffer b;
    b.append(0b101, 3);
    b.append(0xFF, 8);
    b.append(0, 2);
    EXPECT_EQ(b.size(), 13u);
    ASSERT_EQ(b.bytes().size(), 2u);
    EXPECT_EQ(b.bytes()[0], 0b10111111);
    EXPECT_EQ(b.bytes()[1], 0b11100000);
    EXPECT_EQ(b.bit(0), 1);
    EXPECT_EQ(b.bit(1), 0);
    EXPECT_EQ(b.bit(12), 0);
}

TEST(BitBuffer, AppendZerosKeepsPadding) {
    BitBuffer b;
    b.append(1, 1);
    b.appendZeros(9);
    EXPECT_EQ(b.size(), 10u);
    EXPECT_EQ(b.bytes().size(), 2u);
    EXPECT_EQ(b.bytes()[0], 0x80);
    EXPECT_EQ(b.bytes()[1], 0);
}
