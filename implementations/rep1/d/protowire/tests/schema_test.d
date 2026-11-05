module schema_test;

import std.exception : assertThrown;

import protowire.schema;
import protowire.wire : WireType;

@safe unittest
{
    auto s = Schema.parse("message A{int32 x=1;repeated A kids=3;string name = 2;}\n"
            ~ "message B { A a = 1; repeated sint64 v = 9; }");
    assert(s.messages.length == 2);
    assert(s.messageIndex("A") == 0 && s.messageIndex("B") == 1);
    assert(s.messageIndex("C") == -1);

    const a = s.messages[0];
    assert(a.fields.length == 3);
    // Sorted by number, not declaration order.
    assert(a.fields[0].name == "x" && a.fields[1].name == "name" && a.fields[2].name == "kids");
    assert(a.fields[2].repeated && a.fields[2].kind == Kind.message && a.fields[2].message == 0);
    assert(a.findNumber(2) == 1 && a.findNumber(4) == -1);
    assert(a.findName("kids") == 2 && a.findName("nope") == -1);
    assert(a.fields[0].tag == 0x08 && a.fields[0].tagLen == 1);
    assert(a.fields[1].wireType == WireType.lengthDelimited);
}

@safe unittest // forward references
{
    auto s = Schema.parse("message A { B b = 1; } message B { int32 x = 1; }");
    assert(s.messages[0].fields[0].message == 1);
}

@safe unittest // type properties
{
    assert(isNumeric(Kind.fixed64) && !isNumeric(Kind.text) && !isNumeric(Kind.message));
    assert(isSigned(Kind.sint32) && isSigned(Kind.sfixed64) && !isSigned(Kind.uint32));
    assert(wireTypeOf(Kind.sfixed32) == WireType.fixed32);
    assert(wireTypeOf(Kind.fixed64) == WireType.fixed64);
    assert(wireTypeOf(Kind.boolean) == WireType.varint);
}

@safe unittest // malformed schemas are rejected
{
    assertThrown!SchemaException(Schema.parse("message A { foo x = 1; }"));
    assertThrown!SchemaException(Schema.parse("message A { int32 x = 1 }"));
    assertThrown!SchemaException(Schema.parse("message A { int32 x = 1; int32 y = 1; }"));
    assertThrown!SchemaException(Schema.parse("message A { int32 x = 1; } message A { }"));
    assertThrown!SchemaException(Schema.parse("message A { int32 x = 0; }"));
    assertThrown!SchemaException(Schema.parse("message A { int32 x = 1;"));
    assertThrown!SchemaException(Schema.parse("message A { int32 x = 1; } // c"));
}
