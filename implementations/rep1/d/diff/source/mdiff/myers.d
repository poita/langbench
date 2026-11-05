/**
 * Exact shortest edit scripts by Myers' linear-space algorithm.
 *
 * This is the divide-and-conquer ("middle snake") variant of E. Myers,
 * "An O(ND) Difference Algorithm and Its Variations" (1986), section 4b:
 * $(UL
 *   $(LI time O((N+M)·D), where D is the minimal edit cost;)
 *   $(LI space O(N+M): two frontier arrays shared by every recursive call;)
 *   $(LI always exact: no heuristics, cut-offs or anchoring.)
 * )
 * Sequences are arrays of integer ids (see $(REF Interner, mdiff.intern)), so
 * every comparison in the search is one integer comparison.
 */
module mdiff.myers;

import mdiff.edit;

/**
 * Computes a minimal edit script turning `a` into `b`.
 *
 * Returns the operations in script order. The cost of the result is
 * `a.length + b.length - 2 * LCS(a, b)`.
 */
Edit[] shortestEdits(scope const(int)[] a, scope const(int)[] b) @safe
{
    auto s = Searcher(a, b);
    return s.run();
}

private:

enum int invalid = -1; // "diagonal not reachable" marker in frontier arrays

struct Snake
{
    int x, y; // start (absolute coordinates)
    int u, v; // end; the diagonal run from (x,y) to (u,v) is all matches
}

struct Searcher
{
    const(int)[] a, b;
    int[] vf, vb; // forward / backward frontiers, indexed by diagonal + off
    int off;
    Edit[] ops;

    this(const(int)[] a_, const(int)[] b_) @safe
    {
        a = a_;
        b = b_;
        immutable half = (cast(int) a.length + cast(int) b.length + 1) / 2;
        off = half + 2;
        vf = new int[2 * off + 1];
        vb = new int[2 * off + 1];
        ops.reserve(a.length + b.length);
    }

    Edit[] run() @safe
    {
        solve(0, cast(int) a.length, 0, cast(int) b.length);
        return ops;
    }

    void keep(int i) @safe
    {
        ops ~= Edit(EditKind.keep, i);
    }

    /// Emits the script for the rectangle A[a0..a1) x B[b0..b1).
    void solve(int a0, int a1, int b0, int b1) @safe
    {
        // Common prefix: emitted at once. Common suffix: emitted at the end.
        while (a0 < a1 && b0 < b1 && a[a0] == b[b0])
        {
            keep(a0);
            ++a0;
            ++b0;
        }
        int suffix;
        while (a0 < a1 && b0 < b1 && a[a1 - 1] == b[b1 - 1])
        {
            --a1;
            --b1;
            ++suffix;
        }

        if (a0 == a1)
        {
            foreach (j; b0 .. b1)
                ops ~= Edit(EditKind.insert, j);
        }
        else if (b0 == b1)
        {
            foreach (i; a0 .. a1)
                ops ~= Edit(EditKind.remove, i);
        }
        else
        {
            // Both sides non-empty after trimming, so the cost is >= 2 and
            // the middle snake splits it into two strictly cheaper parts.
            immutable s = middleSnake(a0, a1, b0, b1);
            solve(a0, s.x, b0, s.y);
            foreach (i; s.x .. s.u)
                keep(i);
            solve(s.u, a1, s.v, b1);
        }

        foreach (i; 0 .. suffix)
            keep(a1 + i);
    }

    /**
     * Finds the middle snake of the (non-trivial) rectangle: runs the greedy
     * furthest-reaching search forward from the top-left corner and backward
     * from the bottom-right corner, one edit per round each, until the two
     * frontiers meet. The backward search runs in reversed coordinates
     * (distance from the bottom-right corner).
     *
     * Only frontier entries written in the current call are ever read, which
     * is why the reused arrays never need clearing.
     */
    Snake middleSnake(int a0, int a1, int b0, int b1) @safe
    {
        immutable n = a1 - a0, m = b1 - b0, delta = n - m;
        immutable odd = (delta & 1) != 0;
        immutable dmax = (n + m + 1) / 2;

        vf[off - 1] = invalid;
        vf[off + 1] = 0;
        vb[off - 1] = invalid;
        vb[off + 1] = 0;

        foreach (d; 0 .. dmax + 1)
        {
            if (d > 0)
            {
                vf[off - d - 1] = invalid;
                vf[off + d + 1] = invalid;
                vb[off - d - 1] = invalid;
                vb[off + d + 1] = invalid;
            }

            // Forward round d.
            for (int k = -d; k <= d; k += 2)
            {
                int xr = vf[off + k - 1]; // step right (delete from A)
                xr = xr >= 0 && xr + 1 <= n ? xr + 1 : invalid;
                int xd = vf[off + k + 1]; // step down (insert from B)
                if (xd >= 0 && xd - k > m)
                    xd = invalid;
                int x = xr > xd ? xr : xd;
                if (x < 0)
                {
                    vf[off + k] = invalid;
                    continue;
                }
                int y = x - k;
                immutable sx = x, sy = y;
                while (x < n && y < m && a[a0 + x] == b[b0 + y])
                {
                    ++x;
                    ++y;
                }
                vf[off + k] = x;

                if (odd)
                {
                    // Backward frontier of round d-1 spans |diagonal| <= d-1.
                    immutable kb = delta - k;
                    if (kb >= -(d - 1) && kb <= d - 1)
                    {
                        immutable xb = vb[off + kb];
                        if (xb >= 0 && x + xb >= n)
                            return Snake(a0 + sx, b0 + sy, a0 + x, b0 + y);
                    }
                }
            }

            // Backward round d (reversed coordinates).
            for (int k = -d; k <= d; k += 2)
            {
                int xr = vb[off + k - 1];
                xr = xr >= 0 && xr + 1 <= n ? xr + 1 : invalid;
                int xd = vb[off + k + 1];
                if (xd >= 0 && xd - k > m)
                    xd = invalid;
                int x = xr > xd ? xr : xd;
                if (x < 0)
                {
                    vb[off + k] = invalid;
                    continue;
                }
                int y = x - k;
                immutable sx = x, sy = y;
                while (x < n && y < m && a[a1 - 1 - x] == b[b1 - 1 - y])
                {
                    ++x;
                    ++y;
                }
                vb[off + k] = x;

                if (!odd)
                {
                    // Forward frontier of round d spans |diagonal| <= d.
                    immutable kf = delta - k;
                    if (kf >= -d && kf <= d)
                    {
                        immutable xf = vf[off + kf];
                        if (xf >= 0 && xf + x >= n)
                            return Snake(a1 - x, b1 - y, a1 - sx, b1 - sy);
                    }
                }
            }
        }
        assert(0, "middle snake not found"); // unreachable: the frontiers must meet
    }
}
