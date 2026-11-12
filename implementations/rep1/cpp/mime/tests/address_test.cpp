#include <gtest/gtest.h>

#include "mime/address.hpp"

using namespace mime;

namespace {
std::string show(const std::string& value) {
  std::string out;
  for (const Address& a : parse_address_list(value)) {
    if (!out.empty()) out += " && ";
    out += a.display + "|" + a.spec;
  }
  return out;
}
}  // namespace

TEST(Address, SpecExamples) {
  EXPECT_EQ(show("Real Name <user@example.com>"), "Real Name|user@example.com");
  EXPECT_EQ(show("user@example.com (Real Name)"), "|user@example.com");
  EXPECT_EQ(show("\"Doe, John\" <jd@x.com>"), "Doe, John|jd@x.com");
  EXPECT_EQ(show("a@b.com, (c) d@e.com"), "|a@b.com && |d@e.com");
  EXPECT_EQ(show("Undisclosed recipients:;"), "");
  EXPECT_EQ(show("grp: a@b.com, c@d.com;"), "|a@b.com && |c@d.com");
  EXPECT_EQ(show("=?utf-8?B?SsO2cmc=?= <j@x.de>"), "J\xc3\xb6rg|j@x.de");
  EXPECT_EQ(show("foo (c (nested)) <a@b>"), "foo|a@b");
  EXPECT_EQ(show("ed <a@[10.0.0.1]>"), "ed|a@[10.0.0.1]");
  EXPECT_EQ(show("broken <a@@b>"), "|broken<a@@b>");
  EXPECT_EQ(show("John Q. Public <jqp@example.com>"), "John Q. Public|jqp@example.com");
  EXPECT_EQ(show("Symantec Email Proxy"), "|SymantecEmailProxy");
  EXPECT_EQ(show("\"=?utf-8?Q?x?=\" <a@b>"), "=?utf-8?Q?x?=|a@b");
  EXPECT_EQ(show("a <b <c@d.com> , e@f.com>, g@h.com"), "|a<b<c@d.com>,e@f.com> && |g@h.com");
  EXPECT_EQ(show("John (the third) Public <jqp@x.com>"), "John   Public|jqp@x.com");
}

TEST(Address, EdgeCases) {
  EXPECT_EQ(show(""), "");
  EXPECT_EQ(show(" , ,"), "");
  EXPECT_EQ(show("<a@b>"), "|a@b");
  EXPECT_EQ(show("\"a b\".c@d.e"), "|a b.c@d.e");
  EXPECT_EQ(show("x <>"), "|x<>");
  EXPECT_EQ(show("x <a@b"), "|x<a@b");
  EXPECT_EQ(show("a@b."), "|a@b.");
  EXPECT_EQ(show("local"), "|local");
}
