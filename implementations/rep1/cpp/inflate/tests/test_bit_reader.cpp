#include <gtest/gtest.h>

#include "inflate/bit_reader.hpp"

using inflate::BitReader;

TEST(BitReader, ReadsLsbFirst) {
  const std::uint8_t data[] = {0b10110100, 0xFF};
  BitReader br(data, sizeof data);
  std::uint32_t v;
  ASSERT_TRUE(br.read(3, v));
  EXPECT_EQ(v, 0b100u);
  ASSERT_TRUE(br.read(5, v));
  EXPECT_EQ(v, 0b10110u);
  ASSERT_TRUE(br.read(8, v));
  EXPECT_EQ(v, 0xFFu);
}

TEST(BitReader, CannotConsumePastEnd) {
  const std::uint8_t data[] = {0xAB};
  BitReader br(data, 1);
  std::uint32_t v;
  EXPECT_FALSE(br.read(9, v));
  EXPECT_TRUE(br.read(8, v));  // failed read consumed nothing
  EXPECT_EQ(v, 0xABu);
  EXPECT_FALSE(br.read(1, v));
}

TEST(BitReader, PeekPadsWithZeros) {
  const std::uint8_t data[] = {0x01};
  BitReader br(data, 1);
  br.refill();
  EXPECT_EQ(br.buffered(), 8u);
  EXPECT_EQ(br.peek(15), 1u);
}

TEST(BitReader, AlignAndWholeBytes) {
  const std::uint8_t data[] = {1, 2, 3, 4};
  BitReader br(data, 4);
  std::uint32_t v;
  ASSERT_TRUE(br.read(3, v));
  EXPECT_EQ(br.whole_bytes_remaining(), 3u);
  br.align_to_byte();
  EXPECT_EQ(br.whole_bytes_remaining(), 3u);
  std::uint8_t out[2];
  br.read_aligned_bytes(out, 2);
  EXPECT_EQ(out[0], 2);
  EXPECT_EQ(out[1], 3);
  EXPECT_EQ(br.whole_bytes_remaining(), 1u);
}

TEST(BitReader, AlignWhenAlreadyAlignedKeepsBits) {
  const std::uint8_t data[] = {9, 8};
  BitReader br(data, 2);
  std::uint32_t v;
  ASSERT_TRUE(br.read(8, v));
  br.align_to_byte();
  ASSERT_TRUE(br.read(8, v));
  EXPECT_EQ(v, 8u);
}

TEST(BitReader, ReadAlignedBytesLargeSpansBufferAndInput) {
  std::uint8_t data[40];
  for (int i = 0; i < 40; ++i) data[i] = static_cast<std::uint8_t>(i);
  BitReader br(data, sizeof data);
  std::uint32_t v;
  ASSERT_TRUE(br.read(8, v));  // fills the 64-bit buffer
  std::uint8_t out[39];
  br.read_aligned_bytes(out, 39);
  for (int i = 0; i < 39; ++i) EXPECT_EQ(out[i], i + 1);
  EXPECT_EQ(br.whole_bytes_remaining(), 0u);
}
