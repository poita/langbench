module uri_test;

import jsonschema.pointer;
import jsonschema.json;
import jsonschema.uri;

unittest // RFC 3986 section 5.4 normal examples
{
    enum base = "http://a/b/c/d;p?q";
    assert(resolve("g:h", base) == "g:h");
    assert(resolve("g", base) == "http://a/b/c/g");
    assert(resolve("./g", base) == "http://a/b/c/g");
    assert(resolve("g/", base) == "http://a/b/c/g/");
    assert(resolve("/g", base) == "http://a/g");
    assert(resolve("//g", base) == "http://g");
    assert(resolve("?y", base) == "http://a/b/c/d;p?y");
    assert(resolve("g?y", base) == "http://a/b/c/g?y");
    assert(resolve("#s", base) == "http://a/b/c/d;p?q#s");
    assert(resolve("g#s", base) == "http://a/b/c/g#s");
    assert(resolve("", base) == "http://a/b/c/d;p?q");
    assert(resolve(".", base) == "http://a/b/c/");
    assert(resolve("..", base) == "http://a/b/");
    assert(resolve("../g", base) == "http://a/b/g");
    assert(resolve("../..", base) == "http://a/");
    assert(resolve("../../g", base) == "http://a/g");
}

unittest // RFC 3986 section 5.4 abnormal examples
{
    enum base = "http://a/b/c/d;p?q";
    assert(resolve("../../../g", base) == "http://a/g");
    assert(resolve("/./g", base) == "http://a/g");
    assert(resolve("g.", base) == "http://a/b/c/g.");
    assert(resolve("./../g", base) == "http://a/b/g");
    assert(resolve("g;x=1/../y", base) == "http://a/b/c/y");
    assert(resolve("http:g", base) == "http:g");
}

unittest // empty and opaque bases
{
    assert(resolve("foo.json", "") == "foo.json");
    assert(resolve("#a", "") == "#a");
    assert(resolve("#/x", "urn:uuid:1234") == "urn:uuid:1234#/x");
    assert(resolve("http://x/y", "") == "http://x/y");
    assert(resolve("integer.json", "http://localhost:1234/draft2020-12/root.json")
            == "http://localhost:1234/draft2020-12/integer.json");
}

unittest // fragments and percent-decoding
{
    string frag;
    bool has;
    assert(splitFragment("http://x/y#/a/b", frag, has) == "http://x/y");
    assert(has && frag == "/a/b");
    assert(splitFragment("http://x/y", frag, has) == "http://x/y" && !has);
    assert(percentDecode("%25a%2Fb") == "%a/b");
    assert(percentDecode("%C3%A9") == "é");
    assert(percentDecode("100%") == "100%");
}

unittest // JSON pointer
{
    auto doc = parseJson(`{"a":{"b/c":[10,20],"d~e":1},"":2}`);
    assert(evaluatePointer(&doc, "").kind == Kind.object);
    assert(evaluatePointer(&doc, "/a/b~1c/1").number.toCount == 20);
    assert(evaluatePointer(&doc, "/a/d~0e").number.toCount == 1);
    assert(evaluatePointer(&doc, "/").number.toCount == 2);
    assert(evaluatePointer(&doc, "/a/b~1c/2") is null);
    assert(evaluatePointer(&doc, "/a/zzz") is null);
    assert(evaluatePointer(&doc, "/a/b~1c/01") is null);
}
