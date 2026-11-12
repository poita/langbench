#include <gtest/gtest.h>

#include <string>

#include "webhooks/base64.hpp"
#include "webhooks/hex.hpp"

using namespace webhooks;

TEST(Base64Encode, Standard) {
  EXPECT_EQ(base64_encode(as_bytes("")), "");
  EXPECT_EQ(base64_encode(as_bytes("f")), "Zg==");
  EXPECT_EQ(base64_encode(as_bytes("fo")), "Zm8=");
  EXPECT_EQ(base64_encode(as_bytes("foo")), "Zm9v");
  EXPECT_EQ(base64_encode(as_bytes("foobar")), "Zm9vYmFy");
  EXPECT_EQ(base64_encode(Bytes{0xfb, 0xff}), "+/8=");
}

TEST(Base64Encode, UrlSafeHasNoPadding) {
  EXPECT_EQ(base64url_encode(as_bytes("f")), "Zg");
  EXPECT_EQ(base64url_encode(as_bytes("fo")), "Zm8");
  EXPECT_EQ(base64url_encode(Bytes{0xfb, 0xff}), "-_8");
}

TEST(Base64Decode, ValidForms) {
  EXPECT_EQ(*base64_decode(""), Bytes{});
  EXPECT_EQ(as_text(*base64_decode("Zm9v")), "foo");
  EXPECT_EQ(as_text(*base64_decode("Zm8=")), "fo");
  EXPECT_EQ(as_text(*base64_decode("Zm8")), "fo");  // padding optional
  EXPECT_EQ(*base64_decode("-_8"), (Bytes{0xfb, 0xff}));
  EXPECT_EQ(*base64_decode("+/8="), (Bytes{0xfb, 0xff}));
}

TEST(Base64Decode, TrailingBitsAreIgnored) {
  EXPECT_EQ(*base64_decode("QQ=="), Bytes{0x41});
  EXPECT_EQ(*base64_decode("QR=="), Bytes{0x41});
}

TEST(Base64Decode, RejectsInvalid) {
  EXPECT_FALSE(base64_decode("Z"));         // length 1 mod 4
  EXPECT_FALSE(base64_decode("Zm9vY"));     // length 1 mod 4
  EXPECT_FALSE(base64_decode("Zm9v="));     // nothing to pad
  EXPECT_FALSE(base64_decode("Zg="));       // wrong padding count
  EXPECT_FALSE(base64_decode("Zm8=="));     // wrong padding count
  EXPECT_FALSE(base64_decode("Zg==="));     // p > 2
  EXPECT_FALSE(base64_decode("="));
  EXPECT_FALSE(base64_decode("Z=g="));      // '=' in the middle
  EXPECT_FALSE(base64_decode("+-8="));      // mixed alphabets
  EXPECT_FALSE(base64_decode("_/8"));       // mixed alphabets
  EXPECT_FALSE(base64_decode("Zm 9v"));     // whitespace
  EXPECT_FALSE(base64_decode("Zm9v\n"));
  EXPECT_FALSE(base64_decode("Zm9\xc3\xa9"));
}

TEST(Base64, RoundTripAllLengths) {
  Bytes data;
  for (int len = 0; len < 100; ++len) {
    EXPECT_EQ(*base64_decode(base64_encode(data)), data);
    EXPECT_EQ(*base64_decode(base64url_encode(data)), data);
    data.push_back(static_cast<std::uint8_t>(len * 37 + 11));
  }
}
