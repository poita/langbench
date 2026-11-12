#include <gtest/gtest.h>

#include "jinjalite/error.hpp"
#include "jinjalite/format.hpp"
#include "jinjalite/json.hpp"

using namespace jinjalite;

TEST(FormatFloat, Positional) {
  EXPECT_EQ(format_float(3.0), "3.0");
  EXPECT_EQ(format_float(0.5), "0.5");
  EXPECT_EQ(format_float(1000000000000000.0), "1000000000000000.0");
  EXPECT_EQ(format_float(0.0001), "0.0001");
  EXPECT_EQ(format_float(0.1 + 0.2), "0.30000000000000004");
  EXPECT_EQ(format_float(-12.25), "-12.25");
  EXPECT_EQ(format_float(123456.789), "123456.789");
}

TEST(FormatFloat, Scientific) {
  EXPECT_EQ(format_float(1e16), "1e+16");
  EXPECT_EQ(format_float(1e-5), "1e-05");
  EXPECT_EQ(format_float(1.5e300), "1.5e+300");
  EXPECT_EQ(format_float(-2.5e-7), "-2.5e-07");
}

TEST(FormatFloat, Zero) {
  EXPECT_EQ(format_float(0.0), "0.0");
  EXPECT_EQ(format_float(-0.0), "-0.0");
}

TEST(Display, Scalars) {
  EXPECT_EQ(to_display(Value::boolean(true)), "True");
  EXPECT_EQ(to_display(Value::boolean(false)), "False");
  EXPECT_EQ(to_display(Value::none()), "None");
  EXPECT_EQ(to_display(Value::integer(-42)), "-42");
  EXPECT_EQ(to_display(Value::string("a")), "a");
}

TEST(Display, UndefinedThrows) {
  try {
    to_display(Value());
    FAIL();
  } catch (const Error& e) {
    EXPECT_EQ(e.kind(), ErrorKind::Undefined);
  }
}

TEST(Display, ListsAndDictsUseRepr) {
  Value v = parse_json(R"([1, "a", true, null, 1.5, "it's", {"k": [2.0]}])");
  EXPECT_EQ(to_display(v), "[1, 'a', True, None, 1.5, \"it's\", {'k': [2.0]}]");
  EXPECT_EQ(to_display(parse_json("[]")), "[]");
  EXPECT_EQ(to_display(parse_json("{}")), "{}");
}

TEST(Display, StringRepr) {
  Value v = parse_json(R"(["a\\b", "x\ny", "q\"'"])");
  EXPECT_EQ(to_display(v), "['a\\\\b', 'x\\ny', 'q\"\\'']");
}
