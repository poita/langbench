#include <gtest/gtest.h>

#include "mime/header.hpp"

using namespace mime;

TEST(Header, FoldingAndBody) {
  std::string msg = "Subject: a\n b\n\tc\nTo: x\n\nbody\n";
  HeaderBlock hb = parse_headers(msg);
  ASSERT_EQ(hb.fields.size(), 2u);
  EXPECT_EQ(hb.fields[0].name, "Subject");
  EXPECT_EQ(hb.fields[0].raw_value, " a b\tc");
  EXPECT_EQ(msg.substr(hb.body_offset), "body\n");
}

TEST(Header, NonFieldLineEndsBlock) {
  for (const char* bad : {"Subject :x", "no colon here", ": novalue",
                          "From nobody Mon Sep  1 00:00:00 2025"}) {
    std::string msg = std::string("A: 1\n") + bad + "\nrest\n";
    HeaderBlock hb = parse_headers(msg);
    EXPECT_EQ(hb.fields.size(), 1u) << bad;
    EXPECT_EQ(msg.substr(hb.body_offset), std::string(bad) + "\nrest\n") << bad;
  }
}

TEST(Header, LeadingBlankOnFirstLineEndsBlock) {
  HeaderBlock hb = parse_headers(" a: b\nrest");
  EXPECT_TRUE(hb.fields.empty());
  EXPECT_EQ(hb.body_offset, 0u);
}

TEST(Header, HeadersOnlyAndEmpty) {
  EXPECT_EQ(parse_headers("A: 1").body_offset, 4u);
  EXPECT_TRUE(parse_headers("").fields.empty());
  EXPECT_EQ(parse_headers("\nbody").body_offset, 1u);
}

TEST(Header, InvalidUtf8IsReplaced) {
  HeaderBlock hb = parse_headers("A: \xff\n\n");
  EXPECT_EQ(hb.fields[0].raw_value, " \xef\xbf\xbd");
}

TEST(Header, FindFieldAndDisplayValue) {
  HeaderBlock hb = parse_headers("X-A: 1\nSubject:  =?utf-8?Q?a?=  \nsubject: 2\nContent-Type:  a   b \n\n");
  const HeaderField* f = find_field(hb.fields, "subject");
  ASSERT_NE(f, nullptr);
  EXPECT_EQ(display_value(*f), "a");
  EXPECT_EQ(display_value(*find_field(hb.fields, "content-type")), "a b");
  EXPECT_EQ(find_field(hb.fields, "nope"), nullptr);
}
