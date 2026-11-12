// Malformed streams: each is otherwise well-formed, so a decoder that skips
// the check in question would produce output instead of an error.

#include <gtest/gtest.h>

#include "test_support.hpp"

using namespace testing_support;
using inflate::Error;

namespace {

Error error_of(const Bytes& stream) { return inflate::inflate(stream).error; }

BitWriter dynamic_stream(unsigned hlit, unsigned hdist, const std::vector<unsigned>& cl,
                         const std::vector<ClToken>& tokens, unsigned hclen_count = 19) {
  BitWriter w;
  dynamic_header(w, true, hlit, hdist, cl, tokens, hclen_count);
  return w;
}

}  // namespace

TEST(Errors, EmptyStream) { EXPECT_EQ(error_of({}), Error::TruncatedInput); }

TEST(Errors, SpecExampleDistanceBeforeAnyOutput) {
  EXPECT_EQ(error_of(from_hex("030200")), Error::DistanceTooFar);
}

TEST(Errors, EndsAfterNonFinalBlock) {
  EXPECT_EQ(error_of(from_hex("0200")), Error::TruncatedInput);  // non-final empty fixed block
}

TEST(Errors, EndsInsideBlockHeader) {
  EXPECT_EQ(error_of(from_hex("04")), Error::TruncatedInput);  // dynamic header cut after BTYPE
  // A non-final fixed block ending 2 bits before a byte boundary (3 + 4*9 + 7
  // = 46 bits), so only 2 bits remain for the next 3-bit header.
  const auto lit = fixed_lit_code();
  BitWriter w;
  w.bits(0, 1);
  w.bits(1, 2);
  for (unsigned c = 144; c < 148; ++c) lit.put(w, c);
  lit.put(w, 256);
  ASSERT_EQ(w.bytes().size(), 6u);
  EXPECT_EQ(error_of(w.bytes()), Error::TruncatedInput);
}

TEST(Errors, BlockType3) { EXPECT_EQ(error_of(from_hex("07")), Error::InvalidBlockType); }

TEST(Errors, StoredLengthMismatch) {
  EXPECT_EQ(error_of(from_hex("010100fefe41")), Error::StoredLengthMismatch);
}

TEST(Errors, StoredTruncated) {
  EXPECT_EQ(error_of(from_hex("0101")), Error::TruncatedInput);        // inside LEN
  EXPECT_EQ(error_of(from_hex("01010000")), Error::TruncatedInput);    // inside NLEN
  EXPECT_EQ(error_of(from_hex("010300fcff4142")), Error::TruncatedInput);  // inside data
}

TEST(Errors, TruncatedInsideHuffmanCode) {
  const auto lit = fixed_lit_code();
  BitWriter w;
  w.bits(1, 1);
  w.bits(1, 2);
  lit.put(w, 'a');
  lit.put(w, 256);  // 18 bits -> 3 bytes
  Bytes b = w.bytes();
  ASSERT_EQ(b.size(), 3u);
  EXPECT_EQ(error_of(b), Error::None);
  b.pop_back();  // 16 bits: the end-of-block code is cut after 5 of 7 bits
  EXPECT_EQ(error_of(b), Error::TruncatedInput);
}

TEST(Errors, TruncatedInsideExtraBits) {
  // Six 9-bit literals + length symbol 265 (7-bit code) end exactly on a byte
  // boundary (3 + 54 + 7 = 64 bits), leaving its one extra bit missing.
  const auto lit = fixed_lit_code();
  BitWriter w;
  w.bits(1, 1);
  w.bits(1, 2);
  for (unsigned c = 144; c < 150; ++c) lit.put(w, c);
  lit.put(w, 265);
  ASSERT_EQ(w.bytes().size(), 8u);
  EXPECT_EQ(error_of(w.bytes()), Error::TruncatedInput);
}

TEST(Errors, TooManyLengthOrDistanceCodes) {
  BitWriter w;
  w.bits(1, 1);
  w.bits(2, 2);
  w.bits(30, 5);  // HLIT = 30
  w.bits(0, 5);
  w.bits(0, 4);
  for (int i = 0; i < 100; ++i) w.bits(0, 8);
  EXPECT_EQ(error_of(w.bytes()), Error::TooManyCodes);
  BitWriter v;
  v.bits(1, 1);
  v.bits(2, 2);
  v.bits(0, 5);
  v.bits(30, 5);  // HDIST = 30
  v.bits(0, 4);
  for (int i = 0; i < 100; ++i) v.bits(0, 8);
  EXPECT_EQ(error_of(v.bytes()), Error::TooManyCodes);
}

TEST(Errors, CodeLengthCodeNotComplete) {
  std::vector<unsigned> cl(19, 0);
  cl[0] = 1;  // incomplete
  auto w = dynamic_stream(0, 0, cl, {});
  EXPECT_EQ(error_of(w.bytes()), Error::InvalidCodeLengthCode);
  cl.assign(19, 0);
  cl[0] = cl[1] = cl[2] = 1;  // over-subscribed
  w = dynamic_stream(0, 0, cl, {});
  EXPECT_EQ(error_of(w.bytes()), Error::InvalidCodeLengthCode);
  cl.assign(19, 0);  // empty
  w = dynamic_stream(0, 0, cl, {});
  EXPECT_EQ(error_of(w.bytes()), Error::InvalidCodeLengthCode);
}

TEST(Errors, RepeatWithNoPreviousLength) {
  std::vector<unsigned> cl(19, 0);
  cl[0] = cl[16] = 1;
  auto w = dynamic_stream(0, 0, cl, {{16, 0}});
  EXPECT_EQ(error_of(w.bytes()), Error::InvalidRepeat);
}

TEST(Errors, RepeatOverflowsLengthCount) {
  std::vector<unsigned> cl(19, 0);
  cl[0] = cl[18] = 1;
  // 258 lengths expected; 138 + 138 = 276 overflows.
  auto w = dynamic_stream(0, 0, cl, {{18, 127}, {18, 127}});
  EXPECT_EQ(error_of(w.bytes()), Error::InvalidRepeat);
}

namespace {
// Spell out literal/length and distance code lengths with a flat code-length code.
Bytes dynamic_with_lengths(const std::vector<unsigned>& lit, const std::vector<unsigned>& dist) {
  BitWriter w;
  dynamic_header(w, true, static_cast<unsigned>(lit.size() - 257),
                 static_cast<unsigned>(dist.size() - 1), flat_cl_lengths(),
                 literal_tokens(concat(lit, dist)));
  return w.bytes();
}
}  // namespace

TEST(Errors, LiteralCodeMissingEndOfBlock) {
  std::vector<unsigned> lit(257, 0);
  lit[0] = lit[1] = 1;  // complete, but symbol 256 unused
  EXPECT_EQ(error_of(dynamic_with_lengths(lit, {1})), Error::InvalidLiteralCode);
}

TEST(Errors, LiteralCodeOverSubscribedOrIncomplete) {
  std::vector<unsigned> lit(257, 0);
  lit[0] = lit[1] = lit[256] = 1;  // over-subscribed
  EXPECT_EQ(error_of(dynamic_with_lengths(lit, {1})), Error::InvalidLiteralCode);
  lit.assign(257, 0);
  lit[0] = 2; lit[256] = 2;  // incomplete (Kraft 1/2)
  EXPECT_EQ(error_of(dynamic_with_lengths(lit, {1})), Error::InvalidLiteralCode);
  lit.assign(257, 0);
  lit[256] = 2;  // single code but of length 2
  EXPECT_EQ(error_of(dynamic_with_lengths(lit, {1})), Error::InvalidLiteralCode);
}

TEST(Errors, DistanceCodeOverSubscribedOrIncomplete) {
  std::vector<unsigned> lit(257, 0);
  lit[0] = 1; lit[256] = 1;  // complete
  EXPECT_EQ(error_of(dynamic_with_lengths(lit, {1, 1, 1})), Error::InvalidDistanceCode);
  EXPECT_EQ(error_of(dynamic_with_lengths(lit, {2, 2, 2})), Error::InvalidDistanceCode);  // incomplete
  EXPECT_EQ(error_of(dynamic_with_lengths(lit, {2})), Error::InvalidDistanceCode);  // single, 2 bits
  EXPECT_EQ(error_of(dynamic_with_lengths(lit, {1, 1, 1, 0})), Error::InvalidDistanceCode);
}

TEST(Errors, SingleLiteralCodeAcceptsOnlyBitZero) {
  std::vector<unsigned> lit(257, 0);
  lit[256] = 1;  // the lone code: "0" = end of block
  BitWriter w;
  dynamic_header(w, true, 0, 0, flat_cl_lengths(), literal_tokens(concat(lit, {0})));
  w.bits(0, 1);
  EXPECT_EQ(error_of(w.bytes()), Error::None);
  BitWriter v;
  dynamic_header(v, true, 0, 0, flat_cl_lengths(), literal_tokens(concat(lit, {0})));
  v.bits(1, 1);  // unassigned pattern
  EXPECT_EQ(error_of(v.bytes()), Error::InvalidCode);
}

TEST(Errors, LengthCodeWithEmptyDistanceSet) {
  std::vector<unsigned> lit(258, 0);
  lit[97] = 1; lit[256] = 2; lit[257] = 2;
  BitWriter w;
  dynamic_header(w, true, 1, 0, flat_cl_lengths(), literal_tokens(concat(lit, {0})));
  Code c(lit);
  c.put(w, 'a');
  c.put(w, 257);
  c.put(w, 256);
  EXPECT_EQ(error_of(w.bytes()), Error::NoDistanceCodes);
}

TEST(Errors, InvalidFixedSymbols) {
  const auto lit = fixed_lit_code();
  const auto dist = fixed_dist_code();
  for (unsigned sym : {286u, 287u}) {
    BitWriter w;
    w.bits(1, 1);
    w.bits(1, 2);
    lit.put(w, sym);
    for (int i = 0; i < 8; ++i) w.bits(0, 8);
    EXPECT_EQ(error_of(w.bytes()), Error::InvalidSymbol) << sym;
  }
  for (unsigned d : {30u, 31u}) {
    BitWriter w;
    w.bits(1, 1);
    w.bits(1, 2);
    lit.put(w, 'a');
    lit.put(w, 257);
    dist.put(w, d);
    lit.put(w, 256);
    EXPECT_EQ(error_of(w.bytes()), Error::InvalidSymbol) << d;
  }
}

TEST(Errors, DistanceBeyondOutput) {
  const auto lit = fixed_lit_code();
  const auto dist = fixed_dist_code();
  BitWriter w;
  w.bits(1, 1);
  w.bits(1, 2);
  lit.put(w, 'a');
  lit.put(w, 'b');
  put_match(w, lit, dist, 3, 3);  // only 2 bytes so far
  lit.put(w, 256);
  EXPECT_EQ(error_of(w.bytes()), Error::DistanceTooFar);
}

TEST(Errors, DistanceBeyondOutputAcrossStoredBlock) {
  const auto lit = fixed_lit_code();
  const auto dist = fixed_dist_code();
  BitWriter w;
  stored_block(w, Bytes(100, 'q'), false);
  w.bits(1, 1);
  w.bits(1, 2);
  put_match(w, lit, dist, 3, 101);
  lit.put(w, 256);
  EXPECT_EQ(error_of(w.bytes()), Error::DistanceTooFar);
}

TEST(Errors, TrailingData) {
  EXPECT_EQ(error_of(from_hex("030000")), Error::TrailingData);
  EXPECT_EQ(error_of(from_hex("010100feff4100")), Error::TrailingData);
}

TEST(Errors, ErrorAfterLargeValidOutput) {
  BitWriter w;
  for (int i = 0; i < 18; ++i) stored_block(w, Bytes(60000, 'x'), false);
  w.bits(1, 1);
  w.bits(3, 2);
  EXPECT_EQ(error_of(w.bytes()), Error::InvalidBlockType);
}
