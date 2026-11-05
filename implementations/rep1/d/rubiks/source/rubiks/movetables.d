/**
 * Per-component move tables: for each component of a phase coordinate, a
 * table `value x move -> value`.  Each is built by decoding a value into a
 * representative, applying the move once and re-encoding.  Tables are indexed
 * `value * numMoves + move.id`.  Entries for moves that are not valid for the
 * component (see each field) are `ushort.max` (or `ubyte.max`).
 */
module rubiks.movetables;

import rubiks.coord;
import rubiks.cubie;
import rubiks.moves;

/// All component move tables, built once.
final class MoveTables
{
    /// Corner permutation groups used by phases 3 and 4.
    CornerGroup corners;

    /// Edge orientation (phase 1), all moves.
    ushort[] flip;
    /// Corner orientation (phase 2), all moves.
    ushort[] twist;
    /// E-slice position set (phase 2), all moves.
    ushort[] slice;
    /// Corner half-turn class (phase 3), all moves.
    ushort[] cornerClass;
    /// M-slice positions in the U/D layers (phase 3); valid only for moves
    /// that keep the E slice in place (U, D and half turns).
    ushort[] mSlice;
    /// Index in the half-turn corner group (phase 4); valid for half turns.
    ubyte[] cornerHalf;
    /// Permutation of each slice (phase 4); valid for half turns.
    ubyte[][3] slicePerm;

    /// Builds every table.
    this()
    {
        corners = new CornerGroup;
        buildFlip();
        buildTwist();
        buildSlice();
        buildCornerClass();
        buildMSlice();
        buildCornerHalf();
        foreach (s; 0 .. 3)
            buildSlicePerm(s);
    }

    private void buildFlip()
    {
        flip = new ushort[numFlip * numMoves];
        foreach (v; 0 .. numFlip)
        {
            ubyte[12] eo;
            uint parity;
            foreach (i; 0 .. 11)
            {
                eo[i] = (v >> i) & 1;
                parity ^= eo[i];
            }
            eo[11] = cast(ubyte) parity;
            foreach (m; 0 .. numMoves)
            {
                const mc = &moveCubes[m];
                uint n;
                foreach (i; 0 .. 11)
                    n |= cast(uint)(eo[mc.ep[i]] ^ mc.eo[i]) << i;
                flip[v * numMoves + m] = cast(ushort) n;
            }
        }
    }

    private void buildTwist()
    {
        twist = new ushort[numTwist * numMoves];
        foreach (v; 0 .. numTwist)
        {
            ubyte[8] co;
            uint t = v, sum;
            foreach (i; 0 .. 7)
            {
                co[i] = cast(ubyte)(t % 3);
                t /= 3;
                sum += co[i];
            }
            co[7] = cast(ubyte)((3 - sum % 3) % 3);
            foreach (m; 0 .. numMoves)
            {
                const mc = &moveCubes[m];
                uint n;
                foreach_reverse (i; 0 .. 7)
                    n = n * 3 + (co[mc.cp[i]] + mc.co[i]) % 3;
                twist[v * numMoves + m] = cast(ushort) n;
            }
        }
    }

    private void buildSlice()
    {
        slice = new ushort[numSlice * numMoves];
        foreach (r; 0 .. numSlice)
        {
            const mask = subsets12.masks[r];
            foreach (m; 0 .. numMoves)
            {
                const mc = &moveCubes[m];
                uint n;
                foreach (i; 0 .. 12)
                    if (mask & (1u << mc.ep[i]))
                        n |= 1u << i;
                slice[r * numMoves + m] = subsets12.rank[n];
            }
        }
    }

    private void buildCornerClass()
    {
        cornerClass = new ushort[numCornerClasses * numMoves];
        foreach (c; 0 .. numCornerClasses)
        {
            ubyte[8] p = void;
            unrankPerm(corners.classRep[c], p[]);
            foreach (m; 0 .. numMoves)
            {
                const mc = &moveCubes[m];
                ubyte[8] q = void;
                foreach (i; 0 .. 8)
                    q[i] = p[mc.cp[i]];
                cornerClass[c * numMoves + m] = corners.classOf[rankPerm(q[])];
            }
        }
    }

    private void buildMSlice()
    {
        mSlice = new ushort[numMSlice * numMoves];
        mSlice[] = ushort.max;
        foreach (r; 0 .. numMSlice)
        {
            const mask = subsets8.masks[r];
            foreach (m; 0 .. numMoves)
            {
                const mc = &moveCubes[m];
                bool closed = true;
                uint n;
                foreach (i; 0 .. 8)
                {
                    if (mc.ep[i] >= 8)
                        closed = false;
                    else if (mask & (1u << mc.ep[i]))
                        n |= 1u << i;
                }
                if (closed)
                    mSlice[r * numMoves + m] = subsets8.rank[n];
            }
        }
    }

    private void buildCornerHalf()
    {
        cornerHalf = new ubyte[numHalfCorners * numMoves];
        cornerHalf[] = ubyte.max;
        foreach (h; 0 .. numHalfCorners)
            foreach (f; 0 .. numFaces)
            {
                const m = f * 3 + 1; // half turn
                const mc = &moveCubes[m];
                ubyte[8] q = void;
                foreach (i; 0 .. 8)
                    q[i] = corners.halfPerms[h][mc.cp[i]];
                cornerHalf[h * numMoves + m] = corners.halfIndex[rankPerm(q[])];
            }
    }

    private void buildSlicePerm(uint s)
    {
        auto table = new ubyte[numPerm4 * numMoves];
        table[] = ubyte.max;
        foreach (r; 0 .. numPerm4)
        {
            ubyte[4] perm = void;
            unrankPerm(r, perm[]);
            foreach (f; 0 .. numFaces)
            {
                const m = f * 3 + 1;
                const mc = &moveCubes[m];
                ubyte[4] q = void;
                bool closed = true;
                foreach (k; 0 .. 4)
                {
                    const l = indexInSlice(s, mc.ep[slicePositions[s][k]]);
                    if (l < 0)
                        closed = false;
                    else
                        q[k] = perm[l];
                }
                if (closed)
                    table[r * numMoves + m] = cast(ubyte) rankPerm(q[]);
            }
        }
        slicePerm[s] = table;
    }
}
