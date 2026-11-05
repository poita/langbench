/// Unit tests for the low-level pieces: byte decoding, values, affinity, output.
module test_basics;

import dbbuilder;
import sqlitefile;

@safe unittest // varints
{
    size_t pos = 0;
    assert(readVarint([0x05], pos) == 5 && pos == 1);
    pos = 0;
    assert(readVarint([0x81, 0x00], pos) == 128 && pos == 2);
    foreach (v; [0L, 1, 127, 128, 16_383, 16_384, 1L << 40, long.max, -1, long.min, -12345])
    {
        auto enc = varint(v);
        pos = 0;
        assert(readVarint(enc, pos) == v);
        assert(pos == enc.length);
    }
    assert(varint(-1).length == 9);
}

@safe unittest // big-endian helpers
{
    ubyte[] d = [0xff, 0xfe, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06];
    assert(readBE16(d, 0) == 0xfffe);
    assert(readBE32(d, 2) == 0x01020304);
    assert(readBE64(d, 0) == 0xfffe010203040506UL);
    assert(readSignedBE(d, 0, 2) == -2);
    assert(readSignedBE(d, 2, 3) == 0x010203);
    assert(readSignedBE(d, 0, 0) == 0);
}

@safe unittest // value ordering
{
    auto n = Value.makeNull();
    auto i5 = Value.makeInt(5);
    auto r5 = Value.makeReal(5.0);
    auto t = Value.makeText("abc");
    auto b = Value.makeBlob([1, 2]);
    assert(compareValues(n, n) == 0);
    assert(compareValues(n, i5) < 0);
    assert(compareValues(i5, t) < 0);
    assert(compareValues(t, b) < 0);
    assert(compareValues(i5, r5) == 0);
    assert(compareValues(Value.makeInt(5), Value.makeReal(5.5)) < 0);
    assert(compareValues(Value.makeText("ab"), Value.makeText("abc")) < 0);
    assert(compareValues(Value.makeText("b"), Value.makeText("abc")) > 0);
    assert(compareValues(Value.makeBlob([0x80]), Value.makeBlob([0x7f])) > 0);
    // exact integer comparison beyond 2^53
    assert(compareValues(Value.makeInt(long.max), Value.makeInt(long.max - 1)) > 0);
}

@safe unittest // affinity rules, in order
{
    assert(affinityOf("INTEGER") == Affinity.integer);
    assert(affinityOf("POINT") == Affinity.integer);
    assert(affinityOf("FLOATING POINT") == Affinity.integer);
    assert(affinityOf("STRING") == Affinity.numeric);
    assert(affinityOf("INT TEXT") == Affinity.integer);
    assert(affinityOf("CHAR FLOA") == Affinity.text);
    assert(affinityOf("BLOB REAL") == Affinity.blob);
    assert(affinityOf("") == Affinity.blob);
    assert(affinityOf("nvarchar(160)") == Affinity.text);
    assert(affinityOf("NUMERIC(10,2)") == Affinity.numeric);
    assert(affinityOf("DOUBLE PRECISION") == Affinity.real_);
}

@safe unittest // numeric constants
{
    Value v;
    foreach (s; ["5", " 5 ", "\t-7\t", "+5e0", ".5", "-.5", "5.", "1e3", "-0"])
        assert(parseNumericConstant(s, v), s);
    foreach (s; ["", "-", "0x10", "inf", "5 x", ".", "1e", "e5", "1 2", "--1"])
        assert(!parseNumericConstant(s, v), s);
    assert(parseNumericConstant("9223372036854775807", v));
    assert(v.kind == ValueKind.integer && v.i == long.max);
    assert(parseNumericConstant("-9223372036854775808", v));
    assert(v.kind == ValueKind.integer && v.i == long.min);
    assert(parseNumericConstant("9223372036854775808", v));
    assert(v.kind == ValueKind.real_);
    assert(parseNumericConstant("5.", v) && v.kind == ValueKind.real_ && v.r == 5.0);
    assert(parseNumericConstant("+5e0", v) && v.kind == ValueKind.real_);
}

@safe unittest // applying affinity to literals
{
    auto a = applyAffinity(Value.makeText("12"), Affinity.integer);
    assert(a.kind == ValueKind.integer && a.i == 12);
    a = applyAffinity(Value.makeText(" 1.5 "), Affinity.real_);
    assert(a.kind == ValueKind.real_ && a.r == 1.5);
    a = applyAffinity(Value.makeText("x1"), Affinity.numeric);
    assert(a.kind == ValueKind.text);
    a = applyAffinity(Value.makeInt(12), Affinity.text);
    assert(a.kind == ValueKind.text && cast(const(char)[]) a.bytes == "12");
    a = applyAffinity(Value.makeReal(2.5), Affinity.text);
    assert(a.kind == ValueKind.text && cast(const(char)[]) a.bytes == "2.5");
    a = applyAffinity(Value.makeText("12"), Affinity.blob);
    assert(a.kind == ValueKind.text);
    a = applyAffinity(Value.makeNull(), Affinity.integer);
    assert(a.isNull);
}

@safe unittest // printing reals
{
    assert(formatReal(1.0) == "1.0");
    assert(formatReal(0.1) == "0.1");
    assert(formatReal(-3.25) == "-3.25");
    assert(formatReal(1.0 / 3) == "0.333333333333333");
    assert(formatReal(1e300) == "1.0e+300");
    assert(formatReal(2.5e-10) == "2.5e-10");
    assert(formatReal(1.5e16) == "1.5e+16");
    assert(formatReal(1e14) == "100000000000000.0");
    assert(formatReal(1e15) == "1.0e+15");
    assert(formatReal(0.0001) == "0.0001");
    assert(formatReal(1e-5) == "1.0e-05");
    assert(formatReal(0.0) == "0.0");
    assert(formatReal(-0.0) == "0.0");
}

@safe unittest // printing values
{
    OutBuf o;
    appendValue(o, Value.makeNull());
    o.put(cast(ubyte) ' ');
    appendValue(o, Value.makeInt(-42));
    o.put(cast(ubyte) ' ');
    appendValue(o, Value.makeInt(long.min));
    o.put(cast(ubyte) ' ');
    appendValue(o, Value.makeBlob([0x00, 0xab, 0x7f]));
    o.put(cast(ubyte) ' ');
    appendValue(o, Value.makeBlob([]));
    o.put(cast(ubyte) ' ');
    appendValue(o, Value.makeText("héllo"));
    assert(cast(const(char)[]) o.data == "NULL -42 -9223372036854775808 00AB7F  héllo");
}

@safe unittest // records
{
    auto bytes = record([Value.makeNull(), Value.makeInt(0), Value.makeInt(1),
            Value.makeInt(-300), Value.makeReal(2.5), Value.makeText("hi"),
            Value.makeBlob([9, 8])]);
    RecordReader rr;
    rr.parse(bytes);
    assert(rr.length == 7);
    assert(rr.value(0).isNull);
    assert(rr.value(1).i == 0);
    assert(rr.value(2).i == 1);
    assert(rr.value(3).i == -300);
    assert(rr.value(4).r == 2.5);
    assert(rr.value(5).kind == ValueKind.text && cast(const(char)[]) rr.value(5).bytes == "hi");
    assert(rr.value(6).kind == ValueKind.blob && rr.value(6).bytes == [9, 8]);
    assert(rr.value(7).isNull); // missing trailing column reads as NULL
}

@safe unittest // small integer serial types
{
    // header: size 5, types 1,2,3,4 ; body: 1 + 2 + 3 + 4 bytes
    ubyte[] r = [5, 1, 2, 3, 4, 0xff, 0xff, 0xfe, 0x00, 0x00, 0x80, 0x80, 0x00, 0x00, 0x01];
    RecordReader rr;
    rr.parse(r);
    assert(rr.value(0).i == -1);
    assert(rr.value(1).i == -2);
    assert(rr.value(2).i == 128);
    assert(rr.value(3).i == -2_147_483_647);
}
