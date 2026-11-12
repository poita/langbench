/// Column type affinity (SPEC §2.3) and its application to query literals
/// (SPEC Part 3).
module sqlitefile.affinity;

import sqlitefile.numeric;
import sqlitefile.render : formatValue;
import sqlitefile.value;

@safe:

/// The five column affinities.
enum Affinity : ubyte
{
    integer,
    text,
    blob,
    real_,
    numeric,
}

private bool containsCI(const(char)[] hay, string needle) pure nothrow @nogc
{
    if (needle.length > hay.length)
        return false;
    foreach (s; 0 .. hay.length - needle.length + 1)
    {
        bool ok = true;
        foreach (k, c; needle)
        {
            char h = hay[s + k];
            if (h >= 'a' && h <= 'z')
                h = cast(char)(h - 32);
            if (h != c)
            {
                ok = false;
                break;
            }
        }
        if (ok)
            return true;
    }
    return false;
}

/// Derives the affinity from a declared type name using SQLite's five rules,
/// applied in order.
Affinity affinityOf(const(char)[] declaredType) pure nothrow @nogc
{
    if (containsCI(declaredType, "INT"))
        return Affinity.integer;
    if (containsCI(declaredType, "CHAR") || containsCI(declaredType, "CLOB")
            || containsCI(declaredType, "TEXT"))
        return Affinity.text;
    if (declaredType.length == 0 || containsCI(declaredType, "BLOB"))
        return Affinity.blob;
    if (containsCI(declaredType, "REAL") || containsCI(declaredType, "FLOA")
            || containsCI(declaredType, "DOUB"))
        return Affinity.real_;
    return Affinity.numeric;
}

/// Converts a query literal according to the affinity of the column it is
/// compared with. Column values themselves are never converted.
Value applyAffinity(Value literal, Affinity aff)
{
    final switch (aff)
    {
    case Affinity.text:
        if (literal.isNumber)
            return Value.fromText(formatValue(literal));
        return literal;
    case Affinity.integer:
    case Affinity.real_:
    case Affinity.numeric:
        if (literal.type == ValueType.text)
        {
            Value n;
            if (textToNumber(cast(const(char)[]) literal.bytes, n))
                return n;
        }
        return literal;
    case Affinity.blob:
        return literal;
    }
}

unittest
{
    assert(affinityOf("INTEGER") == Affinity.integer);
    assert(affinityOf("NVARCHAR(160)") == Affinity.text);
    assert(affinityOf("NUMERIC(10,2)") == Affinity.numeric);
    assert(affinityOf("") == Affinity.blob);
    assert(affinityOf("POINT") == Affinity.integer);
    assert(affinityOf("FLOATING POINT") == Affinity.integer);
    assert(affinityOf("STRING") == Affinity.numeric);
    assert(affinityOf("INTEGER TEXT") == Affinity.integer);
    assert(affinityOf("CHARFLOAT") == Affinity.text);
    assert(affinityOf("BLOB REAL") == Affinity.blob);
    assert(affinityOf("double precision") == Affinity.real_);
    assert(affinityOf("DATETIME") == Affinity.numeric);
}

unittest
{
    auto t = Value.fromText("12");
    assert(applyAffinity(t, Affinity.integer).i == 12);
    assert(applyAffinity(t, Affinity.numeric).type == ValueType.integer);
    assert(applyAffinity(t, Affinity.blob).type == ValueType.text);
    assert(applyAffinity(Value.fromText("5 x"), Affinity.integer).type == ValueType.text);
    assert(applyAffinity(Value.fromText("1.5"), Affinity.real_).r == 1.5);
    auto s = applyAffinity(Value.fromInt(7), Affinity.text);
    assert(s.type == ValueType.text && s.bytes == cast(const(ubyte)[]) "7");
    s = applyAffinity(Value.fromReal(2.0), Affinity.text);
    assert(s.bytes == cast(const(ubyte)[]) "2.0");
    assert(applyAffinity(Value.makeNull(), Affinity.text).isNull);
    assert(applyAffinity(Value.fromBlob([cast(ubyte) 1]), Affinity.integer).type == ValueType.blob);
}
