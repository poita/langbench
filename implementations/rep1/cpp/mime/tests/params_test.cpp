#include <gtest/gtest.h>

#include "mime/params.hpp"

using namespace mime;

namespace {
std::string filename(const std::string& params) {
  return parse_structured("x/y; " + params).param("filename").value_or("<none>");
}
}  // namespace

TEST(Params, FirstSegment) {
  EXPECT_EQ(parse_structured("  Text/HTML ; a=b").value, "text/html");
}

TEST(Params, Rfc2231Examples) {
  EXPECT_EQ(filename("filename=\"report.pdf\""), "report.pdf");
  EXPECT_EQ(filename("filename*=utf-8''a%C3%A9.txt"), "a\xc3\xa9.txt");
  EXPECT_EQ(filename("filename*0=\"long\"; filename*1=\"name.txt\""), "longname.txt");
  EXPECT_EQ(filename("filename*0*=utf-8''a%C3%A9; filename*1=\".txt\""), "a\xc3\xa9.txt");
  EXPECT_EQ(filename("filename=\"=?utf-8?Q?a=C3=A9.txt?=\""), "a\xc3\xa9.txt");
  EXPECT_EQ(filename("filename=two words.bin"), "two words.bin");
  EXPECT_EQ(filename("filename*=''caf%E9.txt"), "caf\xef\xbf\xbd.txt");
  EXPECT_EQ(filename("filename*0=a; filename*2=c; filename*10=j"), "acj");
  EXPECT_EQ(filename("filename=\"a\\\\\"; x=1"), "a\\");
}

TEST(Params, Precedence) {
  EXPECT_EQ(filename("filename=plain; filename*=utf-8''ext"), "ext");
  EXPECT_EQ(filename("filename*=utf-8''ext; filename*0=num"), "num");
  EXPECT_EQ(filename("filename*0=a; filename*00=b"), "a");
  EXPECT_EQ(filename("filename*1=a; filename*1*=b"), "a");
  EXPECT_EQ(filename("filename=one; filename=two"), "one");
  EXPECT_EQ(filename("filename*07=z"), "z");
}

TEST(Params, QuotesAndSemicolons) {
  StructuredValue v = parse_structured("multipart/mixed; boundary=\"a;b\"; x");
  EXPECT_EQ(v.param("boundary"), "a;b");
  EXPECT_FALSE(v.param("x"));
  EXPECT_EQ(parse_structured("a; b=\"unterminated; c=d").param("b"), "unterminated; c=d");
  EXPECT_EQ(parse_structured("a; (b)=(c)").param("(b)"), "(c)");
}

TEST(Params, StarNamesAreLiteralWhenMalformed) {
  StructuredValue v = parse_structured("a; *0=x; *=y");
  EXPECT_EQ(v.param("*0"), "x");
  EXPECT_EQ(v.param("*"), "y");
}
