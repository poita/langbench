module session_test;

import protowire;

private string run(string input) @trusted
{
    ByteBuffer o;
    processDocument(cast(const(ubyte)[]) input, o);
    return (cast(const(char)[]) o.data).idup;
}

@safe unittest // specification examples
{
    assert(run("message Inner { sint32 v = 1; }\n"
            ~ "message Outer {\n  int32 a = 1;\n  string b = 2;\n  repeated int32 c = 3;\n  Inner d = 4;\n}\n--\n"
            ~ "encode Outer {a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\n"
            ~ "decode Outer 08011201781a02010222020809\n"
            ~ "encode Outer {d: {}, c: [], a: 0}\n"
            ~ "decode Outer 3800\n"
            ~ "decode Outer 08ff\n")
            == "08011201781a02010222020809\n"
            ~ "{a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\n2200\n{}\nerror\n");
}

@safe unittest // request line syntax
{
    const schema = "message M { int32 a = 1; }\n--\n";
    assert(run(schema ~ "decode M") == "{}\n");           // no trailing newline
    assert(run(schema ~ "decode M 0801\n") == "{a: 1}\n");
    assert(run(schema ~ "decode M \n") == "error\n");      // trailing space
    assert(run(schema ~ "decode M 080\n") == "error\n");   // odd digits
    assert(run(schema ~ "decode M 08A1\n") == "error\n");  // uppercase
    assert(run(schema ~ "decode M 08 01\n") == "error\n"); // extra text
    assert(run(schema ~ "decode Z 08\n") == "error\n");    // unknown message
    assert(run(schema ~ "frobnicate M\n") == "error\n");
    assert(run(schema ~ "encode M {}\n") == "\n");         // empty encoding: empty line
    assert(run(schema ~ "encode M\n") == "error\n");
    assert(run(schema ~ "encode M \n") == "error\n");
    assert(run(schema ~ "encode M {a: 1}\ndecode M 0802") == "0801\n{a: 2}\n");
}

@safe unittest // schema formatting and degenerate documents
{
    assert(run("message A{int32 x=1;}\n--\ndecode A 0805\n") == "{x: 5}\n");
    assert(run("message A { int32 x = 1; }\n--\n") == "");
    assert(run("message A { bogus } \n--\ndecode A\n") == "error\n");
}
