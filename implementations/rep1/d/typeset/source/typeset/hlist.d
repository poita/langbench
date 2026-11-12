/**
 * Horizontal lists: turning a styled inline token stream into BOX, GLUE and
 * PENALTY items, including fragment formation, the sentence-end glue rule
 * and hyphenation.
 */
module typeset.hlist;

import std.conv : to;

import typeset.hyphenation;
import typeset.markup : Token;
import typeset.metrics;
import typeset.settings : Settings;
import typeset.units;

/// One item of a horizontal list.
struct Item
{
    /// Item kind.
    enum Kind : ubyte
    {
        box,
        glue,
        penalty
    }

    Kind kind;
    bool rigid; /// box: no text and no face (`~`, `\ `, fixed gaps)
    bool infinite; /// glue: the list-final infinite glue
    bool flagged; /// penalty: a flagged (hyphen) break
    ubyte face; /// box and pre-break text: face index
    long size; /// box and pre-break text
    long raise; /// box and pre-break text
    long width; /// box: advance; glue: natural width
    long stretch, shrink; /// glue
    long penalty; /// penalty value
    dstring text; /// box text
    dstring preText; /// penalty: pre-break text
    long preWidth; /// penalty: width of the pre-break text
    int frag = -1; /// fragment number (boxes and penalties of one word)
    int note; /// mark box: footnote number
}

/// The style a list starts in and how it is broken.
struct ListStyle
{
    Family family;
    bool bold, italic;
    long size;
    bool justify = true; /// false: every glue becomes ragged glue
    bool hyphenate = true; /// context hyphenation switch
}

/// Everything the builder needs besides the text.
struct BuildEnv
{
    const(FaceSet) faces;
    const(Settings)* settings;
    PatternSet patterns;
}

private enum UnitKind : ubyte
{
    chr,
    glue,
    rigid,
    mark,
    disc,
    gap
}

private struct Unit
{
    UnitKind kind;
    dchar c;
    ubyte face;
    long size;
    long raise;
    bool ordinary; // glue: never an extra-space glue
    long width; // rigid / gap
    int note;
}

private struct StyleState
{
    Family family;
    bool bold, italic;
    long size;
}

/// `step-up` of a size (x 6/5).
long stepUp(long s) pure nothrow @safe @nogc { return fdiv(s * 6, 5); }
/// `step-down` of a size (x 5/6).
long stepDown(long s) pure nothrow @safe @nogc { return fdiv(s * 5, 6); }

private void resolve(ref Unit[] units, const Token[] tokens, StyleState initial, ref BuildEnv env)
{
    StyleState[] stack;
    StyleState st = initial;
    foreach (ref t; tokens)
    {
        final switch (t.kind)
        {
        case Token.Kind.chr:
            units ~= Unit(UnitKind.chr, t.c, faceIndex(st.family, st.bold, st.italic), st.size);
            break;
        case Token.Kind.space, Token.Kind.ordinarySpace:
            if (units.length && units[$ - 1].kind == UnitKind.glue)
                break;
            units ~= Unit(UnitKind.glue, ' ', faceIndex(st.family, st.bold, st.italic), st.size, 0,
                t.kind == Token.Kind.ordinarySpace);
            break;
        case Token.Kind.nbsp, Token.Kind.escapedSpace:
            {
                immutable f = faceIndex(st.family, st.bold, st.italic);
                units ~= Unit(UnitKind.rigid, ' ', f, st.size, 0, false, scale(env.faces[f].space, st.size));
                break;
            }
        case Token.Kind.disc:
            units ~= Unit(UnitKind.disc);
            break;
        case Token.Kind.open:
            stack ~= st;
            switch (t.c)
            {
            case 'b': st.bold = true; break;
            case 'i': st.italic = true; break;
            case 'm': st.family = Family.mono; break;
            case '+': st.size = stepUp(st.size); break;
            default: st.size = stepDown(st.size); break;
            }
            break;
        case Token.Kind.close:
            st = stack[$ - 1];
            stack = stack[0 .. $ - 1];
            break;
        case Token.Kind.note:
            units ~= Unit(UnitKind.mark, 0, faceIndex(st.family, st.bold, st.italic), env.settings.markSize,
                env.settings.markRaise, false, 0, t.note);
            break;
        case Token.Kind.gap:
            units ~= Unit(UnitKind.gap, 0, 0, 0, 0, false, t.width);
            break;
        }
    }
}

private bool isCloser(dchar c) pure nothrow @safe @nogc
{
    return c == ')' || c == ']' || c == '}' || c == '\'' || c == '"' || c == '’' || c == '”';
}

/// Does the glue at `units[idx]` follow a sentence end?
private bool followsSentenceEnd(const Unit[] units, size_t idx) pure nothrow @safe @nogc
{
    long k = cast(long) idx - 1;
    while (k >= 0 && (units[k].kind == UnitKind.disc
            || (units[k].kind == UnitKind.chr && isCloser(units[k].c))))
        --k;
    if (k < 0)
        return false;
    if (!(units[k].kind == UnitKind.chr && (units[k].c == '.' || units[k].c == '!' || units[k].c == '?')))
        return false;
    --k;
    while (k >= 0 && units[k].kind == UnitKind.disc)
        --k;
    if (k < 0)
        return true;
    return !(units[k].kind == UnitKind.chr && units[k].c >= 'A' && units[k].c <= 'Z');
}

/// Builds the item list for `content` (preceded by `prefix`, whose glue is not
/// trimmed) in the given style. The three list-final items are appended.
Item[] buildList(const Token[] prefix, const Token[] content, in ListStyle style, ref BuildEnv env)
{
    const s = env.settings;
    StyleState initial = StyleState(style.family, style.bold, style.italic, style.size);
    Unit[] units;
    resolve(units, prefix, initial, env);
    immutable contentStart = units.length;
    resolve(units, content, initial, env);
    // rule 2: drop a glue at the very start and the very end of the content
    if (units.length > contentStart && units[contentStart].kind == UnitKind.glue)
        units = units[0 .. contentStart] ~ units[contentStart + 1 .. $];
    if (units.length > contentStart && units[$ - 1].kind == UnitKind.glue)
        units = units[0 .. $ - 1];

    Item[] items;
    int fragCounter = 0;

    // current fragment
    dchar[] chars;
    int[] discs;
    ubyte fFace;
    long fSize, fRaise;
    bool open = false;
    immutable hyphenOk = style.hyphenate && s.hyphenate;

    void flush()
    {
        if (!open)
            return;
        open = false;
        emitFragment(items, chars, discs, fFace, fSize, fRaise, fragCounter++, hyphenOk, env);
        chars = null;
        discs = null;
    }

    foreach (i, ref u; units)
    {
        final switch (u.kind)
        {
        case UnitKind.chr:
            if (open && (u.face != fFace || u.size != fSize))
                flush();
            if (!open)
            {
                open = true;
                fFace = u.face;
                fSize = u.size;
                fRaise = u.raise;
                chars = null;
                discs = null;
            }
            chars ~= u.c;
            break;
        case UnitKind.disc:
            if (open)
                discs ~= cast(int) chars.length;
            break;
        case UnitKind.glue:
            {
                flush();
                const f = env.faces[u.face];
                Item g;
                g.kind = Item.Kind.glue;
                if (!u.ordinary && followsSentenceEnd(units, i))
                {
                    g.width = scale(f.space + f.extra, u.size);
                    g.stretch = scale(f.stretch + f.stretch / 2, u.size);
                    g.shrink = scale(f.shrink, u.size);
                }
                else
                {
                    g.width = scale(f.space, u.size);
                    g.stretch = scale(f.stretch, u.size);
                    g.shrink = scale(f.shrink, u.size);
                }
                if (!style.justify)
                {
                    g.stretch = s.raggedStretch * g.width;
                    g.shrink = 0;
                }
                items ~= g;
                break;
            }
        case UnitKind.rigid, UnitKind.gap:
            {
                flush();
                Item b;
                b.kind = Item.Kind.box;
                b.rigid = true;
                b.width = u.width;
                items ~= b;
                break;
            }
        case UnitKind.mark:
            {
                flush();
                Item b;
                b.kind = Item.Kind.box;
                b.face = u.face;
                b.size = u.size;
                b.raise = u.raise;
                b.text = u.note.to!dstring;
                b.width = env.faces[u.face].width(b.text, u.size);
                b.frag = fragCounter++;
                b.note = u.note;
                items ~= b;
                break;
            }
        }
    }
    flush();

    Item p;
    p.kind = Item.Kind.penalty;
    p.penalty = 10_000;
    items ~= p;
    Item g;
    g.kind = Item.Kind.glue;
    g.infinite = true;
    items ~= g;
    p.penalty = -10_000;
    items ~= p;
    return items;
}

private void emitFragment(ref Item[] items, dchar[] chars, int[] discs, ubyte face, long size, long raise,
    int frag, bool hyphenOk, ref BuildEnv env)
{
    immutable n = cast(int) chars.length;
    const f = env.faces[face];
    const s = env.settings;

    // (position, isCoreHyphen)
    struct Pt
    {
        int pos;
        bool core;
    }

    Pt[] pts;
    bool hasLetter = false;
    foreach (c; chars)
        if (isLetter(c))
        {
            hasLetter = true;
            break;
        }
    if (hyphenOk && face != 8 && hasLetter)
    {
        int[] explicit;
        foreach (d; discs)
            if (d > 0 && d < n)
                explicit ~= d;
        int lo = 0;
        while (lo < n && !isLetter(chars[lo]))
            ++lo;
        int hi = n;
        while (hi > lo && !isLetter(chars[hi - 1]))
            --hi;
        // core hyphens and segments
        int segStart = lo;
        void segment(int a, int b)
        {
            if (!explicit.length && b > a)
            {
                bool allLetters = true;
                char[] w;
                foreach (c; chars[a .. b])
                {
                    if (!isLetter(c))
                    {
                        allLetters = false;
                        break;
                    }
                    w ~= cast(char)(c >= 'A' && c <= 'Z' ? c + 32 : c);
                }
                if (allLetters)
                    foreach (q; env.patterns.breaks(w.idup))
                        pts ~= Pt(a + q, false);
            }
        }

        foreach (k; lo .. hi)
        {
            if (chars[k] == '-')
            {
                segment(segStart, k);
                pts ~= Pt(k + 1, true);
                segStart = k + 1;
            }
        }
        segment(segStart, hi);
        foreach (d; explicit)
            pts ~= Pt(d, false);
        // sort by position, core first for equal positions, dedupe
        import std.algorithm : sort;

        pts.sort!((a, b) => a.pos != b.pos ? a.pos < b.pos : (a.core && !b.core));
        Pt[] uniq;
        foreach (pt; pts)
        {
            if (pt.pos <= 0 || pt.pos >= n)
                continue;
            if (uniq.length && uniq[$ - 1].pos == pt.pos)
                continue;
            uniq ~= pt;
        }
        pts = uniq;
    }

    int prev = 0;
    void box(int a, int b)
    {
        Item it;
        it.kind = Item.Kind.box;
        it.face = face;
        it.size = size;
        it.raise = raise;
        it.text = chars[a .. b].idup;
        it.width = f.width(it.text, size);
        it.frag = frag;
        items ~= it;
    }

    foreach (pt; pts)
    {
        box(prev, pt.pos);
        Item p;
        p.kind = Item.Kind.penalty;
        p.flagged = true;
        p.frag = frag;
        p.face = face;
        p.size = size;
        p.raise = raise;
        if (pt.core)
            p.penalty = s.exHyphenPenalty;
        else
        {
            p.penalty = s.hyphenPenalty;
            p.preText = "-"d;
            p.preWidth = f.width("-"d, size);
        }
        items ~= p;
        prev = pt.pos;
    }
    box(prev, n);
}

/// Plain text of an inline stream, as used for table-of-contents entries and
/// running-header placeholders.
dstring plainText(const Token[] tokens) pure @safe
{
    dchar[] r;
    foreach (t; tokens)
    {
        switch (t.kind)
        {
        case Token.Kind.chr:
            r ~= t.c;
            break;
        case Token.Kind.space, Token.Kind.ordinarySpace, Token.Kind.nbsp, Token.Kind.escapedSpace:
            if (r.length == 0 || r[$ - 1] != ' ')
                r ~= ' ';
            break;
        default:
            break;
        }
    }
    while (r.length && r[$ - 1] == ' ')
        r = r[0 .. $ - 1];
    return r.idup;
}
