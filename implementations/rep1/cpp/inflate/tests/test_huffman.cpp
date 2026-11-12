#include <gtest/gtest.h>

#include "inflate/huffman.hpp"
#include "test_support.hpp"

using namespace inflate;
using testing_support::BitWriter;
using testing_support::Code;
using Kind = HuffmanInfo::Kind;

namespace {
std::vector<std::uint8_t> narrow(const std::vector<unsigned>& l) {
  return std::vector<std::uint8_t>(l.begin(), l.end());
}
}  // namespace

TEST(Huffman, ClassifiesLengthSets) {
  HuffmanTable t(7);
  auto l = narrow({1, 2, 2});
  EXPECT_EQ(t.build(l.data(), l.size()).kind, Kind::Complete);
  l = narrow({1, 2, 3});
  EXPECT_EQ(t.build(l.data(), l.size()).kind, Kind::Incomplete);
  l = narrow({1, 1, 1});
  EXPECT_EQ(t.build(l.data(), l.size()).kind, Kind::OverSubscribed);
  l = narrow({0, 0, 0});
  auto info = t.build(l.data(), l.size());
  EXPECT_EQ(info.kind, Kind::Incomplete);
  EXPECT_EQ(info.used, 0u);
  l = narrow({0, 1, 0});
  info = t.build(l.data(), l.size());
  EXPECT_TRUE(info.single_one_bit_code());
  l = narrow({0, 2, 0});
  EXPECT_FALSE(t.build(l.data(), l.size()).single_one_bit_code());
}

TEST(Huffman, DecodesCanonicalCodes) {
  // Lengths from RFC 1951 3.2.2: A=3 B=3 C=3 D=3 E=3 F=2 G=4 H=4.
  const std::vector<unsigned> lens{3, 3, 3, 3, 3, 2, 4, 4};
  Code code(lens);
  EXPECT_EQ(code.codes[5], 0b00u);
  EXPECT_EQ(code.codes[0], 0b010u);
  EXPECT_EQ(code.codes[6], 0b1110u);
  HuffmanTable t(3);  // force second-level tables for the 4-bit codes
  auto l = narrow(lens);
  ASSERT_EQ(t.build(l.data(), l.size()).kind, Kind::Complete);
  BitWriter w;
  const unsigned seq[] = {7, 0, 5, 6, 4, 3, 2, 1, 5};
  for (unsigned s : seq) code.put(w, s);
  BitReader br(w.bytes().data(), w.bytes().size());
  for (unsigned s : seq) EXPECT_EQ(t.decode(br), static_cast<int>(s));
}

class HuffmanRootWidth : public ::testing::TestWithParam<unsigned> {};

TEST_P(HuffmanRootWidth, AllFifteenBitShapes) {
  // 1,2,3,...,14,15,15: a maximally skewed complete code.
  std::vector<unsigned> lens;
  for (unsigned i = 1; i <= 15; ++i) lens.push_back(i);
  lens.push_back(15);
  Code code(lens);
  HuffmanTable t(GetParam());
  auto l = narrow(lens);
  ASSERT_EQ(t.build(l.data(), l.size()).kind, Kind::Complete);
  BitWriter w;
  for (unsigned s = 0; s < lens.size(); ++s) code.put(w, s);
  for (unsigned s = lens.size(); s-- > 0;) code.put(w, s);
  BitReader br(w.bytes().data(), w.bytes().size());
  for (unsigned s = 0; s < lens.size(); ++s) EXPECT_EQ(t.decode(br), static_cast<int>(s));
  for (unsigned s = lens.size(); s-- > 0;) EXPECT_EQ(t.decode(br), static_cast<int>(s));
}

INSTANTIATE_TEST_SUITE_P(Roots, HuffmanRootWidth, ::testing::Values(1u, 5u, 8u, 10u, 15u));

TEST(Huffman, IncompleteTableRejectsUnassignedPattern) {
  HuffmanTable t(8);
  auto l = narrow({0, 1});  // only code: symbol 1 -> "0"
  ASSERT_TRUE(t.build(l.data(), l.size()).single_one_bit_code());
  const std::uint8_t zero[] = {0x00};
  BitReader a(zero, 1);
  EXPECT_EQ(t.decode(a), 1);
  const std::uint8_t one[] = {0x01};
  BitReader b(one, 1);
  EXPECT_EQ(t.decode(b), HuffmanTable::kInvalid);
}

TEST(Huffman, TruncatedCodeConsumesNothing) {
  HuffmanTable t(4);
  auto l = narrow({1, 2, 3, 3});  // codes: 0, 10, 110, 111
  ASSERT_EQ(t.build(l.data(), l.size()).kind, Kind::Complete);
  const std::uint8_t data[] = {0xC0};  // bits LSB-first: six 0s, then 1, 1
  BitReader br(data, 1);
  std::uint32_t v;
  ASSERT_TRUE(br.read(6, v));
  // Two bits "11" remain; zero padding would complete them to "110" (symbol
  // 2), but that third bit does not exist.
  EXPECT_EQ(t.decode(br), HuffmanTable::kTruncated);
  EXPECT_EQ(br.buffered(), 2u);
}
