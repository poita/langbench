#include <gtest/gtest.h>

#include "mime/charset.hpp"

using namespace mime;

TEST(Charset, NameNormalisation) { EXPECT_EQ(normalize_charset_name(" \tUTF-8 "), "utf-8"); }

TEST(Charset, Ascii) { EXPECT_EQ(decode("a\xe9", "US-ASCII"), "a\xef\xbf\xbd"); }

TEST(Charset, Latin1AndCp1252) {
  EXPECT_EQ(decode("\xe9", "latin1"), "\xc3\xa9");
  EXPECT_EQ(decode("\x80", "latin1"), "\xc2\x80");
  EXPECT_EQ(decode("\x92", "windows-1252"), "\xe2\x80\x99");
  EXPECT_EQ(decode("\x81", "cp1252"), "\xc2\x81");
  EXPECT_EQ(decode("\x92", ""), "\xe2\x80\x99");
  EXPECT_EQ(decode("\x92", "x-unknown"), "\xe2\x80\x99");
}

TEST(Charset, Utf8Valid) { EXPECT_EQ(decode("caf\xc3\xa9 \xf0\x9f\x98\x80", "utf-8"), "caf\xc3\xa9 \xf0\x9f\x98\x80"); }

TEST(Charset, Utf8MaximalSubpart) {
  const std::string fffd = "\xef\xbf\xbd";
  EXPECT_EQ(decode("\xe2\x28\xa1", "utf-8"), fffd + "(" + fffd);
  EXPECT_EQ(decode("\xf0\x9f", "utf-8"), fffd);
  EXPECT_EQ(decode("\xed\xa0\x80", "utf-8"), fffd + fffd + fffd);
  EXPECT_EQ(decode("\xc0\xaf", "utf-8"), fffd + fffd);
  EXPECT_EQ(decode("\xf4\x90\x80\x80", "utf-8"), fffd + fffd + fffd + fffd);
  EXPECT_EQ(decode("\xe0\x80", "utf-8"), fffd + fffd);
  EXPECT_EQ(decode("\xe1\x80\x41", "utf-8"), fffd + "A");
}

TEST(Charset, CountCodePoints) { EXPECT_EQ(count_code_points("caf\xc3\xa9"), 4u); }
