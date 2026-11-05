module test_parser;

import std.exception : assertThrown;
import depresolve;

unittest // registry layout
{
    auto reg = parseInput(
        "a 1.0.0: b ^1.0.0, c *\n" ~
        "b 1.2.0:\n" ~
        "b 1.10.0:\n" ~
        "b 1.9.0:\n" ~
        "root: a *\n");
    assert(reg.packageCount == 3); // a, b, c (c is only required)
    auto b = reg.idOf("b");
    assert(b != noPackage);
    auto vs = reg.versionsOf(b);
    assert(vs.length == 3);
    assert(Version.fromKey(vs[0].key) == Version(1, 10, 0)); // newest first
    assert(Version.fromKey(vs[1].key) == Version(1, 9, 0));
    assert(Version.fromKey(vs[2].key) == Version(1, 2, 0));
    assert(reg.versionsOf(reg.idOf("c")).length == 0);
    assert(reg.idOf("zzz") == noPackage);
    assert(reg.rootRequirements.length == 1);
    auto a1 = reg.versionsOf(reg.idOf("a"))[0];
    assert(reg.requirementsOf(a1).length == 2);
}

unittest // candidate windows
{
    auto reg = parseInput(
        "b 1.0.0:\nb 1.1.0:\nb 1.2.5:\nb 1.3.0:\nb 2.0.0:\n" ~
        "a 1.0.0: b ~1.2.0, b2 *, nowhere ^1.0.0\n" ~
        "root: b ^1.0.0, b >=3.0.0, b >=2.0.0 <1.0.0, b *\n");
    auto roots = reg.rootRequirements;
    assert(roots[0].first == 1 && roots[0].last == 5); // 1.3.0 .. 1.0.0
    assert(roots[1].last <= roots[1].first);           // nothing >= 3.0.0
    assert(roots[2].last <= roots[2].first);           // empty interval
    assert(roots[3].first == 0 && roots[3].last == 5);
    auto a = reg.requirementsOf(reg.versionsOf(reg.idOf("a"))[0]);
    assert(a[0].first == 2 && a[0].last == 3);         // only 1.2.5
    assert(a[1].last <= a[1].first);                   // b2 has no versions
    assert(a[2].last <= a[2].first);
}

unittest // root only, and empty root
{
    auto reg = parseInput("root:\n");
    assert(reg.packageCount == 0 && reg.rootRequirements.length == 0);
    assert(parseInput("a 1.0.0:\nroot: a *\n").rootRequirements.length == 1);
}

unittest // malformed inputs are rejected
{
    foreach (bad; ["", "a 1.0.0:\n", "root: a\n", "a 1.0.0 b\nroot:\n", "a 1.0.0:b *\nroot:\n",
                   "a 1.0.0: b *,c *\nroot:\n", "root:\na 1.0.0:\n", "a 01.0.0:\nroot:\n",
                   "a 1.0.0: b ^1\nroot:\n", " 1.0.0:\nroot:\n"])
        assertThrown!ParseException(parseInput(bad), bad);
}

unittest // builder API without text
{
    RegistryBuilder b;
    b.addVersion("lib", Version(1, 0, 0));
    b.addVersion("lib", Version(1, 1, 0));
    b.addVersion("app", Version(0, 1, 0), [RequirementSpec("lib", parseRange("^1.0.0"))]);
    b.setRoot([RequirementSpec("app", anyVersion)]);
    auto res = resolve(b.build());
    assert(formatResolution(res) == "app 0.1.0\nlib 1.1.0\n");
}
