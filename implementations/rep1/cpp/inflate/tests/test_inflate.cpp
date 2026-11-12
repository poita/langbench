// Valid streams: examples from SPEC.md, hand-built blocks and zlib output.

#include <gtest/gtest.h>

#include "test_support.hpp"

using namespace testing_support;
using inflate::Error;

namespace {

Bytes decode_ok(const Bytes& stream) {
  auto r = inflate::inflate(stream);
  EXPECT_TRUE(r.ok()) << inflate::to_string(r.error);
  return r.data;
}

}  // namespace

TEST(Inflate, EmptyFixedBlock) { EXPECT_EQ(decode_ok(from_hex("0300")), Bytes{}); }

TEST(Inflate, StoredBlock) {
  EXPECT_EQ(decode_ok(from_hex("010100feff41")), Bytes{0x41});
}

TEST(Inflate, FixedBlockWithOverlappingCopy) {
  EXPECT_EQ(decode_ok(from_hex("4b4c4a862000")), bytes_of("abcabcabc"));
}

TEST(Inflate, StoredBlocksAndEmptyStored) {
  BitWriter w;
  stored_block(w, bytes_of("hello "), false);
  stored_block(w, {}, false);
  stored_block(w, bytes_of("world"), true);
  EXPECT_EQ(decode_ok(w.bytes()), bytes_of("hello world"));
}

TEST(Inflate, StoredBlockAfterUnalignedBlockIgnoresPaddingBits) {
  BitWriter w;
  w.bits(0, 1);  // not final
  w.bits(1, 2);  // fixed
  fixed_lit_code().put(w, 'x');
  fixed_lit_code().put(w, 256);
  w.bits(1, 1);  // final stored
  w.bits(0, 2);
  w.bits(7, 3);  // nonzero padding bits (up to the byte boundary) are ignored
  w.align();
  w.bits(1, 16);
  w.bits(0xFFFE, 16);
  w.raw_byte('y');
  EXPECT_EQ(decode_ok(w.bytes()), bytes_of("xy"));
}

TEST(Inflate, StoredHeaderEndingOnByteBoundary) {
  // Three 9-bit literals put the end-of-block code's last bit at bit 36, so
  // the final stored block's 3 header bits occupy bits 37..39: nothing to skip.
  const auto lit = fixed_lit_code();
  BitWriter w;
  w.bits(0, 1);
  w.bits(1, 2);
  for (unsigned c : {144u, 145u, 146u}) lit.put(w, c);
  lit.put(w, 256);
  w.bits(1, 1);
  w.bits(0, 2);
  w.bits(1, 16);
  w.bits(0xFFFE, 16);
  w.raw_byte(0x55);
  ASSERT_EQ(w.bytes().size(), 5u + 5u);
  EXPECT_EQ(decode_ok(w.bytes()), (Bytes{144, 145, 146, 0x55}));
}

TEST(Inflate, FixedBlockLiteralsAndMatches) {
  const auto lit = fixed_lit_code();
  const auto dist = fixed_dist_code();
  BitWriter w;
  w.bits(1, 1);
  w.bits(1, 2);
  for (char c : std::string("abcd")) lit.put(w, static_cast<unsigned char>(c));
  put_match(w, lit, dist, 258, 4);
  put_match(w, lit, dist, 3, 1);
  put_match(w, lit, dist, 100, 7);
  lit.put(w, 256);
  Bytes expect = bytes_of("abcd");
  auto copy = [&](size_t len, size_t d) {
    for (size_t i = 0; i < len; ++i) expect.push_back(expect[expect.size() - d]);
  };
  copy(258, 4);
  copy(3, 1);
  copy(100, 7);
  EXPECT_EQ(decode_ok(w.bytes()), expect);
}

TEST(Inflate, Symbol284WithAllExtraBitsGivesLength258) {
  const auto lit = fixed_lit_code();
  const auto dist = fixed_dist_code();
  BitWriter w;
  w.bits(1, 1);
  w.bits(1, 2);
  lit.put(w, 'z');
  lit.put(w, 284);
  w.bits(31, 5);
  dist.put(w, 0);
  lit.put(w, 256);
  EXPECT_EQ(decode_ok(w.bytes()), Bytes(259, 'z'));
}

TEST(Inflate, MatchReachingBackAcrossBlocks) {
  const auto lit = fixed_lit_code();
  const auto dist = fixed_dist_code();
  BitWriter w;
  stored_block(w, bytes_of("0123456789"), false);
  w.bits(1, 1);
  w.bits(1, 2);
  put_match(w, lit, dist, 10, 10);
  lit.put(w, 256);
  EXPECT_EQ(decode_ok(w.bytes()), bytes_of("01234567890123456789"));
}

TEST(Inflate, MaximumDistance) {
  Bytes prefix(32768);
  for (size_t i = 0; i < prefix.size(); ++i) prefix[i] = static_cast<std::uint8_t>(i * 7 + i / 256);
  BitWriter w;
  stored_block(w, prefix, false);
  const auto lit = fixed_lit_code();
  const auto dist = fixed_dist_code();
  w.bits(1, 1);
  w.bits(1, 2);
  put_match(w, lit, dist, 258, 32768);
  lit.put(w, 256);
  Bytes expect = prefix;
  expect.insert(expect.end(), prefix.begin(), prefix.begin() + 258);
  EXPECT_EQ(decode_ok(w.bytes()), expect);
}

TEST(Inflate, DynamicBlockLiteralTokens) {
  // Literal/length code: 'a'=1 bit, 'b'=2, EOB=2; distance: one 1-bit code.
  const auto lens = abc_lit_lengths();
  const std::vector<unsigned> dl{1};
  BitWriter w;
  dynamic_header(w, true, 0, 0, flat_cl_lengths(),
                 literal_tokens(concat(lens, dl)));
  Code lit(lens);
  lit.put(w, 'a');
  lit.put(w, 'b');
  lit.put(w, 'a');
  lit.put(w, 256);
  EXPECT_EQ(decode_ok(w.bytes()), bytes_of("aba"));
}

TEST(Inflate, DynamicBlockWithRepeatCodesAndNoDistances) {
  // Code-length code: symbol 0 -> 2 bits, 1 -> 2, 2 -> 3, 16/17/18 -> 3 (complete).
  std::vector<unsigned> cl(19, 0);
  cl[0] = 2; cl[1] = 2; cl[2] = 3; cl[16] = 3; cl[17] = 3; cl[18] = 3;
  std::vector<ClToken> t;
  t.push_back({18, 97 - 11});   // symbols 0..96: 97 zeros
  t.push_back({1, 0});          // 'a' (97): length 1
  t.push_back({2, 0});          // 'b' (98): length 2
  t.push_back({18, 138 - 11});  // 99..236
  t.push_back({17, 10 - 3});    // 237..246
  t.push_back({17, 9 - 3});     // 247..255
  t.push_back({2, 0});          // 256: length 2
  t.push_back({0, 0});          // the single distance length: 0 (no distances)
  BitWriter w;
  dynamic_header(w, true, 0, 0, cl, t);
  Code lit(abc_lit_lengths());
  lit.put(w, 'b');
  lit.put(w, 'a');
  lit.put(w, 256);
  EXPECT_EQ(decode_ok(w.bytes()), bytes_of("ba"));
}

TEST(Inflate, RepeatPreviousLengthRunsAcrossLiteralDistanceBoundary) {
  // Literal/length lengths: 'a','b',256,257 all 2 bits (complete). The last
  // one is repeated by code 16 into the distance part, giving four 2-bit
  // distance codes (also complete).
  std::vector<unsigned> cl(19, 0);
  cl[2] = 1; cl[16] = 2; cl[18] = 2;
  std::vector<ClToken> t;
  t.push_back({18, 97 - 11});
  t.push_back({2, 0});          // 'a'
  t.push_back({2, 0});          // 'b'
  t.push_back({18, 138 - 11});  // 99..236
  t.push_back({18, 19 - 11});   // 237..255: needs 19 zeros
  t.push_back({2, 0});          // 256
  t.push_back({2, 0});          // 257
  t.push_back({16, 0});         // 3 more 2s: distance symbols 0..2
  t.push_back({2, 0});          // distance symbol 3
  BitWriter w;
  dynamic_header(w, true, 1, 3, cl, t);
  std::vector<unsigned> ll(258, 0);
  ll[97] = ll[98] = ll[256] = ll[257] = 2;
  Code lit(ll);
  Code dist(std::vector<unsigned>{2, 2, 2, 2});
  lit.put(w, 'a');
  lit.put(w, 'b');
  lit.put(w, 257);  // length 3
  dist.put(w, 1);   // distance 2
  lit.put(w, 256);
  EXPECT_EQ(decode_ok(w.bytes()), bytes_of("ababa"));
}

TEST(Inflate, SingleOneBitDistanceCode) {
  const auto lens = abc_lit_lengths();
  std::vector<unsigned> ll = lens;
  ll.push_back(0);  // 258 entries so that symbol 257 exists
  ll[97] = 2; ll[98] = 2; ll[256] = 2; ll[257] = 2;
  BitWriter w;
  dynamic_header(w, true, 1, 0, flat_cl_lengths(), literal_tokens(concat(ll, {1})));
  Code lit(ll);
  lit.put(w, 'a');
  lit.put(w, 257);
  w.bits(0, 1);  // the only distance code, "0" -> distance 1
  lit.put(w, 256);
  EXPECT_EQ(decode_ok(w.bytes()), bytes_of("aaaa"));
}

TEST(Inflate, ZlibDynamicBlock) {
  std::string text;
  for (int i = 0; i < 60; ++i) text += "line " + std::to_string(i) + ": " + std::to_string(i * i) + "\n";
  const char* hex =
      "3d92cb71c4300c43efa94225883fc9523f39646667fb3f06b005df6853241e097efebebfadefd67f3e8c6c377b22"
      "df2d9f28765b4f94c88e27acddbc9e70ec16e7ef44d1797bed364e83b5db75ba1aa4ac4b8c6aae0c042d4f850595"
      "4e27a3ec3a0a466129db20853210f74b35900f57b74542cd05821481832053198e7c9d1a0741f9e9e620a879741c"
      "0443040e82f1664030df1a10ccb71b57209d00c112418060892db8832eece012ba260a6ec1346c1457278a18fcd2"
      "8a021816da5e5cf75ed5132056da79d28d2194a41d434e2559a62c4cb25cf2366f47647ad2922e96a427a633499a"
      "e25d7560f1e8ea0916cf7ef4aad34bb114587cbc39b0f8545d058d56cf028baff72cc1122f4bf1344d9c35ef9b50"
      "1d2f24345ff14412b3ff03";
  EXPECT_EQ(decode_ok(from_hex(hex)), bytes_of(text));
}

TEST(Inflate, ZlibFixedBlock) {
  const std::string unit =
      "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age "
      "of foolishness. ";
  const char* hex =
      "f32c51284f2c5628c94855484a2d2e51c84f5328c9cc4d2dd651c844c894e717e1924a4c4f0549946716a7e4e762"
      "9349cbcfcfc92ccec84b2d2ed653f01cc6b60100";
  EXPECT_EQ(decode_ok(from_hex(hex)), bytes_of(unit + unit + unit));
}

TEST(Inflate, LargeOutputManyLiteralsAndMatches) {
  const auto lit = fixed_lit_code();
  const auto dist = fixed_dist_code();
  BitWriter w;
  w.bits(1, 1);
  w.bits(1, 2);
  Bytes expect;
  for (int i = 0; i < 100000; ++i) {
    lit.put(w, static_cast<unsigned>(i % 251));
    expect.push_back(static_cast<std::uint8_t>(i % 251));
  }
  for (int i = 0; i < 1000; ++i) {
    put_match(w, lit, dist, 258, 1 + (i * 97) % 30000);
    const size_t d = 1 + (i * 97) % 30000;
    for (int k = 0; k < 258; ++k) expect.push_back(expect[expect.size() - d]);
  }
  lit.put(w, 256);
  EXPECT_EQ(decode_ok(w.bytes()), expect);
}

TEST(Inflate, TrailingBitsInLastByteAreIgnored) {
  // "0300" has 7 bits of block data in the second byte; set the padding bits.
  EXPECT_EQ(decode_ok(from_hex("03fc")), Bytes{});
}

TEST(Inflate, OutputLimit) {
  inflate::Options opt;
  opt.max_output = 4;
  EXPECT_EQ(inflate::inflate(from_hex("4b4c4a862000"), opt).error, Error::OutputLimitExceeded);
  opt.max_output = 9;
  EXPECT_TRUE(inflate::inflate(from_hex("4b4c4a862000"), opt).ok());
  BitWriter w;
  stored_block(w, bytes_of("hello"), true);
  opt.max_output = 4;
  EXPECT_EQ(inflate::inflate(w.bytes(), opt).error, Error::OutputLimitExceeded);
}

TEST(Inflate, ErrorStringsAreNonEmpty) {
  EXPECT_STRNE(inflate::to_string(Error::TruncatedInput), "");
  EXPECT_STRNE(inflate::to_string(Error::TrailingData), "unknown error");
}
