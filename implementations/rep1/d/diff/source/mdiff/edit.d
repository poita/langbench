/// Edit operations: the in-memory representation of an edit script.
module mdiff.edit;

/// What an edit does to the next line of the old file / the new file.
enum EditKind : ubyte
{
    /// The line is present in both files.
    keep,
    /// The line of the old file (A) is removed.
    remove,
    /// A line of the new file (B) is added.
    insert,
}

/**
 * One step of an edit script.
 *
 * `index` is the line number (0-based) in the old file for `keep` and
 * `remove`, and in the new file for `insert`. Line text is never copied into
 * an edit; render it with $(REF appendScript, mdiff.script).
 */
struct Edit
{
    EditKind kind;
    int index;
}

/// The one-character tag used for `kind` in the textual script format.
char tagOf(EditKind kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
    case EditKind.keep:   return ' ';
    case EditKind.remove: return '-';
    case EditKind.insert: return '+';
    }
}

/// The cost of a script: its number of removals plus insertions.
size_t cost(scope const(Edit)[] edits) @safe pure nothrow @nogc
{
    size_t c;
    foreach (e; edits)
        if (e.kind != EditKind.keep)
            ++c;
    return c;
}

@safe pure nothrow @nogc unittest
{
    assert(tagOf(EditKind.keep) == ' ');
    assert(tagOf(EditKind.remove) == '-');
    assert(tagOf(EditKind.insert) == '+');
    immutable Edit[3] es = [Edit(EditKind.keep, 0), Edit(EditKind.remove, 1), Edit(EditKind.insert, 0)];
    assert(cost(es[]) == 2);
}
