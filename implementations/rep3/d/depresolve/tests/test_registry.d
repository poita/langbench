/// Unit tests for depresolve.registry.
module test_registry;

import std.exception : assertThrown;
import depresolve.range;
import depresolve.registry;
import depresolve.semver;

private size_t idOf(const ref Registry reg, string name) @safe
{
    foreach (i, n; reg.names)
        if (n == name)
            return i;
    assert(false, "no such package");
}

@safe unittest // sorting, interning and windows
{
    auto reg = Registry.parse("c 1.2.5:\nc 1.10.0:\nc 1.9.0:\nc 2.0.0:\nroot: c ^1.0.0, d *\n");
    assert(reg.names == ["c", "d"]);
    // Versions of c, newest first.
    assert(reg.versions.length == 4);
    assert(reg.versions[0] == Version(2, 0, 0));
    assert(reg.versions[1] == Version(1, 10, 0));
    assert(reg.versions[3] == Version(1, 2, 5));
    auto root = reg.rootRequirements;
    assert(root.length == 2);
    // ^1.0.0 admits positions 1..4 (1.10.0, 1.9.0, 1.2.5).
    assert(root[0].first == 1 && root[0].last == 4);
    // d has no versions: empty window.
    assert(root[1].last <= root[1].first);
}

@safe unittest // requirements of versions, including empty ones
{
    auto reg = Registry.parse("a 1.0.0: b *, c ~1.2.0\nb 1.0.0:\nroot:\n");
    assert(reg.rootRequirements.length == 0);
    const a = idOf(reg, "a"), b = idOf(reg, "b");
    assert(reg.requirementsOf(reg.pkgStart[a]).length == 2);
    assert(reg.requirementsOf(reg.pkgStart[b]).length == 0);
}

@safe unittest // an empty interval gives an empty window
{
    auto reg = Registry.parse("a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n");
    auto q = reg.rootRequirements[0];
    assert(q.last <= q.first);
}

@safe unittest // a window with no admitted version in a populated package
{
    auto reg = Registry.parse("a 1.0.0:\na 3.0.0:\nroot: a ^2.0.0\n");
    auto q = reg.rootRequirements[0];
    assert(q.last <= q.first);
}

@safe unittest // malformed input
{
    assertThrown!ParseException(Registry.parse("a 1.0.0:\n"));
    assertThrown!ParseException(Registry.parse("A 1.0.0:\nroot:\n"));
}
