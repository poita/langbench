module tests.test_registry;

import depresolve.registry;
import depresolve.semver;

unittest // parsing, interning and ordering
{
    auto reg = parseRegistry("a 1.0.0: b *\nb 1.9.0:\nb 1.10.0:\nroot: a *\n");
    assert(reg.names == ["a", "b"]);
    assert(reg.versions.length == 3);
    const b = reg.lookup("b");
    assert(reg.lookup("zzz") == none);
    auto c = reg.candidatesOf(b);
    assert(c.length == 2);
    assert(reg.versions[c[0]].key == packVersion(1, 10, 0)); // newest first
    assert(reg.versions[c[1]].key == packVersion(1, 9, 0));
    assert(reg.rootCount == 1);
}

unittest // windows into the newest-first list
{
    auto reg = parseRegistry("c 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: c ~1.2.0, c ^1.0.0, c >=2.0.0, c ^1.2.5\n");
    auto r = reg.requirements[reg.rootStart .. reg.rootStart + reg.rootCount];
    assert(r[0].first == 1 && r[0].last == 2); // 1.2.5 only
    assert(r[1].first == 0 && r[1].last == 3);
    assert(r[2].first >= r[2].last); // empty
    assert(r[3].first == 0 && r[3].last == 2);
    assert(r[0].admits(1) && !r[0].admits(0));
}

unittest // requirement on an unknown package yields an empty window
{
    auto reg = parseRegistry("root: ghost *\n");
    assert(reg.rootCount == 1);
    assert(reg.requirements[0].first >= reg.requirements[0].last);
}

unittest // empty requirements and empty root
{
    auto reg = parseRegistry("a 1.0.0:\nroot:\n");
    assert(reg.versions[0].reqCount == 0);
    assert(reg.rootCount == 0);
}
