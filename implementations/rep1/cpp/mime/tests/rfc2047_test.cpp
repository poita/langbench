#include <gtest/gtest.h>

#include "mime/rfc2047.hpp"

using namespace mime;

TEST(Rfc2047, UnstructuredExamples) {
  EXPECT_EQ(decode_unstructured("=?utf-8?Q?caf=C3=A9?="), "caf\xc3\xa9");
  EXPECT_EQ(decode_unstructured("=?utf-8?Q?a?=   =?utf-8?Q?b?="), "ab");
  EXPECT_EQ(decode_unstructured("x =?utf-8?Q?a?= y"), "x a y");
  EXPECT_EQ(decode_unstructured("=?utf-8?Q?a?=b"), "ab");
  EXPECT_EQ(decode_unstructured("=?iso-8859-1?Q?caf=E9?="), "caf\xc3\xa9");
  EXPECT_EQ(decode_unstructured("=?windows-1252?Q?smart=92quote?="), "smart\xe2\x80\x99quote");
  EXPECT_EQ(decode_unstructured("=?utf-8?B?SsO2cmc=?="), "J\xc3\xb6rg");
  EXPECT_EQ(decode_unstructured("=?utf-8*en?Q?hi?="), "hi");
  EXPECT_EQ(decode_unstructured("=?utf-8?X?hi?="), "=?utf-8?X?hi?=");
  EXPECT_EQ(decode_unstructured("  plain    spaced   text  "), "plain    spaced   text");
  EXPECT_EQ(decode_unstructured("=?utf-8?Q?a?= \t =?utf-8?Q?b?= \t c"), "ab \t c");
}

TEST(Rfc2047, Matching) {
  EXPECT_FALSE(match_encoded_word("=??Q?a?=", 0));
  EXPECT_FALSE(match_encoded_word("=?utf-8?Q?a b?=", 0));
  EXPECT_FALSE(match_encoded_word("=?utf-8?Q?a?b?=", 0));
  auto w = match_encoded_word("x=?utf-8?Q?=41_b=ZZ?=y", 1);
  ASSERT_TRUE(w);
  EXPECT_EQ(w->text, "A b=ZZ");
  EXPECT_EQ(w->end, 21u);
  EXPECT_TRUE(match_encoded_word("=?utf-8?Q?\?=", 0));
}

TEST(Rfc2047, Display) {
  EXPECT_EQ(decode_display("John Q. Public "), "John Q. Public");
  EXPECT_EQ(decode_display("\"Doe, John\" "), "Doe, John");
  EXPECT_EQ(decode_display("=?utf-8?B?SsO2cmc=?= "), "J\xc3\xb6rg");
  EXPECT_EQ(decode_display("John (the third) Public "), "John   Public");
  EXPECT_EQ(decode_display("\"=?utf-8?Q?x?=\" "), "=?utf-8?Q?x?=");
}
