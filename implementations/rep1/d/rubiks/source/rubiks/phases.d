/**
 * The four phases of Thistlethwaite's algorithm as coordinate spaces, and the
 * breadth-first search that fills an exact distance table for each.
 *
 * Each phase type provides `size`, the list of allowed `moves` (move ids, in
 * trial order), `encode` (cube to coordinate) and `step` (coordinate and
 * move to coordinate, using only table lookups).  The move sets are closed
 * under inverses, so the distance from the goal equals the distance to it.
 */
module rubiks.phases;

import rubiks.coord;
import rubiks.cubie;
import rubiks.movetables;
import rubiks.moves;

/// Distance value of coordinates the search did not reach.
enum ubyte unreached = 0xFF;

private uint[] selectMoves(bool function(Face, int) pure nothrow @safe @nogc allowed) pure nothrow @safe
{
    uint[] r;
    foreach (m; 0 .. numMoves)
        if (allowed(cast(Face)(m / 3), m % 3 + 1))
            r ~= m;
    return r;
}

/// Move ids allowed in the phase.
immutable uint[] moves1 = selectMoves((f, t) => true);
/// Move ids allowed in the phase.
immutable uint[] moves2 = selectMoves((f, t) => (f != Face.F && f != Face.B) || t == 2);
/// Move ids allowed in the phase.
immutable uint[] moves3 = selectMoves((f, t) => f == Face.U || f == Face.D || t == 2);
/// Move ids allowed in the phase.
immutable uint[] moves4 = selectMoves((f, t) => t == 2);

/// Phase 1: G0 -> G1 = <U, D, L, R, F2, B2> (all edges oriented).
struct Phase1
{
    const(MoveTables) mt;
    enum uint size = numFlip;
    alias moves = moves1;
    uint encode(in CubieCube c) const { return flipCoord(c); }
    uint step(uint c, uint m) const { return mt.flip[c * numMoves + m]; }
}

/// Phase 2: G1 -> G2 = <U, D, L2, R2, F2, B2> (corners oriented, E-slice
/// edges in the E slice).
struct Phase2
{
    const(MoveTables) mt;
    enum uint size = numPhase2;
    alias moves = moves2;
    uint encode(in CubieCube c) const { return twistCoord(c) * numSlice + sliceCoord(c); }
    uint step(uint c, uint m) const
    {
        const t = c / numSlice, s = c % numSlice;
        return cast(uint) mt.twist[t * numMoves + m] * numSlice + mt.slice[s * numMoves + m];
    }
}

/// Phase 3: G2 -> G3 = <half turns> up to the corner/edge permutation parts
/// left for phase 4 (corners in the half-turn group, every edge in its slice).
struct Phase3
{
    const(MoveTables) mt;
    enum uint size = numPhase3;
    alias moves = moves3;
    uint encode(in CubieCube c) const
    {
        return mt.corners.classOf[rankPerm(c.cp[])] * numMSlice + mSliceCoord(c);
    }
    uint step(uint c, uint m) const
    {
        const k = c / numMSlice, s = c % numMSlice;
        return cast(uint) mt.cornerClass[k * numMoves + m] * numMSlice + mt.mSlice[s * numMoves + m];
    }
}

/// Phase 4: G3 -> solved, using half turns only.
struct Phase4
{
    const(MoveTables) mt;
    enum uint size = numPhase4;
    alias moves = moves4;
    uint encode(in CubieCube c) const
    {
        const h = mt.corners.halfIndex[rankPerm(c.cp[])];
        return ((h * numPerm4 + slicePermCoord(c, 0)) * numPerm4 + slicePermCoord(c, 1)) * numPerm4
            + slicePermCoord(c, 2);
    }
    uint step(uint c, uint m) const
    {
        const s2 = c % numPerm4;
        const s1 = (c / numPerm4) % numPerm4;
        const s0 = (c / (numPerm4 * numPerm4)) % numPerm4;
        const h = c / (numPerm4 * numPerm4 * numPerm4);
        return ((cast(uint) mt.cornerHalf[h * numMoves + m] * numPerm4
                + mt.slicePerm[0][s0 * numMoves + m]) * numPerm4
                + mt.slicePerm[1][s1 * numMoves + m]) * numPerm4
            + mt.slicePerm[2][s2 * numMoves + m];
    }
}

/**
 * Breadth-first search from the solved cube's coordinate over the phase's
 * moves.  Returns one byte per coordinate value: its exact distance from the
 * goal, or `unreached`.
 */
ubyte[] buildDistances(P)(const P phase)
{
    auto dist = new ubyte[P.size];
    dist[] = unreached;
    auto queue = new uint[P.size];
    size_t head, tail;
    const goal = phase.encode(CubieCube.init);
    dist[goal] = 0;
    queue[tail++] = goal;
    while (head < tail)
    {
        const c = queue[head++];
        const d = cast(ubyte)(dist[c] + 1);
        foreach (m; P.moves)
        {
            const n = phase.step(c, m);
            if (dist[n] == unreached)
            {
                dist[n] = d;
                queue[tail++] = n;
            }
        }
    }
    return dist;
}
