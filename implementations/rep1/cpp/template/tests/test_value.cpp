#include <gtest/gtest.h>

#include "jinjalite/value.hpp"

using namespace jinjalite;

TEST(Value, DefaultIsUndefined) {
  Value v;
  EXPECT_TRUE(v.is_undefined());
  EXPECT_EQ(v.kind(), Value::Kind::Undefined);
}

TEST(Value, ScalarsRoundTrip) {
  EXPECT_TRUE(Value::none().is_none());
  EXPECT_TRUE(Value::boolean(true).as_bool());
  EXPECT_EQ(Value::integer(-7).as_int(), -7);
  EXPECT_EQ(Value::real(2.5).as_float(), 2.5);
  EXPECT_EQ(Value::string("héllo").as_string(), "héllo");
}

TEST(Value, BooleansAreIntegral) {
  EXPECT_TRUE(Value::boolean(true).is_integral());
  EXPECT_EQ(Value::boolean(true).integral(), 1);
  EXPECT_EQ(Value::boolean(false).integral(), 0);
  EXPECT_TRUE(Value::boolean(true).is_number());
  EXPECT_FALSE(Value::string("1").is_number());
}

TEST(Value, ListsAreShared) {
  Value a = Value::list(List{Value::integer(1), Value::integer(2)});
  Value b = a;
  EXPECT_EQ(a.list_ptr().get(), b.list_ptr().get());
  EXPECT_EQ(a.as_list().size(), 2u);
}

TEST(Dict, KeepsInsertionOrderAndOverwrites) {
  Dict d;
  d.set("b", Value::integer(1));
  d.set("a", Value::integer(2));
  d.set("b", Value::integer(3));
  ASSERT_EQ(d.size(), 2u);
  EXPECT_EQ(d.entries()[0].first, "b");
  EXPECT_EQ(d.find("b")->as_int(), 3);
  EXPECT_EQ(d.find("zz"), nullptr);
}

TEST(Dict, ManyKeysUseIndex) {
  Dict d;
  for (int i = 0; i < 1000; ++i) d.set("k" + std::to_string(i), Value::integer(i));
  for (int i = 0; i < 1000; ++i) ASSERT_EQ(d.find("k" + std::to_string(i))->as_int(), i);
  d.set("k500", Value::integer(-1));
  EXPECT_EQ(d.size(), 1000u);
  EXPECT_EQ(d.find("k500")->as_int(), -1);
  EXPECT_EQ(d.find("nope"), nullptr);
}
