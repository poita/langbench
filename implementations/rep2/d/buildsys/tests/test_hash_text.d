module test_hash_text;

import kiln.hash;
import kiln.paths;
import kiln.text;

unittest
{
    assert(toHex16(fnv1a("")) == "cbf29ce484222325");
    assert(toHex16(fnv1a("hello\n")) == "a9bc80cca21f28b3");
    assert(toHex16(fnv1a("abc\n")) == "fc17b183ee074373");
    ulong h;
    assert(parseHex16("0123456789abcdef", h) && h == 0x0123456789abcdefUL);
    assert(!parseHex16("0123456789ABCDEF", h));
    assert(!parseHex16("abc", h));
}

unittest
{
    assert(isWorkspacePath("a"));
    assert(isWorkspacePath("src/a.b-c+d_e"));
    assert(!isWorkspacePath(""));
    assert(!isWorkspacePath("/a"));
    assert(!isWorkspacePath("a/"));
    assert(!isWorkspacePath("a//b"));
    assert(!isWorkspacePath("a/../b"));
    assert(!isWorkspacePath("./a"));
    assert(!isWorkspacePath("a b"));
    assert(!isWorkspacePath("a*"));
    assert(isGenerated("out/x"));
    assert(isGenerated("out"));
    assert(!isGenerated("output/x"));
    assert(!isGlobEligible(".kiln-state"));
    assert(isIdentifier("_a1"));
    assert(!isIdentifier("1a"));
}

unittest
{
    assert(splitLines("") == []);
    assert(splitLines("a\nb\n") == ["a", "b"]);
    assert(splitLines("a\nb") == ["a", "b"]);
    assert(splitLines("a\n\nb\n") == ["a", "", "b"]);
    assert(splitLines("\n") == [""]);
    assert(countLines("a\r\nb") == 2);
    assert(countLines("") == 0);
    assert(joinLines(["a", "b"]) == "a\nb\n");
    assert(replaceAll("aaa", "aa", "b") == "ba");
    assert(replaceAll("abc", "x", "y") == "abc");
    assert(findBytes("hello", "") == 0);
    assert(containsBytes("hello", "ell"));
    assert(!containsBytes("he", "hello"));
}
