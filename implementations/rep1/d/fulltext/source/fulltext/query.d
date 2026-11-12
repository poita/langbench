/**
 * The query language: lexer, recursive-descent parser and the query tree.
 *
 * ```
 * query := or
 * or    := and ( "OR" and )*
 * and   := ( "AND" | not )*
 * not   := "NOT"* primary
 * primary := "(" or ")" | atom
 * ```
 *
 * Parsing never fails: malformed input is recovered from by the rules in
 * the specification. The empty tree is represented by a `null` $(LREF Node).
 */
module fulltext.query;

import fulltext.analysis;

@safe:

/// A search atom: the analysed terms of a word or quoted phrase. An atom
/// matches where its terms occur at consecutive positions.
struct Atom
{
    /// Index terms, at least one.
    immutable(string)[] terms;

    /// Number of terms.
    @property size_t length() const pure nothrow @nogc { return terms.length; }

    bool opEquals(const Atom o) const pure nothrow @nogc
    {
        return terms == o.terms;
    }

    /// A string that is equal for equal atoms; usable as an AA key.
    string key() const pure nothrow
    {
        string k;
        foreach (t; terms)
            k ~= t ~ "\0";
        return k;
    }
}

/// Kinds of query tree node.
enum NodeKind
{
    atom, /// leaf holding an $(LREF Atom)
    and,  /// intersection of children
    or,   /// union of children
    not,  /// complement of its single child
}

/// A node of the query tree.
final class Node
{
    NodeKind kind;
    Atom atom;          /// valid when `kind == NodeKind.atom`
    Node[] children;    /// operands for `and`, `or`, `not`

    this(NodeKind kind, Atom atom = Atom.init, Node[] children = null) pure nothrow
    {
        this.kind = kind;
        this.atom = atom;
        this.children = children;
    }
}

/**
 * Builds the atom for a phrase body: analyses it like document text. Returns
 * `false` (an empty atom) when it has no terms, or exactly one term whose
 * token text is a stop word.
 */
bool makeAtom(string body_, out Atom atom) pure
{
    auto toks = analyze(body_);
    if (toks.length == 0)
        return false;
    if (toks.length == 1 && isStopWord(toks[0].folded))
        return false;
    string[] terms;
    foreach (t; toks)
        terms ~= t.term;
    atom = Atom(terms.idup);
    return true;
}

private enum TokKind { lparen, rparen, phrase, and, or, not }

private struct QTok
{
    TokKind kind;
    string body_;
}

private QTok[] lex(string q) pure
{
    import std.utf : decode;

    QTok[] toks;
    size_t i = 0;
    while (i < q.length)
    {
        size_t j = i;
        immutable c = decode(q, j);
        if (isSpace(c))
        {
            i = j;
        }
        else if (c == '(')
        {
            toks ~= QTok(TokKind.lparen);
            i = j;
        }
        else if (c == ')')
        {
            toks ~= QTok(TokKind.rparen);
            i = j;
        }
        else if (c == '"')
        {
            size_t k = j;
            while (k < q.length && q[k] != '"')
                k++;
            toks ~= QTok(TokKind.phrase, q[j .. k]);
            i = k < q.length ? k + 1 : k;
        }
        else
        {
            size_t k = i;
            while (k < q.length)
            {
                size_t m = k;
                immutable d = decode(q, m);
                if (isSpace(d) || d == '(' || d == ')' || d == '"')
                    break;
                k = m;
            }
            immutable word = q[i .. k];
            switch (word)
            {
                case "AND": toks ~= QTok(TokKind.and); break;
                case "OR": toks ~= QTok(TokKind.or); break;
                case "NOT": toks ~= QTok(TokKind.not); break;
                default: toks ~= QTok(TokKind.phrase, word);
            }
            i = k;
        }
    }
    return toks;
}

private struct Parser
{
    QTok[] toks;
    size_t pos;

    bool atEnd() const pure nothrow @nogc { return pos >= toks.length; }

    static Node combine(NodeKind kind, Node[] parts) pure nothrow
    {
        Node[] kept;
        foreach (p; parts)
            if (p !is null)
                kept ~= p;
        if (kept.length == 0)
            return null;
        if (kept.length == 1)
            return kept[0];
        return new Node(kind, Atom.init, kept);
    }

    Node parseOr() pure
    {
        Node[] parts = [parseAnd()];
        while (!atEnd && toks[pos].kind == TokKind.or)
        {
            pos++;
            parts ~= parseAnd();
        }
        return combine(NodeKind.or, parts);
    }

    Node parseAnd() pure
    {
        Node[] parts;
        while (!atEnd)
        {
            immutable k = toks[pos].kind;
            if (k == TokKind.rparen || k == TokKind.or)
                break;
            if (k == TokKind.and)
            {
                pos++;
                continue;
            }
            parts ~= parseNot();
        }
        return combine(NodeKind.and, parts);
    }

    Node parseNot() pure
    {
        size_t count = 0;
        while (!atEnd && toks[pos].kind == TokKind.not)
        {
            pos++;
            count++;
        }
        auto p = parsePrimary();
        if (p is null)
            return null;
        foreach (_; 0 .. count)
            p = new Node(NodeKind.not, Atom.init, [p]);
        return p;
    }

    Node parsePrimary() pure
    {
        if (atEnd)
            return null;
        immutable t = toks[pos];
        switch (t.kind)
        {
            case TokKind.lparen:
                pos++;
                auto inner = parseOr();
                if (!atEnd && toks[pos].kind == TokKind.rparen)
                    pos++;
                return inner;
            case TokKind.rparen:
                return null;
            case TokKind.phrase:
                pos++;
                Atom a;
                if (makeAtom(t.body_, a))
                    return new Node(NodeKind.atom, a);
                return null;
            default:
                pos++;
                return null;
        }
    }
}

/**
 * Parses `text` into a query tree. Returns `null` for the empty tree, which
 * matches no document.
 */
Node parseQuery(string text) pure
{
    auto p = Parser(lex(text));
    return p.parseOr();
}

/// Renders a tree as an S-expression, for debugging and tests.
string toSExpr(const Node n)
{
    if (n is null)
        return "()";
    final switch (n.kind)
    {
        case NodeKind.atom:
            string s;
            foreach (i, t; n.atom.terms)
                s ~= (i ? " " : "") ~ t;
            return n.atom.length == 1 ? s : "\"" ~ s ~ "\"";
        case NodeKind.and:
        case NodeKind.or:
        case NodeKind.not:
            string s = "(" ~ (n.kind == NodeKind.and ? "AND" : n.kind == NodeKind.or ? "OR" : "NOT");
            foreach (c; n.children)
                s ~= " " ~ toSExpr(c);
            return s ~ ")";
    }
}

/**
 * The positive atoms of a tree: atoms under an even number of `NOT`s, in
 * depth-first left-to-right order of first occurrence, without duplicates.
 */
Atom[] positiveAtoms(const Node root) pure
{
    Atom[] result;
    void walk(const Node n, bool positive)
    {
        if (n is null)
            return;
        if (n.kind == NodeKind.atom)
        {
            if (positive)
            {
                foreach (a; result)
                    if (a == n.atom)
                        return;
                result ~= n.atom;
            }
            return;
        }
        immutable childPositive = n.kind == NodeKind.not ? !positive : positive;
        foreach (c; n.children)
            walk(c, childPositive);
    }

    walk(root, true);
    return result;
}

version (unittest)
{
    private string P(string q) { return toSExpr(parseQuery(q)); }
}

unittest
{
    assert(P("cat") == "cat");
    assert(P("cat dog") == "(AND cat dog)");
    assert(P("cat OR dog") == "(OR cat dog)");
    assert(P("cat OR dog fish") == "(OR cat (AND dog fish))");
    assert(P("NOT cat") == "(NOT cat)");
    assert(P("NOT NOT cat") == "(NOT (NOT cat))");
    assert(P("\"lazy dog\"") == "\"lazi dog\"");
    assert(P("well-known") == "\"well known\"");
    assert(P("(cat OR dog) fish") == "(AND (OR cat dog) fish)");
}

/// The recovery rules of the specification.
unittest
{
    foreach (q; ["()", "the", "NOT", "", "\"\"", "(", ")", "NOT ()"])
        assert(P(q) == "()", q);
    foreach (q; ["cat AND", "OR cat", "cat ()", "cat NOT ()", "cat NOT (", "(cat",
                 "\"cat", "cat ) dog", "cat ) ) dog", "cat the"])
        assert(P(q) == "cat", q);
    assert(P("cat OR AND dog") == "(OR cat dog)");
    assert(P("cat AND OR dog") == "(OR cat dog)");
    assert(P("cat AND AND dog") == "(AND cat dog)");
    assert(P("dog NOT ( cat") == "(AND dog (NOT cat))");
    assert(P("\"to be or not to be\"") == "\"to be or not to be\"");
    assert(P("and or not") == "()");
    assert(P("cat \"the\"") == "cat");
}

unittest
{
    string[] names(string q)
    {
        string[] r;
        foreach (a; positiveAtoms(parseQuery(q)))
            r ~= a.terms.dup;
        return r;
    }

    assert(names("cat dog cat") == ["cat", "dog"]);
    assert(names("cat NOT dog") == ["cat"]);
    assert(names("NOT cat") == []);
    assert(names("NOT (cat NOT dog)") == ["dog"]);
    assert(names("") == []);
}
