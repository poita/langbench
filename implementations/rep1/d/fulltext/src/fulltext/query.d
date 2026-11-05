/**
 * The query language: lexer, recursive-descent parser and positive-atom
 * extraction.
 *
 * The parser never fails. Malformed queries are repaired exactly as laid out
 * in the specification, and a query with nothing left in it parses to the
 * empty tree, represented by a `null` `Node`.
 */
module fulltext.query;

import fulltext.analysis : Tokenizer, TermAnalyzer;
import fulltext.whitespace : spaceLengthAt;

/// A search atom: the sequence of terms of one word or quoted phrase.
struct Atom
{
    /// The analysed terms; never empty for an atom that is part of a tree.
    string[] terms;

    /// A string that is equal for two atoms exactly when their terms are equal.
    string key() const pure nothrow @safe
    {
        string k;
        foreach (i, t; terms)
        {
            if (i)
                k ~= '\0';
            k ~= t;
        }
        return k;
    }
}

/// The kinds of node in a query tree.
enum NodeKind
{
    atom, /// leaf holding an `Atom`
    not, /// negation of the single child
    and, /// intersection of the children
    or, /// union of the children
}

/// A node of the query tree.
final class Node
{
    NodeKind kind;
    Atom atom; /// valid for `NodeKind.atom`
    Node[] children; /// operands for `not` (one), `and` and `or`

    this(NodeKind kind, Node[] children = null) pure nothrow @safe
    {
        this.kind = kind;
        this.children = children;
    }

    /// Creates a leaf.
    static Node leaf(Atom a) pure nothrow @safe
    {
        auto n = new Node(NodeKind.atom);
        n.atom = a;
        return n;
    }
}

/// Lexical token kinds.
enum TokenKind
{
    lparen,
    rparen,
    and,
    or,
    not,
    phrase,
}

/// A lexical token; `body` is set for phrases.
struct QueryToken
{
    TokenKind kind;
    string body;
}

/// Splits a query into tokens. Never fails.
QueryToken[] lexQuery(string q) pure nothrow @safe
{
    QueryToken[] toks;
    size_t i = 0;
    while (i < q.length)
    {
        immutable sp = spaceLengthAt(q, i);
        if (sp)
        {
            i += sp;
            continue;
        }
        immutable c = q[i];
        if (c == '(')
        {
            toks ~= QueryToken(TokenKind.lparen);
            ++i;
        }
        else if (c == ')')
        {
            toks ~= QueryToken(TokenKind.rparen);
            ++i;
        }
        else if (c == '"')
        {
            size_t j = i + 1;
            while (j < q.length && q[j] != '"')
                ++j;
            toks ~= QueryToken(TokenKind.phrase, q[i + 1 .. j]);
            i = j < q.length ? j + 1 : j;
        }
        else
        {
            size_t j = i;
            while (j < q.length && q[j] != '(' && q[j] != ')' && q[j] != '"'
                    && spaceLengthAt(q, j) == 0)
                ++j;
            auto w = q[i .. j];
            if (w == "AND")
                toks ~= QueryToken(TokenKind.and);
            else if (w == "OR")
                toks ~= QueryToken(TokenKind.or);
            else if (w == "NOT")
                toks ~= QueryToken(TokenKind.not);
            else
                toks ~= QueryToken(TokenKind.phrase, w);
            i = j;
        }
    }
    return toks;
}

/**
 * Analyses a phrase body into an atom. Returns `false` (leaving `atom`
 * empty) when the atom is empty: no terms, or a single stop word.
 */
bool analyzeAtom(string body, out Atom atom) pure @trusted
{
    TermAnalyzer an;
    auto bytes = cast(const(ubyte)[]) body;
    string[] terms;
    bool lastStop = false;
    foreach (span; Tokenizer(bytes))
    {
        bool stop;
        terms ~= an.analyze(bytes[span.start .. span.end], stop).idup;
        lastStop = stop;
    }
    if (terms.length == 0 || (terms.length == 1 && lastStop))
        return false;
    atom = Atom(terms);
    return true;
}

private struct Parser
{
    QueryToken[] toks;
    size_t pos;

    bool atEnd() const pure nothrow @safe
    {
        return pos >= toks.length;
    }

    TokenKind peek() const pure nothrow @safe
    {
        return toks[pos].kind;
    }

    static Node combine(NodeKind kind, Node[] parts) pure nothrow @safe
    {
        Node[] kept;
        foreach (p; parts)
            if (p !is null)
                kept ~= p;
        if (kept.length == 0)
            return null;
        if (kept.length == 1)
            return kept[0];
        return new Node(kind, kept);
    }

    Node parseOr() pure @safe
    {
        Node[] parts = [parseAnd()];
        while (!atEnd && peek == TokenKind.or)
        {
            ++pos;
            parts ~= parseAnd();
        }
        return combine(NodeKind.or, parts);
    }

    Node parseAnd() pure @safe
    {
        Node[] parts;
        while (!atEnd)
        {
            immutable k = peek;
            if (k == TokenKind.rparen || k == TokenKind.or)
                break;
            if (k == TokenKind.and)
            {
                ++pos;
                continue;
            }
            parts ~= parseNot();
        }
        return combine(NodeKind.and, parts);
    }

    Node parseNot() pure @safe
    {
        size_t count = 0;
        while (!atEnd && peek == TokenKind.not)
        {
            ++pos;
            ++count;
        }
        auto p = parsePrimary();
        if (p is null)
            return null;
        foreach (_; 0 .. count)
            p = new Node(NodeKind.not, [p]);
        return p;
    }

    Node parsePrimary() pure @safe
    {
        if (atEnd)
            return null;
        final switch (peek)
        {
        case TokenKind.lparen:
            ++pos;
            auto inner = parseOr();
            if (!atEnd && peek == TokenKind.rparen)
                ++pos;
            return inner;
        case TokenKind.rparen:
            return null;
        case TokenKind.phrase:
            auto body = toks[pos].body;
            ++pos;
            Atom a;
            if (analyzeAtom(body, a))
                return Node.leaf(a);
            return null;
        case TokenKind.and, TokenKind.or, TokenKind.not:
            ++pos;
            return null;
        }
    }
}

/**
 * Parses a query into a tree. The empty tree is `null`. Any tokens left
 * after the top-level expression (stray `)`) are discarded.
 */
Node parseQuery(string query) pure @safe
{
    auto p = Parser(lexQuery(query), 0);
    return p.parseOr();
}

/**
 * The positive atoms of a tree: atoms under an even number of `not` nodes,
 * in depth-first left-to-right order, without duplicates.
 */
Atom[] positiveAtoms(const Node root) pure @safe
{
    Atom[] result;
    bool[string] seen;
    void walk(const Node n, bool positive)
    {
        if (n is null)
            return;
        final switch (n.kind)
        {
        case NodeKind.atom:
            if (positive)
            {
                auto k = n.atom.key;
                if (k !in seen)
                {
                    seen[k] = true;
                    result ~= Atom(n.atom.terms.dup);
                }
            }
            break;
        case NodeKind.not:
            walk(n.children[0], !positive);
            break;
        case NodeKind.and, NodeKind.or:
            foreach (c; n.children)
                walk(c, positive);
            break;
        }
    }

    walk(root, true);
    return result;
}
