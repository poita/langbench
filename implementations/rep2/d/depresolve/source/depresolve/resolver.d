/**
 * The resolution search.
 *
 * Implements exactly the depth-first, newest-version-first, chronologically
 * backtracking search from the specification, iteratively:
 *
 * $(UL
 *  $(LI pending requirements are an immutable singly linked list stored in an
 *       arena, so a choice point shares its tail instead of copying it;)
 *  $(LI choices are undone through a trail, so a step costs $(I O(1)) plus
 *       the requirements it pushes;)
 *  $(LI candidates are the precomputed index range of each requirement, no
 *       version list is ever filtered during the search;)
 *  $(LI an explicit choice-point stack replaces recursion, so depth is
 *       limited by memory only.)
 * )
 */
module depresolve.resolver;

import depresolve.parser : Problem;
import depresolve.registry;
import depresolve.semver;

/// One picked package version.
struct Pick
{
    /// Package name.
    string name;
    /// Chosen version.
    Version version_;
}

/// Outcome of a resolution.
struct Resolution
{
    /// True if a complete resolution was found.
    bool satisfiable;
    /// Picks sorted by name in ascending byte order (empty if unsatisfiable).
    Pick[] picks;
    /// Number of choice points opened by the search (a work measure).
    size_t choicePoints;
}

/**
 * Resolves `root` against `registry`.
 *
 * The registry is sealed (sorted and bound) first if necessary. `root` may
 * be unbound; it is bound against the registry internally.
 *
 * Returns: the first solution in the specified search order, or an
 * unsatisfiable `Resolution`.
 */
Resolution resolve(ref Registry registry, const(Requirement)[] root) pure @safe
{
    registry.seal();

    // Bound copy of the root requirements.
    auto rootReqs = root.dup;
    foreach (ref r; rootReqs)
        registry.bind(r);

    const nPkg = registry.packages.length;

    // Index of the chosen version of each package, or `none`.
    auto chosen = new uint[nPkg];
    chosen[] = none;
    // Packages in the order they were chosen; undo log for backtracking.
    PackageId[] trail;
    trail.reserve(nPkg);

    // Pending requirements: persistent linked list in an arena.
    static struct Node
    {
        const(Requirement)* req;
        uint next;
    }
    Node[] nodes;
    nodes.reserve(1024);

    // Choice points.
    static struct Choice
    {
        PackageId pkg;
        uint cur;       // index of the candidate currently applied
        uint end;       // one past the last candidate
        uint rest;      // pending list that follows the chosen version's requirements
        uint trailMark; // trail length before this choice
        uint nodeMark;  // arena length before this choice's requirements
    }
    Choice[] stack;
    stack.reserve(256);

    size_t choicePoints = 0;

    // Pending list head: build the root requirements (first listed = head).
    uint pending = none;
    foreach_reverse (ref r; rootReqs)
    {
        () @trusted { nodes ~= Node(&r, pending); }();
        pending = cast(uint) nodes.length - 1;
    }

    // Applies candidate `cp.cur` of the choice point `cp`: records it, and
    // pushes the version's requirements in front of `cp.rest`.
    // Returns the new pending head.
    uint apply(ref const Choice cp) @safe
    {
        chosen[cp.pkg] = cp.cur;
        trail ~= cp.pkg;
        const pv = &registry.packages[cp.pkg].versions[cp.cur];
        uint head = cp.rest;
        foreach_reverse (i; pv.reqStart .. pv.reqEnd)
        {
            () @trusted { nodes ~= Node(&registry.pool[i], head); }();
            head = cast(uint) nodes.length - 1;
        }
        return head;
    }

    bool failed = false;
    while (true)
    {
        if (failed)
        {
            // Chronological backtracking: advance the most recent choice
            // point that still has an untried candidate.
            bool resumed = false;
            while (stack.length)
            {
                auto cp = &stack[$ - 1];
                foreach (p; trail[cp.trailMark .. $])
                    chosen[p] = none;
                trail.length = cp.trailMark;
                nodes.length = cp.nodeMark;
                ++cp.cur;
                if (cp.cur < cp.end)
                {
                    pending = apply(*cp);
                    resumed = true;
                    break;
                }
                stack.length = stack.length - 1;
            }
            if (!resumed)
                return Resolution(false, null, choicePoints);
            failed = false;
        }

        if (pending == none)
            break; // success

        const node = nodes[pending];
        const req = node.req;
        const rest = node.next;

        const cur = chosen[req.pkg];
        if (cur != none)
        {
            if (cur >= req.first && cur < req.last)
                pending = rest;
            else
                failed = true;
            continue;
        }
        if (req.first >= req.last)
        {
            failed = true;
            continue;
        }

        ++choicePoints;
        stack ~= Choice(req.pkg, req.first, req.last, rest,
                        cast(uint) trail.length, cast(uint) nodes.length);
        pending = apply(stack[$ - 1]);
    }

    Pick[] picks;
    picks.reserve(trail.length);
    foreach (p; trail)
        picks ~= Pick(registry.packages[p].name,
                      registry.packages[p].versions[chosen[p]].version_);
    import std.algorithm.sorting : sort;
    picks.sort!((a, b) => a.name < b.name);
    return Resolution(true, picks, choicePoints);
}

/// Convenience overload taking a parsed `Problem`.
Resolution resolve(ref Problem problem) pure @safe
{
    return resolve(problem.registry, problem.root);
}

version (unittest)
{
    import depresolve.parser : parseProblem;

    private string solve(string input)
    {
        auto p = parseProblem(input);
        auto r = resolve(p);
        if (!r.satisfiable)
            return "unsatisfiable";
        string s;
        foreach (pk; r.picks)
            s ~= pk.name ~ " " ~ pk.version_.toString ~ "\n";
        return s;
    }
}

// Spec example 1: diamond that needs backtracking.
unittest
{
    assert(solve("a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\n"
                 ~ "root: a *, b *\n") == "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
}

// Spec example 2: first solution, not the globally newest set.
unittest
{
    assert(solve("a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\n"
                 ~ "root: a *, b *\n") == "a 2.0.0\nb 1.0.5\n");
}

// Spec example 3: conflicting majors.
unittest
{
    assert(solve("a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n"
                 ~ "root: a *, b *\n") == "unsatisfiable");
}

// Spec example 4: requirement order matters.
unittest
{
    enum reg = "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\n"
             ~ "b 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n";
    assert(solve(reg ~ "root: a *, b *\n") == "a 2.0.0\nb 1.0.0\nc 2.0.0\n");
    assert(solve(reg ~ "root: b *, a *\n") == "a 1.0.0\nb 2.0.0\nc 1.0.0\n");
}

unittest
{
    assert(solve("root:\n") == "");
    assert(solve("a 1.0.0:\nroot:\n") == "");
}

// Missing package / empty range / self requirement / cycles.
unittest
{
    assert(solve("root: ghost *\n") == "unsatisfiable");
    assert(solve("a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n") == "unsatisfiable");
    assert(solve("a 1.0.0: a 1.0.0\nroot: a *\n") == "a 1.0.0\n");
    assert(solve("a 2.0.0: a ^1.0.0\na 1.0.0: a ^1.0.0\nroot: a *\n") == "a 1.0.0\n");
    assert(solve("a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n") == "a 1.0.0\nb 1.0.0\n");
}

// Numeric (not lexicographic) version order and byte-order output sorting.
unittest
{
    assert(solve("a 1.9.0:\na 1.10.0:\nroot: a *\n") == "a 1.10.0\n");
    assert(solve("mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\n"
                 ~ "root: mylib *, my-lib2 *, my-lib *\n")
           == "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n");
}

// Chronological backtracking revisits an unrelated earlier choice.
unittest
{
    // x is chosen before the conflict between y and z, and only x 1.0.0 helps.
    enum reg = "x 2.0.0: z ^2.0.0\nx 1.0.0: z ^1.0.0\n"
             ~ "y 1.0.0: z ^1.0.0\nz 1.0.0:\nz 2.0.0:\n";
    assert(solve(reg ~ "root: x *, y *\n") == "x 1.0.0\ny 1.0.0\nz 1.0.0\n");
}

// Deep chains must not overflow the call stack.
unittest
{
    import std.array : appender;
    import std.format : format;
    auto app = appender!string;
    enum n = 20_000;
    foreach (i; 0 .. n)
        app ~= format("p%d 1.0.0: p%d *\n", i, i + 1);
    app ~= format("p%d 1.0.0:\nroot: p0 *\n", n);
    auto p = parseProblem(app.data);
    auto r = resolve(p);
    assert(r.satisfiable && r.picks.length == n + 1);
}

// Many versions stepped through before one fits.
unittest
{
    import std.array : appender;
    import std.format : format;
    auto app = appender!string;
    foreach (i; 0 .. 1000)
        app ~= format("a %d.0.0:\n", i);
    app ~= "root: a *, a <=3.0.0\n";
    // `a *` fixes a to 999.0.0 first; the second requirement then fails and
    // the search steps down through the versions until it fits.
    assert(solve(app.data) == "a 3.0.0\n");
}
