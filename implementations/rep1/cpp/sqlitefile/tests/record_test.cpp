#include <gtest/gtest.h>

#include "db_builder.hpp"
#include "sqlitefile/error.hpp"
#include "sqlitefile/record.hpp"

using namespace sqlitefile;
using testsupport::Bytes;

TEST(Varint, RoundTripsEveryWidth) {
  const std::int64_t values[] = {0,           1,           127,         128,
                                 16383,       16384,       (1LL << 21) - 1, 1LL << 21,
                                 1LL << 35,   (1LL << 56) - 1, 1LL << 56,   INT64_MAX,
                                 -1,          -2,          INT64_MIN};
  for (std::int64_t v : values) {
    Bytes b;
    testsupport::appendVarint(b, v);
    std::int64_t out = 0;
    std::size_t end = readVarint(ByteView(b), 0, out);
    EXPECT_EQ(out, v);
    EXPECT_EQ(end, b.size());
  }
}

TEST(Varint, NegativeNeedsNineBytes) {
  Bytes b;
  testsupport::appendVarint(b, -1);
  EXPECT_EQ(b.size(), 9u);
}

TEST(Varint, KnownEncodings) {
  Bytes b = {0x81, 0x00};
  std::int64_t v;
  EXPECT_EQ(readVarint(ByteView(b), 0, v), 2u);
  EXPECT_EQ(v, 128);
}

TEST(Varint, TruncatedThrows) {
  Bytes b = {0x81};
  std::int64_t v;
  EXPECT_THROW(readVarint(ByteView(b), 0, v), FormatError);
}

TEST(Record, DecodesEverySerialType) {
  Bytes rec = {
      // header: size 13, types 0,1,2,3,4,5,6,7,8,9,text(2),blob(1)
      13, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 17, 14,
      // body
      0xff,                          // 1: -1
      0xff, 0xfe,                    // 2: -2
      0x80, 0x00, 0x00,              // 3: -8388608
      0x00, 0x00, 0x01, 0x00,        // 4: 256
      0xff, 0xff, 0xff, 0xff, 0xff, 0xfd,  // 5: -3
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,  // 6: 1<<32
      0x3f, 0xf8, 0, 0, 0, 0, 0, 0,  // 7: 1.5
      'h', 'i',                      // text
      0x7f};                         // blob
  auto v = decodeRecord(ByteView(rec));
  ASSERT_EQ(v.size(), 12u);
  EXPECT_TRUE(v[0].isNull());
  EXPECT_EQ(v[1], Value::integer(-1));
  EXPECT_EQ(v[2], Value::integer(-2));
  EXPECT_EQ(v[3], Value::integer(-8388608));
  EXPECT_EQ(v[4], Value::integer(256));
  EXPECT_EQ(v[5], Value::integer(-3));
  EXPECT_EQ(v[6], Value::integer(1LL << 32));
  EXPECT_EQ(v[7], Value::real(1.5));
  EXPECT_EQ(v[8], Value::integer(0));
  EXPECT_EQ(v[9], Value::integer(1));
  EXPECT_EQ(v[10], Value::text("hi"));
  EXPECT_EQ(v[11], Value::blob(std::string("\x7f", 1)));
}

TEST(Record, EncoderAndDecoderAgree) {
  std::vector<Value> in = {Value::null(),    Value::integer(0),        Value::integer(1),
                           Value::integer(-129), Value::integer(70000), Value::integer(INT64_MIN),
                           Value::real(-0.25), Value::text(""),         Value::text("é"),
                           Value::blob("")};
  auto out = decodeRecord(ByteView(testsupport::encodeRecord(in)));
  EXPECT_EQ(out, in);
}

TEST(Record, MaxColumnsStopsEarly) {
  auto bytes = testsupport::encodeRecord({Value::integer(7), Value::text("x"), Value::integer(9)});
  auto v = decodeRecord(ByteView(bytes), 2);
  ASSERT_EQ(v.size(), 2u);
  EXPECT_EQ(v[1], Value::text("x"));
}

TEST(Record, MalformedThrows) {
  Bytes bad_header = {5, 1};          // header claims 5 bytes, record has 2
  EXPECT_THROW(decodeRecord(ByteView(bad_header)), FormatError);
  Bytes short_body = {2, 6, 0, 0};    // 8-byte integer, 2 body bytes
  EXPECT_THROW(decodeRecord(ByteView(short_body)), FormatError);
  Bytes reserved = {2, 10};
  EXPECT_THROW(decodeRecord(ByteView(reserved)), FormatError);
}
