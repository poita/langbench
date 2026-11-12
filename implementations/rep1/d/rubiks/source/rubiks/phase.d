/**
 * One phase of Thistlethwaite's algorithm.
 *
 * A phase works on a composite coordinate (a mixed-radix combination of
 * `Component`s) that identifies the cube's coset of the next subgroup, using
 * a restricted set of moves. A breadth-first search from the goal coordinate
 * fills a table with the exact number of moves needed from every coordinate
 * value, so a solution is found by greedy descent: repeatedly apply any move
 * that leads to a coordinate one step closer.
 */
module rubiks.phase;

import rubiks.coords;
import rubiks.cubie;
import rubiks.move;

/// Distance-table entry for coordinate values the phase's moves cannot reach.
enum ubyte unreachable = ubyte.max;

/// A phase: coordinate layout, allowed moves and exact distance table.
final class Phase
{
    /// Human-readable name, e.g. "phase 2".
    string name;
    /// Moves this phase may use.
    immutable(Move)[] moves;
    /// Coordinate components, most significant first.
    Component[] components;
    /// Moves-to-goal for every coordinate value (`unreachable` if none).
    ubyte[] distance;
    /// The coordinate of the goal (the solved cube).
    uint goal;

    /**
     * Builds the phase and runs the breadth-first search from the goal.
     * `components` must have been built for exactly `moves`.
     */
    this(string name, immutable(Move)[] moves, Component[] components)
    {
        this.name = name;
        this.moves = moves;
        this.components = components;
        size_t total = 1;
        foreach (c; components)
            total *= c.size;
        distance = new ubyte[total];
        distance[] = unreachable;
        goal = coordinate(CubieCube.solved);
        fill();
    }

    /// Number of distinct coordinate values.
    size_t size() const pure nothrow @safe @nogc
    {
        return distance.length;
    }

    /// The composite coordinate of a cube.
    uint coordinate(const CubieCube cube) const
    {
        uint r = 0;
        foreach (c; components)
            r = r * c.size + c.rank(cube);
        return r;
    }

    /// The coordinate reached from `coord` by move `m` (which must be in `moves`).
    uint next(uint coord, Move m) const pure nothrow @safe @nogc
    {
        uint result = 0, scale = 1;
        foreach_reverse (ref c; components)
        {
            immutable digit = coord % c.size;
            coord /= c.size;
            result += c.next(digit, m) * scale;
            scale *= c.size;
        }
        return result;
    }

    /// Largest finite entry of the distance table.
    uint maxDistance() const pure nothrow @safe @nogc
    {
        ubyte best = 0;
        foreach (d; distance)
            if (d != unreachable && d > best)
                best = d;
        return best;
    }

    /// Number of coordinate values reachable from the goal.
    size_t reachableCount() const pure nothrow @safe @nogc
    {
        size_t n;
        foreach (d; distance)
            n += d != unreachable;
        return n;
    }

    /**
     * Greedy descent: appends to `output` the moves that take `cube` to the
     * goal, applying them to `cube` as it goes. Returns false (leaving `cube`
     * untouched) if the cube is not in the set of states this phase solves.
     */
    bool descend(ref CubieCube cube, ref Move[] output) const
    {
        uint coord = coordinate(cube);
        ubyte d = distance[coord];
        if (d == unreachable)
            return false;
        while (d > 0)
        {
            bool stepped;
            foreach (m; moves)
            {
                immutable n = next(coord, m);
                if (distance[n] == d - 1)
                {
                    output ~= m;
                    cube.apply(m);
                    coord = n;
                    --d;
                    stepped = true;
                    break;
                }
            }
            assert(stepped, "distance table is inconsistent");
        }
        return true;
    }

private:

    void fill()
    {
        auto queue = new uint[distance.length];
        size_t head = 0, tail = 0;
        distance[goal] = 0;
        queue[tail++] = goal;
        while (head < tail)
        {
            immutable cur = queue[head++];
            immutable nd = cast(ubyte)(distance[cur] + 1);
            foreach (m; moves)
            {
                immutable n = next(cur, m);
                if (distance[n] == unreachable)
                {
                    distance[n] = nd;
                    queue[tail++] = n;
                }
            }
        }
    }
}
