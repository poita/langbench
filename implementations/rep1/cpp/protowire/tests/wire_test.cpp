#include <gtest/gtest.h>

#include <vector>

#include "protowire/wire.hpp"

using namespace protowire;

namespace {
Reader readerOf(const std::vector<std::uint8_t>& v) { return Reader(v.data(), v.data() + v.size()); }
}  // namespace

TEST(Varint, MinimalEncoding) {
  auto enc = [](std::uint64_t v) {
    std::vector<std::uint8_t> out;
    appendVarint(out, v);
    EXPECT_EQ(out.size(), varintSize(v));
    return out;
  };
  EXPECT_EQ(enc(0), (std::vector<std::uint8_t>{0x00}));
  EXPECT_EQ(enc(1), (std::vector<std::uint8_t>{0x01}));
  EXPECT_EQ(enc(300), (std::vector<std::uint8_t>{0xac, 0x02}));
  EXPECT_EQ(enc(~0ull).size(), 10u);
  EXPECT_EQ(enc(~0ull).back(), 0x01);
}

TEST(Varint, DecodeAcceptsNonMinimal) {
  std::vector<std::uint8_t> b{0x81, 0x00};
  auto r = readerOf(b);
  std::uint64_t v = 99;
  ASSERT_TRUE(r.readVarint(10, v));
  EXPECT_EQ(v, 1u);
  EXPECT_TRUE(r.empty());
}

TEST(Varint, TenthByteHighBitsDiscarded) {
  std::vector<std::uint8_t> a(9, 0xff);
  a.push_back(0x7f);
  auto r = readerOf(a);
  std::uint64_t v = 0;
  ASSERT_TRUE(r.readVarint(10, v));
  EXPECT_EQ(v, ~0ull);

  std::vector<std::uint8_t> b(9, 0x80);
  b.push_back(0x02);
  auto r2 = readerOf(b);
  ASSERT_TRUE(r2.readVarint(10, v));
  EXPECT_EQ(v, 0u);
}

TEST(Varint, RejectsOverlongAndTruncated) {
  std::vector<std::uint8_t> eleven(11, 0x80);
  auto r = readerOf(eleven);
  std::uint64_t v;
  EXPECT_FALSE(r.readVarint(10, v));

  std::vector<std::uint8_t> trunc{0xff};
  auto r2 = readerOf(trunc);
  EXPECT_FALSE(r2.readVarint(10, v));

  std::vector<std::uint8_t> six{0x80, 0x80, 0x80, 0x80, 0x80, 0x01};
  auto r3 = readerOf(six);
  EXPECT_FALSE(r3.readVarint(5, v));
}

TEST(Zigzag, KnownValues) {
  EXPECT_EQ(zigzag32(0), 0u);
  EXPECT_EQ(zigzag32(-1), 1u);
  EXPECT_EQ(zigzag32(1), 2u);
  EXPECT_EQ(zigzag32(INT32_MIN), 0xffffffffu);
  EXPECT_EQ(zigzag64(INT64_MIN), ~0ull);
  EXPECT_EQ(zigzag64(-5), 9u);
  EXPECT_EQ(unzigzag32(0xffffffffu), INT32_MIN);
  EXPECT_EQ(unzigzag64(~0ull), INT64_MIN);
  for (std::int32_t v : {-100000, -2, -1, 0, 1, 2, 77777}) EXPECT_EQ(unzigzag32(zigzag32(v)), v);
}

TEST(Reader, FixedAndTake) {
  std::vector<std::uint8_t> b{1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 9};
  auto r = readerOf(b);
  std::uint32_t a;
  std::uint64_t c;
  ASSERT_TRUE(r.readFixed32(a));
  EXPECT_EQ(a, 1u);
  ASSERT_TRUE(r.readFixed64(c));
  EXPECT_EQ(c, 2u);
  Reader sub(nullptr, nullptr);
  EXPECT_FALSE(r.take(2, sub));
  ASSERT_TRUE(r.take(1, sub));
  EXPECT_EQ(sub.remaining(), 1u);
  EXPECT_FALSE(r.readFixed32(a));
}
