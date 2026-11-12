#include <gtest/gtest.h>

#include "tessera/command.hpp"
#include "tessera/error.hpp"
#include "tessera/index_key.hpp"
#include "tessera/value.hpp"

using namespace tessera;

static std::string hex(const std::string& s) {
  static const char* d = "0123456789abcdef";
  std::string out;
  for (unsigned char c : s) {
    out += d[c >> 4];
    out += d[c & 15];
  }
  return out;
}

TEST(Value, SerialisationMatchesSpec) {
  EXPECT_EQ(hex(serialize(Value::integer(1))), "030000000000000001");
  EXPECT_EQ(hex(serialize(Value::integer(-1))), "03ffffffffffffffff");
  EXPECT_EQ(hex(serialize(Value::null())), "00");
  EXPECT_EQ(hex(serialize(Value::string("ada"))), "040000000361" "6461");
  Value v = parse_value_literal("{name:\"ada\",age:36,ok:true}");
  EXPECT_EQ(serialize(v).size(), 44u);
  EXPECT_EQ(hex(serialize(v)),
            "0600000003"
            "00000003" "616765" "030000000000000024"
            "00000004" "6e616d65" "0400000003616461"
            "00000002" "6f6b" "02");
}

TEST(Value, RoundTrip) {
  Value v = parse_value_literal("{a:[1,-2,\"x\\u0000y\",null,{b:false}],\"\":{}}");
  EXPECT_EQ(deserialize(serialize(v)), v);
}

TEST(Value, RenderingIsCanonical) {
  EXPECT_EQ(render(parse_value_literal("{name:\"ada\",age:36}")), "{\"age\":36,\"name\":\"ada\"}");
  EXPECT_EQ(render(parse_value_literal("[1,\"x\",null]")), "[1,\"x\",null]");
  EXPECT_EQ(render(parse_value_literal("-9223372036854775808")), "-9223372036854775808");
  EXPECT_EQ(render(parse_value_literal("{}")), "{}");
  EXPECT_EQ(render(parse_value_literal("\"a\\\"b\"")), "\"a\\\"b\"");
}

TEST(Value, StringEscaping) {
  EXPECT_EQ(render_string(std::string("\x01\x7f\b\t\n\f\r/\\", 9)),
            "\"\\u0001\\u007f\\b\\t\\n\\f\\r/\\\\\"");
  EXPECT_EQ(render_string(std::string("a\0b", 3)), "\"a\\u0000b\"");
  EXPECT_EQ(render_string("é😀"), "\"é😀\"");
}

TEST(Value, ObjectsIgnoreFieldOrder) {
  EXPECT_EQ(parse_value_literal("{a:1,b:2}"), parse_value_literal("{b:2,a:1}"));
}

TEST(Value, Depth) {
  EXPECT_EQ(depth(parse_value_literal("1")), 1);
  EXPECT_EQ(depth(parse_value_literal("[]")), 1);
  EXPECT_EQ(depth(parse_value_literal("[[1]]")), 3);
}

TEST(Value, PathAccess) {
  Value doc = parse_value_literal("{a:{b:1},l:[1]}");
  EXPECT_EQ(*resolve_path(doc, {"a", "b"}), Value::integer(1));
  EXPECT_EQ(resolve_path(doc, {"a", "c"}), nullptr);
  EXPECT_EQ(resolve_path(doc, {"l", "0"}), nullptr);

  set_path(doc, {"x", "y"}, Value::integer(2));
  EXPECT_EQ(render(doc), "{\"a\":{\"b\":1},\"l\":[1],\"x\":{\"y\":2}}");
  EXPECT_THROW(set_path(doc, {"a", "b", "c"}, Value::null()), Error);

  unset_path(doc, {"x", "y"});
  EXPECT_EQ(render(doc), "{\"a\":{\"b\":1},\"l\":[1],\"x\":{}}");
  try {
    unset_path(doc, {"zz"});
    FAIL();
  } catch (const Error& e) {
    EXPECT_EQ(e.kind(), ErrorKind::NoField);
  }
}

TEST(IndexKey, MatchesSpecExamples) {
  EXPECT_EQ(hex(*value_key(Value::null())), "10");
  EXPECT_EQ(hex(*value_key(Value::boolean(false))), "20");
  EXPECT_EQ(hex(*value_key(Value::boolean(true))), "21");
  EXPECT_EQ(hex(*value_key(Value::integer(0))), "308000000000000000");
  EXPECT_EQ(hex(*value_key(Value::integer(-1))), "307fffffffffffffff");
  EXPECT_EQ(hex(*value_key(Value::integer(INT64_MIN))), "300000000000000000");
  EXPECT_EQ(hex(*value_key(Value::string(""))), "400000");
  EXPECT_EQ(hex(*value_key(Value::string(std::string("a\0b", 3)))), "406100ff620000");
  EXPECT_FALSE(value_key(Value::list({})));
  EXPECT_FALSE(value_key(Value::object({})));
}

TEST(IndexKey, EntryKeyAndLength) {
  Value doc = parse_value_literal("{age:36}");
  auto k = index_entry_key(doc, {"age"}, "u1");
  ASSERT_TRUE(k);
  EXPECT_EQ(hex(*k), "3080000000000000247531");
  EXPECT_EQ(value_key_length(*k), 9u);
  auto s = index_entry_key(parse_value_literal("{n:\"a\\u0000b\"}"), {"n"}, "k");
  EXPECT_EQ(value_key_length(*s), 7u);
  EXPECT_FALSE(index_entry_key(doc, {"nope"}, "u1"));
}
