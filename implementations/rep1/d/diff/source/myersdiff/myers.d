/**
 * Myers' O(ND) difference algorithm in its linear-space form
 * (E. Myers, "An O(ND) Difference Algorithm and Its Variations", 1986, §4b).
 *
 * The search finds the "middle snake" of an optimal path by running a
 * forward and a reverse greedy search until they overlap, then recurses on
 * the two halves. Space is O(N+M) beyond the output; time is O((N+M)·D);
 * the recursion depth is O(log D). Common prefixes and suffixes are trimmed
 * at every level. The result is always a minimal script — there are no
 * heuristics or cost cut-offs.
 */
module myersdiff.myers;

import std.array : appender, Appender;
import myersdiff.edit;
import myersdiff.intern;

/**
 * Computes a shortest edit script turning `a` into `b`, where the two
 * sequences are given as integer ids (equal ids mean equal lines).
 *
 * Returns: the script in order; `keep`/`remove` carry indices into `a`,
 * `insert` carries an index into `b`.
 */
Edit[] diffIds(scope const(int)[] a, scope const(int)[] b) @safe pure nothrow
in (a.length < int.max / 2 && b.length < int.max / 2, "sequences too long")
{
    auto s = Solver(a, b);
    s.run();
    return s.result.data;
}

/**
 * Computes a shortest edit script turning the lines `a` into the lines `b`.
 * Lines are compared byte-for-byte.
 */
Edit[] diffLines(scope const(Line)[] a, scope const(Line)[] b) @safe pure nothrow
{
    Interner interner;
    const ia = interner.internLines(a);
    const ib = interner.internLines(b);
    return diffIds(ia, ib);
}

///
@safe pure nothrow unittest
{
    // The example from Myers' paper: abcabba -> cbabac has cost 5.
    auto script = diffLines(["a", "b", "c", "a", "b", "b", "a"],
                            ["c", "b", "a", "b", "a", "c"]);
    assert(cost(script) == 5);
}

private:

/// The middle snake of a sub-problem, in coordinates relative to the
/// sub-problem's origin: the path runs (xs,ys) -> (xe,ye) along a diagonal.
struct Snake
{
    int xs, ys, xe, ye;
}

struct Solver
{
    const(int)[] a, b;
    int[] vf, vb;    // furthest-reaching x per diagonal (forward / reverse search)
    int off;         // index of diagonal 0 in vf / vb
    Appender!(Edit[]) result;

    this(const(int)[] a, const(int)[] b) @safe pure nothrow
    {
        this.a = a;
        this.b = b;
        result = appender!(Edit[]);
    }

    void run() @safe pure nothrow
    {
        // Allocate the diagonal arrays for the largest sub-problem we will see.
        // Only the untrimmed core can ever reach the middle-snake search.
        size_t pre, suf;
        trim(0, a.length, 0, b.length, pre, suf);
        const n = a.length - pre - suf, m = b.length - pre - suf;
        off = cast(int) ((n + m + 1) / 2) + 2;
        vf = new int[2 * off + 2];
        vb = new int[2 * off + 2];
        result.reserve(a.length + b.length);
        solve(0, a.length, 0, b.length);
    }

    /// Length of the common prefix and (non-overlapping) common suffix.
    void trim(size_t a0, size_t a1, size_t b0, size_t b1, out size_t pre, out size_t suf)
        const @safe pure nothrow @nogc
    {
        const lim = (a1 - a0) < (b1 - b0) ? (a1 - a0) : (b1 - b0);
        while (pre < lim && a[a0 + pre] == b[b0 + pre])
            ++pre;
        const lim2 = lim - pre;
        while (suf < lim2 && a[a1 - 1 - suf] == b[b1 - 1 - suf])
            ++suf;
    }

    void solve(size_t a0, size_t a1, size_t b0, size_t b1) @safe pure nothrow
    {
        size_t pre, suf;
        trim(a0, a1, b0, b1, pre, suf);
        foreach (i; 0 .. pre)
            result.put(Edit(EditKind.keep, a0 + i));
        a0 += pre;
        b0 += pre;
        a1 -= suf;
        b1 -= suf;

        if (a0 == a1)
        {
            foreach (j; b0 .. b1)
                result.put(Edit(EditKind.insert, j));
        }
        else if (b0 == b1)
        {
            foreach (i; a0 .. a1)
                result.put(Edit(EditKind.remove, i));
        }
        else
        {
            // Both sides are non-empty and differ at both ends, so D >= 2
            // and each half below has a strictly smaller cost.
            const sn = middleSnake(a0, a1, b0, b1);
            solve(a0, a0 + sn.xs, b0, b0 + sn.ys);
            foreach (i; sn.xs .. sn.xe)
                result.put(Edit(EditKind.keep, a0 + i));
            solve(a0 + sn.xe, a1, b0 + sn.ye, b1);
        }

        foreach (i; 0 .. suf)
            result.put(Edit(EditKind.keep, a1 + i));
    }

    /// Finds the middle snake of the sub-problem a[a0..a1] x b[b0..b1].
    Snake middleSnake(size_t a0, size_t a1, size_t b0, size_t b1) @safe pure nothrow
    {
        const int n = cast(int) (a1 - a0), m = cast(int) (b1 - b0);
        const delta = n - m;
        const odd = (delta & 1) != 0;
        const maxD = (n + m + 1) / 2;
        const o = off;

        vf[o + 1] = 0;
        vb[o + 1] = 0;

        foreach (d; 0 .. maxD + 1)
        {
            // Forward search.
            for (int k = -d; k <= d; k += 2)
            {
                const i = o + k;
                int x = (k == -d || (k != d && vf[i - 1] < vf[i + 1])) ? vf[i + 1] : vf[i - 1] + 1;
                int y = x - k;
                const sx = x, sy = y;
                while (x < n && y < m && a[a0 + x] == b[b0 + y])
                {
                    ++x;
                    ++y;
                }
                vf[i] = x;
                if (odd)
                {
                    const rk = delta - k;
                    if (rk >= -(d - 1) && rk <= d - 1 && x + vb[o + rk] >= n)
                        return Snake(sx, sy, x, y);
                }
            }
            // Reverse search (coordinates measured from the end).
            for (int k = -d; k <= d; k += 2)
            {
                const i = o + k;
                int x = (k == -d || (k != d && vb[i - 1] < vb[i + 1])) ? vb[i + 1] : vb[i - 1] + 1;
                int y = x - k;
                const sx = x, sy = y;
                while (x < n && y < m && a[a1 - 1 - x] == b[b1 - 1 - y])
                {
                    ++x;
                    ++y;
                }
                vb[i] = x;
                if (!odd)
                {
                    const fk = delta - k;
                    if (fk >= -d && fk <= d && x + vf[o + fk] >= n)
                        return Snake(n - x, m - y, n - sx, m - sy);
                }
            }
        }
        assert(false, "middle snake not found");
    }
}

version (unittest)
{
    import std.random : Random, uniform;

    /// Reference LCS length by dynamic programming (tests only).
    size_t lcsLength(const(int)[] a, const(int)[] b)
    {
        auto prev = new size_t[b.length + 1];
        auto cur = new size_t[b.length + 1];
        foreach (i; 0 .. a.length)
        {
            cur[0] = 0;
            foreach (j; 0 .. b.length)
                cur[j + 1] = a[i] == b[j] ? prev[j] + 1
                    : (prev[j + 1] > cur[j] ? prev[j + 1] : cur[j]);
            auto t = prev; prev = cur; cur = t;
        }
        return prev[b.length];
    }

    /// Asserts that `script` is a valid, minimal script from a to b.
    void checkScript(const(int)[] a, const(int)[] b, const Edit[] script)
    {
        int[] ra, rb;
        foreach (e; script)
        {
            final switch (e.kind)
            {
            case EditKind.keep:
                ra ~= a[e.index];
                rb ~= a[e.index];
                break;
            case EditKind.remove:
                ra ~= a[e.index];
                break;
            case EditKind.insert:
                rb ~= b[e.index];
                break;
            }
        }
        assert(ra == a, "script does not reproduce A");
        assert(rb == b, "script does not reproduce B");
        assert(cost(script) == a.length + b.length - 2 * lcsLength(a, b), "script not minimal");
    }
}

unittest // edge cases
{
    foreach (c; [
        [cast(int[]) [], cast(int[]) []],
        [[], [1, 2, 3]],
        [[1, 2, 3], []],
        [[1], [1]],
        [[1], [2]],
        [[1, 2, 3], [1, 2, 3]],
        [[1, 2, 3, 4], [1, 4]],
        [[1, 4], [1, 2, 3, 4]],
        [[1, 2, 3], [4, 5, 6]],
        [[0, 1, 2, 0, 1, 1, 0], [2, 1, 0, 1, 0, 2]], // Myers' paper
        [[0, 0, 0, 1, 0, 0], [0, 1, 0, 0, 0, 1]],
        [[1, 2, 3, 4, 5, 6], [4, 5, 6, 1, 2, 3]],
    ])
        checkScript(c[0], c[1], diffIds(c[0], c[1]));
}

unittest // randomized against the DP reference
{
    auto rng = Random(12345);
    foreach (iter; 0 .. 20_000)
    {
        const alphabet = uniform(1, 6, rng);
        auto a = new int[uniform(0, 14, rng)];
        auto b = new int[uniform(0, 14, rng)];
        foreach (ref x; a) x = uniform(0, alphabet, rng);
        foreach (ref x; b) x = uniform(0, alphabet, rng);
        checkScript(a, b, diffIds(a, b));
    }
}

unittest // randomized, larger, with related sequences
{
    auto rng = Random(777);
    foreach (iter; 0 .. 300)
    {
        auto a = new int[uniform(0, 200, rng)];
        foreach (ref x; a) x = uniform(0, 12, rng);
        int[] b;
        foreach (x; a)
        {
            const r = uniform(0, 10, rng);
            if (r == 0) continue;
            if (r == 1) b ~= uniform(0, 12, rng);
            b ~= x;
        }
        checkScript(a, b, diffIds(a, b));
    }
}

unittest // worst case: fully disjoint
{
    auto a = new int[400];
    auto b = new int[300];
    foreach (i, ref x; a) x = cast(int) i;
    foreach (i, ref x; b) x = cast(int) (1000 + i);
    const s = diffIds(a, b);
    assert(cost(s) == 700);
}
