/// Basic edit-script types shared by the rest of the library.
module myersdiff.edit;

/// The three kinds of script operation. The enum value is the script tag character.
enum EditKind : char
{
    /// Keep the next line of A (it is also in B).
    keep = ' ',
    /// Delete the next line of A.
    remove = '-',
    /// Insert a line of B.
    insert = '+',
}

/**
 * One operation of an edit script.
 *
 * `index` is a zero-based line index: into A for `keep` and `remove`,
 * into B for `insert`.
 */
struct Edit
{
    EditKind kind;
    size_t index;
}

/// The cost of a script: the number of removals plus insertions.
size_t cost(scope const Edit[] script) @safe pure nothrow @nogc
{
    size_t n;
    foreach (e; script)
        if (e.kind != EditKind.keep)
            ++n;
    return n;
}

///
@safe pure nothrow unittest
{
    auto s = [Edit(EditKind.keep, 0), Edit(EditKind.remove, 1), Edit(EditKind.insert, 1)];
    assert(cost(s) == 2);
    assert(cost([]) == 0);
}
