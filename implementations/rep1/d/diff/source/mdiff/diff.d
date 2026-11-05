/// High-level diff entry point: lines in, minimal edit script out.
module mdiff.diff;

import mdiff.edit;
import mdiff.intern;
import mdiff.myers;

/**
 * Computes a minimal edit script turning the lines `a` into the lines `b`.
 *
 * Lines are compared byte for byte. The returned edits refer to lines by
 * index (see $(REF Edit, mdiff.edit)). Time is O((N+M)·D) and space O(N+M).
 */
Edit[] diffLines(scope const(const(char)[])[] a, scope const(const(char)[])[] b) @safe
{
    Interner interner;
    auto ia = interner.internAll(a);
    auto ib = interner.internAll(b);
    return shortestEdits(ia, ib);
}
