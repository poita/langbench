#include <gtest/gtest.h>

#include "protowire/error.hpp"
#include "protowire/schema.hpp"

using namespace protowire;

TEST(Schema, ParsesCompactAndMultiLine) {
  Schema s = Schema::parse("message A{int32 x=1;repeated string y=2;}\n"
                           "message B {\n\tA a = 3 ;\r\n  repeated A as = 1;\n}\n");
  const MessageDescriptor* a = s.findMessage("A");
  ASSERT_NE(a, nullptr);
  ASSERT_EQ(a->fields().size(), 2u);
  EXPECT_EQ(a->fields()[0].type, FieldType::Int32);
  EXPECT_FALSE(a->fields()[0].repeated);
  EXPECT_TRUE(a->fields()[1].repeated);

  const MessageDescriptor* b = s.findMessage("B");
  ASSERT_NE(b, nullptr);
  // Sorted by field number, with indices assigned in that order.
  EXPECT_EQ(b->fields()[0].name, "as");
  EXPECT_EQ(b->fields()[0].index, 0u);
  EXPECT_EQ(b->fields()[1].name, "a");
  EXPECT_EQ(b->fields()[1].message, a);
  EXPECT_EQ(b->findByNumber(3), &b->fields()[1]);
  EXPECT_EQ(b->findByName("as"), &b->fields()[0]);
  EXPECT_EQ(b->findByNumber(2), nullptr);
  EXPECT_EQ(b->findByName("zz"), nullptr);
  EXPECT_EQ(s.findMessage("C"), nullptr);
}

TEST(Schema, ForwardAndSelfReferences) {
  Schema s = Schema::parse("message A { B b = 1; A self = 2; } message B { int32 v = 1; }");
  const MessageDescriptor* a = s.findMessage("A");
  EXPECT_EQ(a->findByNumber(1)->message, s.findMessage("B"));
  EXPECT_EQ(a->findByNumber(2)->message, a);
}

TEST(Schema, AllScalarTypes) {
  Schema s = Schema::parse("message M { int32 a=1; int64 b=2; uint32 c=3; uint64 d=4; sint32 e=5; sint64 f=6;"
                           " bool g=7; fixed32 h=8; fixed64 i=9; sfixed32 j=10; sfixed64 k=11; string l=12; bytes m=13; }");
  const auto& f = s.findMessage("M")->fields();
  ASSERT_EQ(f.size(), 13u);
  EXPECT_EQ(f[0].type, FieldType::Int32);
  EXPECT_EQ(f[10].type, FieldType::SFixed64);
  EXPECT_EQ(f[12].type, FieldType::Bytes);
}

TEST(Schema, RejectsMalformed) {
  EXPECT_THROW(Schema::parse("message A { int32 x = 1 }"), SchemaError);
  EXPECT_THROW(Schema::parse("message A { Nope x = 1; }"), SchemaError);
  EXPECT_THROW(Schema::parse("message A { int32 x = 1; int32 x = 2; }"), SchemaError);
  EXPECT_THROW(Schema::parse("message A { int32 x = 1; int32 y = 1; }"), SchemaError);
  EXPECT_THROW(Schema::parse("message A {} message A {}"), SchemaError);
  EXPECT_THROW(Schema::parse("message A { int32 x = 1; "), SchemaError);
}

TEST(Schema, WireTypes) {
  EXPECT_EQ(wireTypeOf(FieldType::SInt64), WireType::Varint);
  EXPECT_EQ(wireTypeOf(FieldType::SFixed32), WireType::Fixed32);
  EXPECT_EQ(wireTypeOf(FieldType::Fixed64), WireType::Fixed64);
  EXPECT_EQ(wireTypeOf(FieldType::Message), WireType::LengthDelimited);
  EXPECT_TRUE(isNumeric(FieldType::Bool));
  EXPECT_FALSE(isNumeric(FieldType::String));
}
