/**
 * Coordinates: small integers describing one aspect of a cube's state.
 *
 * Each `Component` is a coordinate with a precomputed move table, so the
 * effect of a move on it is a single array lookup. The four phases of the
 * solver (see `rubiks.phase`) are built from these components.
 */
module rubiks.coords;

import rubiks.cubie;
import rubiks.move;

/// Sentinel stored in a move table for moves a component does not support.
enum uint invalidCoord = uint.max;

/**
 * One coordinate of the cube state together with its move table.
 *
 * `moveTable[value * moveCount + move.id]` is the coordinate after applying
 * the move, or `invalidCoord` if the move is not one of the moves the
 * component was built for.
 */
struct Component
{
    /// Number of distinct values, `0 .. size`.
    uint size;
    /// Transition table, `size * moveCount` entries.
    uint[] moveTable;
    /// Reads this coordinate from a cube.
    uint delegate(const CubieCube) pure nothrow rank;

    /// Coordinate after applying `m` to a state with coordinate `value`.
    uint next(uint value, Move m) const pure nothrow @safe @nogc
    {
        return moveTable[value * moveCount + m.id];
    }
}

/**
 * Builds a component from a rank function (cube to value) and an unrank
 * function (value to a representative cube). The move table is filled by
 * applying each allowed move to the representative of each value.
 */
Component buildComponent(uint size, const(Move)[] moves,
    CubieCube delegate(uint) pure nothrow unrank,
    uint delegate(const CubieCube) pure nothrow rank)
{
    auto table = new uint[size * moveCount];
    table[] = invalidCoord;
    foreach (v; 0 .. size)
        foreach (m; moves)
        {
            auto c = unrank(v);
            c.apply(m);
            table[v * moveCount + m.id] = rank(c);
        }
    return Component(size, table, rank);
}

/// Index of a permutation of `n <= 8` distinct values `0 .. n` in lexicographic order.
uint permutationRank(const(ubyte)[] p) pure nothrow @safe @nogc
{
    uint r = 0;
    foreach (i; 0 .. p.length)
    {
        uint smaller = 0;
        foreach (j; i + 1 .. p.length)
            if (p[j] < p[i])
                ++smaller;
        r = r * cast(uint)(p.length - i) + smaller;
    }
    return r;
}

/// Inverse of `permutationRank`: fills `p` with the permutation of rank `r`.
void permutationUnrank(uint r, ubyte[] p) pure nothrow @safe @nogc
{
    immutable n = p.length;
    uint[8] digits;
    foreach_reverse (i; 0 .. n)
    {
        immutable base = cast(uint)(n - i);
        digits[i] = r % base;
        r /= base;
    }
    ubyte[8] avail;
    foreach (i; 0 .. n)
        avail[i] = cast(ubyte) i;
    size_t left = n;
    foreach (i; 0 .. n)
    {
        p[i] = avail[digits[i]];
        foreach (j; digits[i] .. left - 1)
            avail[j] = avail[j + 1];
        --left;
    }
}

/// Numbering of the subsets of `bits` positions that have exactly `k` members.
struct Combinations
{
    uint[] indexOfMask; /// subset bitmask to index, `uint.max` if not a k-subset
    uint[] maskOfIndex; /// index to subset bitmask

    this(uint bits, uint k) pure nothrow @safe
    {
        import core.bitop : popcnt;

        indexOfMask = new uint[1 << bits];
        indexOfMask[] = uint.max;
        foreach (mask; 0 .. 1u << bits)
            if (popcnt(mask) == k)
            {
                indexOfMask[mask] = cast(uint) maskOfIndex.length;
                maskOfIndex ~= mask;
            }
    }

    /// Number of subsets.
    uint count() const pure nothrow @safe @nogc
    {
        return cast(uint) maskOfIndex.length;
    }
}

/// Edge orientation of the first 11 edges (the twelfth is determined): 2^11 values.
Component edgeOrientationComponent(const(Move)[] moves)
{
    uint rank(const CubieCube c) pure nothrow
    {
        uint r = 0;
        foreach (i; 0 .. 11)
            r = r * 2 + c.eo[i];
        return r;
    }

    CubieCube unrank(uint v) pure nothrow
    {
        CubieCube c;
        uint parity = 0;
        foreach_reverse (i; 0 .. 11)
        {
            c.eo[i] = v & 1;
            parity ^= v & 1;
            v >>= 1;
        }
        c.eo[11] = cast(ubyte) parity;
        return c;
    }

    return buildComponent(2048, moves, &unrank, &rank);
}

/// Orientation of the first 7 corners (the eighth is determined): 3^7 values.
Component cornerOrientationComponent(const(Move)[] moves)
{
    uint rank(const CubieCube c) pure nothrow
    {
        uint r = 0;
        foreach (i; 0 .. 7)
            r = r * 3 + c.co[i];
        return r;
    }

    CubieCube unrank(uint v) pure nothrow
    {
        CubieCube c;
        uint sum = 0;
        foreach_reverse (i; 0 .. 7)
        {
            c.co[i] = cast(ubyte)(v % 3);
            sum += v % 3;
            v /= 3;
        }
        c.co[7] = cast(ubyte)((3 - sum % 3) % 3);
        return c;
    }

    return buildComponent(2187, moves, &unrank, &rank);
}

/**
 * Which four of the twelve edge positions hold the E-slice cubies (FR, FL,
 * BL, BR): C(12, 4) = 495 values, numbered in increasing bitmask order.
 */
Component eSliceComponent(const(Move)[] moves, Combinations combos)
{
    uint rank(const CubieCube c) pure nothrow
    {
        uint mask = 0;
        foreach (i; 0 .. 12)
            if (c.ep[i] >= 8)
                mask |= 1u << i;
        return combos.indexOfMask[mask];
    }

    CubieCube unrank(uint v) pure nothrow
    {
        immutable mask = combos.maskOfIndex[v];
        CubieCube c;
        ubyte slice = 8, other = 0;
        foreach (i; 0 .. 12)
            c.ep[i] = (mask >> i) & 1 ? slice++ : other++;
        return c;
    }

    return buildComponent(combos.count, moves, &unrank, &rank);
}

/**
 * Among the eight U/D-layer edge positions (0..7), which four hold the
 * M-slice cubies (UF, UB, DF, DB; the odd cubie numbers): C(8, 4) = 70
 * values. Only valid while the E-slice cubies stay in the E slice.
 */
Component mSliceComponent(const(Move)[] moves, Combinations combos)
{
    uint rank(const CubieCube c) pure nothrow
    {
        uint mask = 0;
        foreach (i; 0 .. 8)
            if (c.ep[i] & 1)
                mask |= 1u << i;
        return combos.indexOfMask[mask];
    }

    CubieCube unrank(uint v) pure nothrow
    {
        immutable mask = combos.maskOfIndex[v];
        CubieCube c;
        ubyte odd = 1, even = 0;
        foreach (i; 0 .. 8)
        {
            if ((mask >> i) & 1)
            {
                c.ep[i] = odd;
                odd += 2;
            }
            else
            {
                c.ep[i] = even;
                even += 2;
            }
        }
        return c;
    }

    return buildComponent(combos.count, moves, &unrank, &rank);
}

/**
 * The permutation of the four edges of one slice within that slice's four
 * positions: 24 values. `positions` lists the slice's edge positions in
 * increasing order; the slice's cubies carry the same numbers.
 */
Component slicePermutationComponent(const(Move)[] moves, immutable(ubyte)[4] positions)
{
    ubyte[12] local = ubyte.max;
    foreach (k, p; positions)
        local[p] = cast(ubyte) k;

    uint rank(const CubieCube c) pure nothrow
    {
        ubyte[4] q;
        foreach (k; 0 .. 4)
        {
            q[k] = local[c.ep[positions[k]]];
            assert(q[k] < 4, "edge is outside its slice");
        }
        return permutationRank(q[]);
    }

    CubieCube unrank(uint v) pure nothrow
    {
        ubyte[4] q;
        permutationUnrank(v, q[]);
        CubieCube c;
        foreach (k; 0 .. 4)
            c.ep[positions[k]] = positions[q[k]];
        return c;
    }

    return buildComponent(24, moves, &unrank, &rank);
}

/**
 * The corner permutations that the half-turn group <U2, D2, L2, R2, F2, B2>
 * can produce (96 of them), and the classes ("cosets") the 8! = 40320 corner
 * permutations fall into modulo that group (420 of them).
 *
 * Two corner arrays `p` and `q` are in the same class iff `q = h o p` for a
 * half-turn permutation `h`, i.e. `q[i] = h[p[i]]`. Because moves act as
 * `p'[i] = p[m[i]]`, the class of the result depends only on the class of `p`
 * and on `m`.
 */
final class CornerGroup
{
    /// The 96 half-turn corner permutations, by index.
    immutable(ubyte[8])[] halfTurnPerms;
    /// Index into `halfTurnPerms` for a permutation rank, or 0xFFFF.
    ushort[] halfTurnIndex;
    /// Class number (0 .. 419) for a permutation rank.
    ushort[] classOf;
    /// One permutation per class.
    immutable(ubyte[8])[] classRepresentative;

    this() pure nothrow @safe
    {
        enum perms = 40320;
        halfTurnIndex = new ushort[perms];
        halfTurnIndex[] = 0xFFFF;
        classOf = new ushort[perms];
        classOf[] = 0xFFFF;

        // Closure of the identity under the six half turns.
        immutable(ubyte[8])[] found;
        found ~= cast(immutable) CubieCube.init.cp;
        halfTurnIndex[permutationRank(found[0][])] = 0;
        for (size_t head = 0; head < found.length; ++head)
        {
            foreach (m; allMoves)
            {
                if (!m.isHalfTurn)
                    continue;
                ubyte[8] q;
                foreach (i; 0 .. 8)
                    q[i] = found[head][basicMoves[m.id].cp[i]];
                immutable r = permutationRank(q[]);
                if (halfTurnIndex[r] == 0xFFFF)
                {
                    halfTurnIndex[r] = cast(ushort) found.length;
                    found ~= cast(immutable) q;
                }
            }
        }
        halfTurnPerms = found;

        foreach (r; 0 .. perms)
        {
            if (classOf[r] != 0xFFFF)
                continue;
            ubyte[8] p;
            permutationUnrank(r, p[]);
            immutable cls = cast(ushort) classRepresentative.length;
            classRepresentative ~= cast(immutable) p;
            foreach (ref h; halfTurnPerms)
            {
                ubyte[8] q;
                foreach (i; 0 .. 8)
                    q[i] = h[p[i]];
                classOf[permutationRank(q[])] = cls;
            }
        }
    }

    /// Number of corner permutation classes.
    size_t classCount() const pure nothrow @safe @nogc
    {
        return classRepresentative.length;
    }
}

/// Class of the corner permutation modulo the half-turn group: 420 values.
Component cornerClassComponent(const(Move)[] moves, CornerGroup group)
{
    uint rank(const CubieCube c) pure nothrow
    {
        return group.classOf[permutationRank(c.cp[])];
    }

    CubieCube unrank(uint v) pure nothrow
    {
        CubieCube c;
        c.cp = group.classRepresentative[v];
        return c;
    }

    return buildComponent(cast(uint) group.classCount, moves, &unrank, &rank);
}

/// Which of the 96 half-turn corner permutations the cube's corners are in.
Component cornerHalfTurnComponent(const(Move)[] moves, CornerGroup group)
{
    uint rank(const CubieCube c) pure nothrow
    {
        immutable i = group.halfTurnIndex[permutationRank(c.cp[])];
        assert(i != 0xFFFF, "corners are outside the half-turn group");
        return i;
    }

    CubieCube unrank(uint v) pure nothrow
    {
        CubieCube c;
        c.cp = group.halfTurnPerms[v];
        return c;
    }

    return buildComponent(cast(uint) group.halfTurnPerms.length, moves, &unrank, &rank);
}

unittest
{
    // Lehmer code round trip.
    foreach (n; [1, 4, 8])
    {
        ubyte[8] p;
        immutable count = n == 1 ? 1 : n == 4 ? 24 : 40320;
        foreach (r; 0 .. count)
        {
            permutationUnrank(r, p[0 .. n]);
            assert(permutationRank(p[0 .. n]) == r);
        }
    }
    ubyte[4] id = [0, 1, 2, 3];
    assert(permutationRank(id[]) == 0);
    ubyte[4] rev = [3, 2, 1, 0];
    assert(permutationRank(rev[]) == 23);
}

unittest
{
    auto c = Combinations(12, 4);
    assert(c.count == 495);
    auto d = Combinations(8, 4);
    assert(d.count == 70);
    foreach (i; 0 .. d.count)
        assert(d.indexOfMask[d.maskOfIndex[i]] == i);
}

unittest
{
    auto g = new CornerGroup;
    assert(g.halfTurnPerms.length == 96);
    assert(g.classCount == 420);
    // The classes partition all permutations evenly.
    auto sizes = new size_t[g.classCount];
    foreach (c; g.classOf)
        ++sizes[c];
    foreach (s; sizes)
        assert(s == 96);
}

unittest
{
    // Move tables are consistent: coordinates stay in range, the solved cube
    // has the coordinate it should, and undoing a move undoes its effect.
    auto combos12 = Combinations(12, 4);
    auto combos8 = Combinations(8, 4);
    auto group = new CornerGroup;
    immutable(ubyte)[4] mPos = [1, 3, 5, 7];
    Move[] all = allMoves[].dup;
    Move[] halves;
    foreach (m; allMoves)
        if (m.isHalfTurn)
            halves ~= m;

    Component[] comps = [
        edgeOrientationComponent(all),
        cornerOrientationComponent(all),
        eSliceComponent(all, combos12),
        mSliceComponent(halves, combos8),
        slicePermutationComponent(halves, mPos),
        cornerClassComponent(all, group),
        cornerHalfTurnComponent(halves, group),
    ];
    immutable uint[] sizes = [2048, 2187, 495, 70, 24, 420, 96];
    foreach (k, ref c; comps)
    {
        assert(c.size == sizes[k]);
        immutable solved = c.rank(CubieCube.solved);
        assert(solved < c.size);
        foreach (v; 0 .. c.size)
            foreach (m; (k == 3 || k == 4 || k == 6) ? halves : all)
            {
                immutable n = c.next(v, m);
                assert(n < c.size);
                assert(c.next(n, m.inverse) == v);
            }
        // Tracking a cube move by move agrees with ranking the cube.
        auto cube = CubieCube.solved;
        uint v = solved;
        foreach (m; (k == 3 || k == 4 || k == 6) ? halves : all)
        {
            cube.apply(m);
            v = c.next(v, m);
            assert(v == c.rank(cube));
        }
    }
}
