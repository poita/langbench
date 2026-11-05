module tests.value_test;

import tessera.bytes;
import tessera.render;
import tessera.value;

private Value obj(string[] names, Value[] vals) { return Value.object(names, vals); }

unittest
{
    // Serialisation examples of the specification.
    assert(serialize(Value.integer(1)) == [3, 0, 0, 0, 0, 0, 0, 0, 1]);
    assert(serialize(Value.integer(-1)) == [3, 255, 255, 255, 255, 255, 255, 255, 255]);
    assert(serialize(Value.nullValue()) == [0]);
    assert(serialize(Value.boolean(true)) == [2]);
    assert(serialize(Value.boolean(false)) == [1]);
    assert(serialize(Value.string_("")) == [4, 0, 0, 0, 0]);
    assert(serialize(Value.string_("ada")) == [4, 0, 0, 0, 3, 0x61, 0x64, 0x61]);
    auto l = Value.list([Value.integer(1), Value.string_("x"), Value.nullValue()]);
    assert(serialize(l).length == 21);
    auto o = obj(["name", "age", "ok"], [Value.string_("ada"), Value.integer(36), Value.boolean(true)]);
    assert(serialize(o).length == 44);
    assert(o.names == ["age", "name", "ok"]);
}

unittest
{
    // Serialisation round-trips.
    auto v = obj(["b", "a", "c"], [Value.list([Value.integer(long.min), Value.integer(long.max)]),
            Value.string_("é😀\u0000x"), obj([], [])]);
    auto back = deserialize(serialize(v));
    assert(valuesEqual(v, back));
    assert(serialize(back) == serialize(v));
}

unittest
{
    // Canonical rendering and escaping.
    assert(renderToString(Value.integer(long.min)) == "-9223372036854775808");
    assert(renderToString(Value.list([Value.integer(1), Value.string_("x"), Value.nullValue()])) == `[1,"x",null]`);
    assert(renderToString(obj(["name", "age"], [Value.string_("ada"), Value.integer(36)])) == `{"age":36,"name":"ada"}`);
    assert(renderToString(obj([], [])) == "{}");
    assert(renderToString(Value.string_("a\"b\\c/\b\t\n\f\r\u0000\u001f\u007fé😀"))
            == `"a\"b\\c/\b\t\n\f\r\u0000\u001f\u007fé😀"`);
}

unittest
{
    // Depth.
    assert(depthOf(Value.integer(1)) == 1);
    assert(depthOf(Value.list([])) == 1);
    assert(depthOf(Value.list([Value.list([Value.integer(1)])])) == 3);
}

unittest
{
    // Deep equality ignores field order of construction; kinds must match.
    auto a = obj(["x", "y"], [Value.integer(1), Value.list([Value.integer(2)])]);
    auto b = obj(["y", "x"], [Value.list([Value.integer(2)]), Value.integer(1)]);
    assert(valuesEqual(a, b));
    assert(!valuesEqual(Value.integer(1), Value.boolean(true)));
    assert(!valuesEqual(Value.list([Value.integer(1)]), Value.list([Value.integer(1), Value.integer(2)])));
    assert(compareScalars(Value.string_("a"), Value.string_("b")) < 0);
    assert(compareScalars(Value.string_("a"), Value.string_("a\u0000")) < 0);
    assert(compareScalars(Value.integer(-5), Value.integer(3)) < 0);
}

unittest
{
    // Path resolution never traverses lists.
    auto d = obj(["a", "l"], [obj(["b"], [Value.integer(7)]), Value.list([obj(["b"], [Value.integer(1)])])]);
    assert(resolvePath(d, ["a", "b"]).num == 7);
    assert(resolvePath(d, ["a", "c"]) is null);
    assert(resolvePath(d, ["l", "b"]) is null);
    assert(resolvePath(d, ["a", "b", "c"]) is null);
}

unittest
{
    // setPath auto-vivifies, replaces, and reports non-objects.
    auto d = obj(["name"], [Value.string_("ada")]);
    Value r;
    assert(setPath(d, ["addr", "city"], Value.string_("oslo"), r));
    assert(renderToString(r) == `{"addr":{"city":"oslo"},"name":"ada"}`);
    assert(renderToString(d) == `{"name":"ada"}`); // the original is untouched
    assert(setPath(d, ["name"], Value.integer(1), r));
    assert(renderToString(r) == `{"name":1}`);
    assert(!setPath(d, ["name", "first"], Value.integer(1), r));
    assert(!setPath(Value.integer(3), ["x"], Value.integer(1), r));
}

unittest
{
    // unsetPath distinguishes the two failures.
    auto d = obj(["addr", "name"], [obj(["city"], [Value.string_("oslo")]), Value.string_("ada")]);
    Value r;
    assert(unsetPath(d, ["addr", "city"], r) == PathStatus.ok);
    assert(renderToString(r) == `{"addr":{},"name":"ada"}`);
    assert(unsetPath(d, ["addr", "zip"], r) == PathStatus.noField);
    assert(unsetPath(d, ["name", "first"], r) == PathStatus.notObject);
    assert(unsetPath(d, ["nope"], r) == PathStatus.noField);
}
