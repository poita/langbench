/// Unit tests: hashing, byte helpers, paths, VFS, heap.
module tests.test_basics;

import kiln;
import kiln.heap;

unittest // FNV-1a known values
{
    assert(hashHex("") == "cbf29ce484222325");
    assert(hashHex("hello\n") == "a9bc80cca21f28b3");
    assert(hashHex("abc\n") == "fc17b183ee074373");
}

unittest // byte helpers
{
    assert(findBytes("hello world", "o w") == 4);
    assert(findBytes("hello", "xyz") == size_t.max);
    assert(findBytes("hello", "") == 0);
    assert(findBytes("aaab", "ab") == 2);
    assert(splitLines("") == []);
    assert(splitLines("a\nb\n") == ["a", "b"]);
    assert(splitLines("a\nb") == ["a", "b"]);
    assert(splitLines("a\n\nb\n") == ["a", "", "b"]);
    assert(splitLines("\n") == [""]);
    assert(countLines("a\r\nb") == 2);
    assert(replaceAll("aaa", "aa", "b") == "ba");
    assert(replaceAll("abc", "x", "y") == "abc");
    assert(intText(-45) == "-45");
}

unittest // workspace paths
{
    assert(isWorkspacePath("src/a.txt"));
    assert(isWorkspacePath("a+b-c_d.e"));
    assert(!isWorkspacePath(""));
    assert(!isWorkspacePath("/a"));
    assert(!isWorkspacePath("a/"));
    assert(!isWorkspacePath("a//b"));
    assert(!isWorkspacePath("a/../b"));
    assert(!isWorkspacePath("a/./b"));
    assert(!isWorkspacePath("a b"));
    assert(isWorkspacePath("..."));
    assert(isGeneratedPath("out/x"));
    assert(!isGeneratedPath("output/x"));
    assert(isIdentShaped("_a1") && !isIdentShaped("1a") && !isIdentShaped(""));
    assert(isReferenceShape("@all") && !isReferenceShape("@a-b") && isReferenceShape("x/y"));
}

unittest // vfs: hash cache, glob index, clean
{
    auto v = new Vfs;
    v.write("src/a.txt", "x");
    v.write("src/b.txt", "y");
    v.write("out/c.txt", "z");
    v.write(".kiln-state", "s");
    assert(v.hashOf("src/a.txt") == fnv1a("x"));
    v.write("src/a.txt", "changed");
    assert(v.hashOf("src/a.txt") == fnv1a("changed"));
    assert(v.eligibleWithPrefix("src") == ["src/a.txt", "src/b.txt"]);
    v.write("src/0.txt", "n");
    assert(v.eligibleWithPrefix("src")[0] == "src/0.txt");
    v.remove("src/0.txt");
    assert(v.eligibleWithPrefix("src").length == 2);
    assert(v.eligibleWithPrefix("out").length == 0);
    assert(v.clean() == [".kiln-state", "out/c.txt"]);
    assert(!v.exists("out/c.txt"));
}

unittest // min-heap
{
    MinHeap h;
    foreach (x; [5, 3, 9, 1, 7, 1])
        h.push(x);
    int[] got;
    while (!h.empty)
        got ~= h.pop();
    assert(got == [1, 1, 3, 5, 7, 9]);
}
