#include <gtest/gtest.h>

#include "mime/transfer.hpp"

using namespace mime;

TEST(QuotedPrintable, SpecExamples) {
  EXPECT_EQ(decode_quoted_printable("a=20b"), "a b");
  EXPECT_EQ(decode_quoted_printable("a=\nb"), "ab");
  EXPECT_EQ(decode_quoted_printable("a=3Db"), "a=b");
  EXPECT_EQ(decode_quoted_printable("a=Zb"), "a=Zb");
  EXPECT_EQ(decode_quoted_printable("a=3\n"), "a=3\n");
  EXPECT_EQ(decode_quoted_printable("abc="), "abc");
  EXPECT_EQ(decode_quoted_printable("=0D=0A"), "\r\n");
  EXPECT_EQ(decode_quoted_printable("x  \ny"), "x  \ny");
  EXPECT_EQ(decode_quoted_printable("=4"), "=4");
}

TEST(Base64, Basics) {
  EXPECT_EQ(decode_base64("AAECAw=="), std::string("\0\1\2\3", 4));
  EXPECT_EQ(decode_base64("TWFu\nTWE="), "ManMa");
  EXPECT_EQ(decode_base64("TQ"), "M");
  EXPECT_EQ(decode_base64("TWE"), "Ma");
  EXPECT_EQ(decode_base64("TWFuT"), "Man");  // dangling single char dropped
  EXPECT_EQ(decode_base64(""), "");
}

TEST(DecodeBody, Dispatch) {
  EXPECT_EQ(decode_body("a=41", "7bit"), "a=41");
  EXPECT_EQ(decode_body("a=41", "x-weird"), "a=41");
  EXPECT_EQ(decode_body("a=41", "quoted-printable"), "aA");
  EXPECT_EQ(decode_body("YQ==", "base64"), "a");
  EXPECT_TRUE(is_identity_encoding("binary"));
  EXPECT_FALSE(is_identity_encoding("base64"));
}
