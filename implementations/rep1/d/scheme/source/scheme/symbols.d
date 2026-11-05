/// Symbol interning: every distinct symbol name maps to a dense integer id.
module scheme.symbols;

/// Ids of the names the compiler recognises. They are interned first, in this
/// order, by every `SymbolTable`.
enum Known : int
{
    quote, if_, define, set, lambda, let, letStar, letrec, begin, cond,
    and, or, else_,
    count,
}

private immutable string[Known.count] knownNames = [
    "quote", "if", "define", "set!", "lambda", "let", "let*", "letrec",
    "begin", "cond", "and", "or", "else",
];

/// Maps symbol names to ids and back.
final class SymbolTable
{
    private int[string] ids;
    private string[] names;

    this()
    {
        foreach (n; knownNames)
            intern(n);
    }

    /// Id of `name`, adding it if new.
    int intern(string name)
    {
        if (auto p = name in ids)
            return *p;
        int id = cast(int) names.length;
        names ~= name;
        ids[name] = id;
        return id;
    }

    /// The name of symbol `id`.
    string name(int id) const { return names[id]; }

    /// Number of symbols interned so far.
    size_t length() const { return names.length; }
}
