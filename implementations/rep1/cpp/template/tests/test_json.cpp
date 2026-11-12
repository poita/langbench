#include <gtest/gtest.h>

#include "jinjalite/json.hpp"

using namespace jinjalite;

TEST(Json, Scalars) {
  EXPECT_TRUE(parse_json("null").is_none());
  EXPECT_TRUE(parse_json("true").as_bool());
  EXPECT_EQ(parse_json("12").as_int(), 12);
  EXPECT_EQ(parse_json("-0").as_int(), 0);
  EXPECT_TRUE(parse_json("1.0").is_float());
  EXPECT_TRUE(parse_json("1e2").is_float());
  EXPECT_DOUBLE_EQ(parse_json("1E-2").as_float(), 0.01);
}

TEST(Json, StringEscapes) {
  EXPECT_EQ(parse_json(R"("a\n\t\"\\\/")").as_string(), "a\n\t\"\\/");
  EXPECT_EQ(parse_json(R"("é")").as_string(), "\xc3\xa9");
  EXPECT_EQ(parse_json(R"("😀")").as_string(), "\xf0\x9f\x98\x80");
  EXPECT_EQ(parse_json("\"h\xc3\xa9\"").as_string(), "h\xc3\xa9");
}

TEST(Json, ObjectOrderIsPreserved) {
  Value v = parse_json(R"({"z": 1, "a": [1, 2], "m": {"x": null}})");
  ASSERT_TRUE(v.is_dict());
  EXPECT_EQ(v.as_dict().entries()[0].first, "z");
  EXPECT_EQ(v.as_dict().entries()[1].first, "a");
  EXPECT_EQ(v.as_dict().entries()[2].first, "m");
  EXPECT_EQ(v.as_dict().find("a")->as_list().size(), 2u);
}

TEST(Json, MultiLineDocument) {
  Value v = parse_json("{\n  \"a\": 1,\n  \"b\": [\n 2 ]\n}\n");
  EXPECT_EQ(v.as_dict().find("b")->as_list()[0].as_int(), 2);
}

TEST(Json, Malformed) {
  for (const char* bad : {"", "{", "[1,]", "{\"a\" 1}", "01", "1.", "\"abc", "tru", "{} x", "-"}) {
    EXPECT_THROW(parse_json(bad), JsonError) << bad;
  }
}
