module tests.params_test;

import mime.params;

private string param(string raw, string name)
{
    string v;
    return parseStructured(raw).find(name, v) ? v : "<none>";
}

unittest // value proper and plain parameters
{
    auto sv = parseStructured(" Text/Plain ; Charset=\"UTF-8\"; x=1; X=2");
    assert(sv.valueProper() == "text/plain");
    assert(param(" a/b; charset=\"UTF-8\"; x=1; X=2", "charset") == "UTF-8");
    assert(param("a/b; x=1; X=2", "x") == "1");
    assert(param("a/b; novalue", "novalue") == "<none>");
}

unittest // quoted strings and separators
{
    assert(param(`a; filename="a;b"; x=1`, "filename") == "a;b");
    assert(param(`a; filename="a\\"; x=1`, "filename") == `a\`);
    assert(param(`a; filename="a\"b"`, "filename") == `a"b`);
    assert(param(`a; filename=two words.bin`, "filename") == "two words.bin");
    assert(param(`a; boundary=simple boundary`, "boundary") == "simple boundary");
    assert(param(`a; b="unterminated; c=d`, "b") == "unterminated; c=d");
}

unittest // RFC 2231
{
    assert(param("a; filename*=utf-8''a%C3%A9.txt", "filename") == "aé.txt");
    assert(param(`a; filename*0="long"; filename*1="name.txt"`, "filename") == "longname.txt");
    assert(param(`a; filename*0*=utf-8''a%C3%A9; filename*1=".txt"`, "filename") == "aé.txt");
    assert(param(`a; filename="=?utf-8?Q?a=C3=A9.txt?="`, "filename") == "aé.txt");
    assert(param("a; filename*=''caf%E9.txt", "filename") == "caf�.txt");
    assert(param("a; filename*0=a; filename*2=c; filename*10=j", "filename") == "acj");
    assert(param("a; f*0=a; f*00=b; f*1=c; f*1*=d", "f") == "ac");
    assert(param("a; f*07=x; f*7=y", "f") == "x");
    assert(param("a; f=plain; f*=utf-8''ext", "f") == "ext");
    assert(param("a; f*=utf-8''ext; f*0=num", "f") == "num");
    assert(param("a; *0=x", "*0") == "x");
    assert(param("a; f*=nocharset%41", "f") == "nocharsetA");
    assert(param("a; f*0=%41; f*1*=%42", "f") == "%41B");
}
