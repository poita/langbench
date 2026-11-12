#include <gtest/gtest.h>

#include "sqlitefile/value.hpp"

using namespace sqlitefile;

TEST(Compare, StorageClassOrder) {
  EXPECT_LT(compare(Value::null(), Value::integer(-5)), 0);
  EXPECT_LT(compare(Value::real(1e300), Value::text("")), 0);
  EXPECT_LT(compare(Value::text("zzz"), Value::blob("")), 0);
  EXPECT_EQ(compare(Value::null(), Value::null()), 0);
}

TEST(Compare, NumbersByValueAcrossClasses) {
  EXPECT_EQ(compare(Value::integer(2), Value::real(2.0)), 0);
  EXPECT_LT(compare(Value::integer(2), Value::real(2.5)), 0);
  EXPECT_GT(compare(Value::real(-1.5), Value::integer(-2)), 0);
}

TEST(Compare, IntegersAreExactPastTwoToThe53) {
  Value a = Value::integer(9223372036854775807);
  Value b = Value::integer(9223372036854775806);
  EXPECT_GT(compare(a, b), 0);
  EXPECT_NE(compare(a, b), 0);
}

TEST(Compare, TextAndBlobUseUnsignedBytes) {
  EXPECT_LT(compare(Value::text("a"), Value::text("ab")), 0);
  EXPECT_LT(compare(Value::text("Z"), Value::text("a")), 0);
  // U+00E9 (0xC3 0xA9) sorts after ASCII 'z' as unsigned bytes.
  EXPECT_GT(compare(Value::text("\xC3\xA9"), Value::text("z")), 0);
  EXPECT_GT(compare(Value::blob(std::string("\xff", 1)), Value::blob(std::string("\x01", 1))), 0);
  EXPECT_LT(compare(Value::blob(""), Value::blob(std::string("\0", 1))), 0);
}

TEST(FormatReal, SpecTable) {
  struct { double v; const char* s; } cases[] = {
      {1.0, "1.0"},          {0.1, "0.1"},        {-3.25, "-3.25"},
      {1.0 / 3, "0.333333333333333"},             {1e300, "1.0e+300"},
      {2.5e-10, "2.5e-10"},  {1.5e16, "1.5e+16"}, {1e14, "100000000000000.0"},
      {1e15, "1.0e+15"},     {0.0001, "0.0001"},  {1e-5, "1.0e-05"},
      {0.0, "0.0"},          {-0.0, "0.0"},
  };
  for (auto& c : cases) EXPECT_EQ(formatReal(c.v), c.s) << c.s;
}

TEST(Format, AllClasses) {
  EXPECT_EQ(format(Value::null()), "NULL");
  EXPECT_EQ(format(Value::integer(-42)), "-42");
  EXPECT_EQ(format(Value::integer(INT64_MIN)), "-9223372036854775808");
  EXPECT_EQ(format(Value::text("h\xC3\xA9")), "h\xC3\xA9");
  EXPECT_EQ(format(Value::blob(std::string("\x00\x0a\xff", 3))), "000AFF");
  EXPECT_EQ(format(Value::blob("")), "");
}

TEST(Affinity, RulesApplyInOrder) {
  EXPECT_EQ(affinityFromDeclaredType("INTEGER"), Affinity::Integer);
  EXPECT_EQ(affinityFromDeclaredType("POINT"), Affinity::Integer);
  EXPECT_EQ(affinityFromDeclaredType("FLOATING POINT"), Affinity::Integer);
  EXPECT_EQ(affinityFromDeclaredType("STRING"), Affinity::Numeric);
  EXPECT_EQ(affinityFromDeclaredType("INT TEXT"), Affinity::Integer);
  EXPECT_EQ(affinityFromDeclaredType("CHARFLOA"), Affinity::Text);
  EXPECT_EQ(affinityFromDeclaredType("BLOBREAL"), Affinity::Blob);
  EXPECT_EQ(affinityFromDeclaredType(""), Affinity::Blob);
  EXPECT_EQ(affinityFromDeclaredType("nvarchar(160)"), Affinity::Text);
  EXPECT_EQ(affinityFromDeclaredType("NUMERIC(10,2)"), Affinity::Numeric);
  EXPECT_EQ(affinityFromDeclaredType("double"), Affinity::Real);
  EXPECT_EQ(affinityFromDeclaredType("DATETIME"), Affinity::Numeric);
}

TEST(NumericConstant, Accepts) {
  EXPECT_EQ(*parseNumericConstant(".5"), Value::real(0.5));
  EXPECT_EQ(*parseNumericConstant("-.5"), Value::real(-0.5));
  EXPECT_EQ(*parseNumericConstant("5."), Value::real(5.0));
  EXPECT_EQ(*parseNumericConstant(" 5 "), Value::integer(5));
  EXPECT_EQ(*parseNumericConstant("\t+7\t"), Value::integer(7));
  EXPECT_EQ(*parseNumericConstant("+5e0"), Value::real(5.0));
  EXPECT_EQ(*parseNumericConstant("9223372036854775807"), Value::integer(INT64_MAX));
  EXPECT_EQ(*parseNumericConstant("-9223372036854775808"), Value::integer(INT64_MIN));
  EXPECT_EQ(parseNumericConstant("9223372036854775808")->type(), Type::Real);
}

TEST(NumericConstant, Rejects) {
  for (const char* s : {"", "-", ".", "0x10", "inf", "5 x", "1e", "1e+", "--1", "1 2", "5\n"})
    EXPECT_FALSE(parseNumericConstant(s).has_value()) << s;
}

TEST(LiteralAffinity, ConvertsPerColumnAffinity) {
  EXPECT_EQ(applyAffinityToLiteral(Value::integer(5), Affinity::Text), Value::text("5"));
  EXPECT_EQ(applyAffinityToLiteral(Value::real(1.0), Affinity::Text), Value::text("1.0"));
  EXPECT_EQ(applyAffinityToLiteral(Value::text("5"), Affinity::Integer), Value::integer(5));
  EXPECT_EQ(applyAffinityToLiteral(Value::text("5"), Affinity::Real), Value::integer(5));
  EXPECT_EQ(applyAffinityToLiteral(Value::text("5x"), Affinity::Numeric), Value::text("5x"));
  EXPECT_EQ(applyAffinityToLiteral(Value::text("5"), Affinity::Blob), Value::text("5"));
  EXPECT_EQ(applyAffinityToLiteral(Value::integer(5), Affinity::Blob), Value::integer(5));
  EXPECT_EQ(applyAffinityToLiteral(Value::null(), Affinity::Text), Value::null());
  EXPECT_EQ(applyAffinityToLiteral(Value::blob("5"), Affinity::Integer), Value::blob("5"));
}
