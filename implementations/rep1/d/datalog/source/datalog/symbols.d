/// Constants and the table that interns them.
module datalog.symbols;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.range : iota;
import std.array : array;

/// A constant of the language: an integer or an identifier.
///
/// Constants are totally ordered: every integer is below every identifier,
/// integers compare numerically and identifiers bytewise (`strcmp` order).
struct Constant
{
    bool isInteger;
    long number;
    string name;

    /// Makes an integer constant.
    static Constant integer(long value) @safe pure nothrow @nogc
    {
        return Constant(true, value, null);
    }

    /// Makes an identifier constant.
    static Constant symbol(string name) @safe pure nothrow @nogc
    {
        return Constant(false, 0, name);
    }

    /// Canonical textual form: decimal for integers, the name otherwise.
    string toString() const @safe pure
    {
        return isInteger ? number.to!string : name;
    }

    int opCmp(const Constant other) const @safe pure nothrow @nogc
    {
        if (isInteger != other.isInteger)
            return isInteger ? -1 : 1;
        if (isInteger)
            return number < other.number ? -1 : (number > other.number ? 1 : 0);
        return name < other.name ? -1 : (name > other.name ? 1 : 0);
    }

    bool opEquals(const Constant other) const @safe pure nothrow @nogc
    {
        return isInteger == other.isInteger && (isInteger ? number == other.number : name == other.name);
    }
}

///
@safe pure unittest
{
    assert(Constant.integer(5) < Constant.symbol("a"));
    assert(Constant.integer(-2) < Constant.integer(0));
    assert(Constant.symbol("a") < Constant.symbol("a0"));
    assert(Constant.symbol("a_b") < Constant.symbol("aa"));
    assert(Constant.integer(7) != Constant.symbol("7"));
    assert(Constant.integer(-5).toString == "-5");
}

/// Interns constants, giving each distinct constant a dense id.
final class SymbolTable
{
    private uint[long] integerIds;
    private uint[string] nameIds;
    private Constant[] items;

    /// Id of `c`, adding it if it is new.
    uint intern(Constant c) @safe pure
    {
        if (c.isInteger)
        {
            if (auto p = c.number in integerIds)
                return *p;
            immutable id = cast(uint) items.length;
            integerIds[c.number] = id;
            items ~= c;
            return id;
        }
        if (auto p = c.name in nameIds)
            return *p;
        immutable id = cast(uint) items.length;
        nameIds[c.name] = id;
        items ~= c;
        return id;
    }

    /// Number of distinct constants.
    size_t length() const @safe pure nothrow @nogc
    {
        return items.length;
    }

    /// The constant with the given id.
    Constant opIndex(uint id) const @safe pure nothrow @nogc
    {
        return items[id];
    }

    /// Returns `rank` such that `rank[id]` is the position of constant `id`
    /// in the sorted order of all constants. Comparing ranks is therefore the
    /// same as comparing the constants.
    uint[] ranks() const @safe pure
    {
        auto order = iota(cast(uint) items.length).array;
        order.sort!((a, b) => items[a] < items[b]);
        auto result = new uint[items.length];
        foreach (i, id; order)
            result[id] = cast(uint) i;
        return result;
    }
}

@safe pure unittest
{
    auto t = new SymbolTable;
    immutable b = t.intern(Constant.symbol("b"));
    immutable one = t.intern(Constant.integer(1));
    immutable a = t.intern(Constant.symbol("a"));
    immutable neg = t.intern(Constant.integer(-3));
    assert(t.intern(Constant.symbol("b")) == b);
    assert(t.length == 4);
    auto r = t.ranks;
    assert(r[neg] == 0 && r[one] == 1 && r[a] == 2 && r[b] == 3);
    assert(t[a].name == "a");
}
