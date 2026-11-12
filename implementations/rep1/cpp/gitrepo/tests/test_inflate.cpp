#include <gtest/gtest.h>

#include "gitrepo/error.hpp"
#include "gitrepo/inflate.hpp"
#include "support.hpp"

using gitrepo::Error;
using gitrepo::zlib_inflate;

namespace {
std::string from_hex(const std::string& hex) {
  std::string out;
  for (std::size_t i = 0; i + 1 < hex.size(); i += 2) {
    out += static_cast<char>(std::stoi(hex.substr(i, 2), nullptr, 16));
  }
  return out;
}

std::string inflate(const std::string& in) {
  std::string out;
  zlib_inflate(in, out);
  return out;
}
}  // namespace

TEST(Inflate, StoredBlock) {
  EXPECT_EQ(inflate(testing_support::zlib_store("hello")), "hello");
  EXPECT_EQ(inflate(testing_support::zlib_store("")), "");
}

TEST(Inflate, StoredBlockLargerThanOneChunk) {
  std::string data(70000, 'x');
  data[69999] = 'y';
  EXPECT_EQ(inflate(testing_support::zlib_store(data)), data);
}

TEST(Inflate, FixedHuffman) {
  // zlib.compress(b"hello hello hello hello hello\n")
  EXPECT_EQ(inflate(from_hex("789ccb48cdc9c957c8c04e720100adff0aef")),
            "hello hello hello hello hello\n");
}

TEST(Inflate, DynamicHuffman) {
  std::string want;
  for (int i = 0; i < 70; ++i) want += static_cast<char>(((i * i) / 7 + i / 13) % 41 + 48);
  std::string z = from_hex(
      "78da05c10b1280101000d02bd9246d2a9f61c48c6155a6fb9fa4f71863307121519dd6a7422f2ccac672c36a"
      "aef649933a3f22719d070612aeceae89f06c192c619efcd07daf587e6a2e11f6");
  EXPECT_EQ(inflate(z), want);
}

TEST(Inflate, ReportsConsumedBytesAndIgnoresTrailingData) {
  std::string z = testing_support::zlib_store("abc");
  std::string out;
  EXPECT_EQ(zlib_inflate(z + "TRAILING", out), z.size());
  EXPECT_EQ(out, "abc");
}

TEST(Inflate, RejectsBadHeaders) {
  EXPECT_THROW(inflate(""), Error);
  EXPECT_THROW(inflate(from_hex("7800")), Error);           // check bits wrong
  EXPECT_THROW(inflate(from_hex("7801")), Error);           // truncated
  EXPECT_THROW(inflate(from_hex("789c") + "x"), Error);     // truncated block
  EXPECT_THROW(inflate(from_hex("7820") + "x"), Error);     // preset dictionary (0x7820 % 31 == 0)
  EXPECT_THROW(inflate(from_hex("7f9d") + "x"), Error);     // not deflate? (CMF & 0xf == 15)
}

TEST(Inflate, RejectsBadAdler) {
  std::string z = testing_support::zlib_store("hello");
  z.back() ^= 1;
  EXPECT_THROW(inflate(z), Error);
}

TEST(Inflate, RejectsTruncatedStream) {
  std::string z = from_hex("789ccb48cdc9c957c8c04e720100adff0aef");
  EXPECT_THROW(inflate(z.substr(0, 10)), Error);
  EXPECT_THROW(inflate(z.substr(0, z.size() - 2)), Error);
}

TEST(Inflate, EnforcesOutputLimit) {
  std::string out;
  EXPECT_THROW(zlib_inflate(from_hex("789ccb48cdc9c957c8c04e720100adff0aef"), out, 5), Error);
}

TEST(Inflate, Adler32KnownValue) {
  EXPECT_EQ(gitrepo::adler32("Wikipedia"), 0x11E60398u);
}
