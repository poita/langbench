/**
 * Parser for the match file: the setup block (SPEC.md 4.1) and script lines (4.2).
 */
module cardgame.matchfile;

import std.array : split;
import std.string : indexOf;
import cardgame.chain : Tok;
import cardgame.game : Settings, Target;
import cardgame.model;

/// Raised for any violation of the setup block (reported as `FATAL bad-setup`).
class SetupException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// One `<cardid>` or `<cardid>*<count>` entry.
struct Entry
{
    string cardId;
    int count;
}

/// Setup zones, in the order objects are numbered.
enum SetupZone : ubyte { deck, hand, field, ash, rift }

/// The parsed setup block.
struct MatchSetup
{
    Settings cfg;
    string cardsPath;
    Entry[][5][2] zones;       // [player][SetupZone]
    size_t startLine;          // 0-based index of the START line
}

/// Split text into lines; a `\r` before `\n` is stripped.
string[] splitLines(string text)
{
    string[] lines;
    size_t start = 0;
    foreach (i, c; text)
        if (c == '\n')
        {
            auto l = text[start .. i];
            if (l.length > 0 && l[$ - 1] == '\r') l = l[0 .. $ - 1];
            lines ~= l;
            start = i + 1;
        }
    if (start < text.length)
    {
        auto l = text[start .. $];
        if (l.length > 0 && l[$ - 1] == '\r') l = l[0 .. $ - 1];
        lines ~= l;
    }
    return lines;
}

/// Split a line into words on runs of spaces and tabs.
string[] words(string line)
{
    string[] r;
    size_t i = 0;
    while (i < line.length)
    {
        while (i < line.length && (line[i] == ' ' || line[i] == '\t')) ++i;
        auto s = i;
        while (i < line.length && line[i] != ' ' && line[i] != '\t') ++i;
        if (i > s) r ~= line[s .. i];
    }
    return r;
}

/// Whether the line is a comment or blank.
bool isCommentLine(string line)
{
    foreach (c; line)
    {
        if (c == ' ' || c == '\t') continue;
        return c == '#';
    }
    return true;
}

/// Parse a run of decimal digits into an unsigned 64-bit value; false when malformed or too large.
bool parseNumber(string s, out ulong v)
{
    if (s.length == 0) return false;
    ulong acc = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9') return false;
        immutable d = c - '0';
        if (acc > (ulong.max - d) / 10) return false;
        acc = acc * 10 + d;
    }
    v = acc;
    return true;
}

private ulong rangedNumber(string s, ulong lo, ulong hi)
{
    ulong v;
    if (!parseNumber(s, v) || v < lo || v > hi) throw new SetupException("bad number");
    return v;
}

private Player parsePlayerWord(string s)
{
    if (s == "A") return Player.A;
    if (s == "B") return Player.B;
    throw new SetupException("bad player");
}

/// Parse the setup block of the match file; throws `SetupException` on any violation.
MatchSetup parseSetup(string[] lines)
{
    MatchSetup m;
    bool[string] seen;
    bool[2] seenCap;
    bool haveCards, haveSeed, haveStart;

    void once(string key)
    {
        if (key in seen) throw new SetupException("duplicate " ~ key);
        seen[key] = true;
    }

    foreach (idx, line; lines)
    {
        if (isCommentLine(line)) continue;
        auto w = words(line);
        switch (w[0])
        {
        case "START":
            if (w.length != 1) throw new SetupException("START takes no argument");
            m.startLine = idx;
            haveStart = true;
            break;
        case "CARDS":
            if (w.length != 2) throw new SetupException("bad CARDS");
            once("CARDS");
            m.cardsPath = w[1];
            haveCards = true;
            break;
        case "SEED":
            if (w.length != 2) throw new SetupException("bad SEED");
            once("SEED");
            m.cfg.seed = rangedNumber(w[1], 0, ulong.max);
            haveSeed = true;
            break;
        case "SPIRE":
            if (w.length != 2) throw new SetupException("bad SPIRE");
            once("SPIRE");
            m.cfg.spire = cast(long) rangedNumber(w[1], 1, 1_000_000);
            break;
        case "OPENING":
            if (w.length != 2) throw new SetupException("bad OPENING");
            once("OPENING");
            m.cfg.opening = cast(int) rangedNumber(w[1], 0, 20);
            break;
        case "MAXCAP":
            if (w.length != 2) throw new SetupException("bad MAXCAP");
            once("MAXCAP");
            m.cfg.maxCap = cast(int) rangedNumber(w[1], 1, 100);
            break;
        case "HANDMAX":
            if (w.length != 2) throw new SetupException("bad HANDMAX");
            once("HANDMAX");
            m.cfg.handMax = cast(int) rangedNumber(w[1], 0, 100);
            break;
        case "TURNLIMIT":
            if (w.length != 2) throw new SetupException("bad TURNLIMIT");
            once("TURNLIMIT");
            m.cfg.turnLimit = cast(int) rangedNumber(w[1], 1, 100_000);
            break;
        case "FIRST":
            if (w.length != 2) throw new SetupException("bad FIRST");
            once("FIRST");
            m.cfg.first = parsePlayerWord(w[1]);
            break;
        case "SHUFFLE":
            if (w.length != 2 || (w[1] != "on" && w[1] != "off")) throw new SetupException("bad SHUFFLE");
            once("SHUFFLE");
            m.cfg.shuffle = w[1] == "on";
            break;
        case "TRACE":
            if (w.length != 2) throw new SetupException("bad TRACE");
            once("TRACE");
            switch (w[1])
            {
            case "none": m.cfg.trace = Settings.Trace.none; break;
            case "legal": m.cfg.trace = Settings.Trace.legal; break;
            case "state": m.cfg.trace = Settings.Trace.state; break;
            default: throw new SetupException("bad TRACE");
            }
            break;
        case "CAP":
            if (w.length != 3) throw new SetupException("bad CAP");
            auto p = parsePlayerWord(w[1]);
            if (seenCap[p]) throw new SetupException("duplicate CAP");
            seenCap[p] = true;
            m.cfg.startCap[p] = cast(long) rangedNumber(w[2], 0, 100);
            break;
        case "DECK", "HAND", "FIELD", "ASH", "RIFT":
            if (w.length < 3) throw new SetupException("bad zone line");
            auto p = parsePlayerWord(w[1]);
            immutable z = w[0] == "DECK" ? SetupZone.deck : w[0] == "HAND" ? SetupZone.hand
                : w[0] == "FIELD" ? SetupZone.field : w[0] == "ASH" ? SetupZone.ash : SetupZone.rift;
            foreach (e; w[2 .. $])
            {
                Entry en;
                immutable star = e.indexOf('*');
                if (star < 0) { en.cardId = e; en.count = 1; }
                else
                {
                    en.cardId = e[0 .. star];
                    en.count = cast(int) rangedNumber(e[star + 1 .. $], 1, 1000);
                }
                if (en.cardId.length == 0) throw new SetupException("empty card id");
                m.zones[p][z] ~= en;
            }
            break;
        default:
            throw new SetupException("unknown setup word");
        }
        if (haveStart) break;
    }
    if (!haveCards || !haveSeed || !haveStart) throw new SetupException("missing required line");
    return m;
}

/// A parsed script line.
struct Command
{
    enum Kind : ubyte { bad, dump, legal, vault, card, pass, concede, play, act, attack, block }
    Kind kind;
    Player player;
    ulong n1, n2;          // play: pos; act: oid, index
    Tok[] toks;            // play / act targets
    ulong[] ids, ids2;     // attack: oids; block: blockers and attackers
    string word;           // card: the id
}

private bool parseObjRef(string s, out ulong v)
{
    return s.length > 1 && s[0] == '#' && parseNumber(s[1 .. $], v);
}

private bool parseTok(string s, out Tok t)
{
    if (s == "A") { t = Tok(Target.Kind.player, 0); return true; }
    if (s == "B") { t = Tok(Target.Kind.player, 1); return true; }
    ulong v;
    if (s.length > 1 && s[0] == '#' && parseNumber(s[1 .. $], v)) { t = Tok(Target.Kind.obj, v); return true; }
    if (s.length > 1 && s[0] == '~' && parseNumber(s[1 .. $], v)) { t = Tok(Target.Kind.chain, v); return true; }
    return false;
}

/// Parse a non-comment script line; `kind == bad` when it does not match section 4.2.
Command parseCommand(string line)
{
    Command c;
    auto w = words(line);
    if (w.length == 0) return c;
    switch (w[0])
    {
    case "DUMP": if (w.length == 1) c.kind = Command.Kind.dump; return c;
    case "LEGAL": if (w.length == 1) c.kind = Command.Kind.legal; return c;
    case "VAULT": if (w.length == 1) c.kind = Command.Kind.vault; return c;
    case "CARD":
        if (w.length == 2) { c.kind = Command.Kind.card; c.word = w[1]; }
        return c;
    case "A": c.player = Player.A; break;
    case "B": c.player = Player.B; break;
    default: return c;
    }
    if (w.length < 2) return c;
    switch (w[1])
    {
    case "PASS": if (w.length == 2) c.kind = Command.Kind.pass; return c;
    case "CONCEDE": if (w.length == 2) c.kind = Command.Kind.concede; return c;
    case "PLAY":
        if (w.length < 3 || !parseNumber(w[2], c.n1)) return c;
        foreach (s; w[3 .. $])
        {
            Tok t;
            if (!parseTok(s, t)) return c;
            c.toks ~= t;
        }
        c.kind = Command.Kind.play;
        return c;
    case "ACT":
        if (w.length < 4 || !parseObjRef(w[2], c.n1) || !parseNumber(w[3], c.n2)) return c;
        foreach (s; w[4 .. $])
        {
            Tok t;
            if (!parseTok(s, t)) return c;
            c.toks ~= t;
        }
        c.kind = Command.Kind.act;
        return c;
    case "ATTACK":
        foreach (s; w[2 .. $])
        {
            ulong v;
            if (!parseObjRef(s, v)) return c;
            c.ids ~= v;
        }
        c.kind = Command.Kind.attack;
        return c;
    case "BLOCK":
        foreach (s; w[2 .. $])
        {
            immutable colon = s.indexOf(':');
            ulong a, b;
            if (colon < 0 || !parseObjRef(s[0 .. colon], a) || !parseObjRef(s[colon + 1 .. $], b)) return c;
            c.ids ~= a;
            c.ids2 ~= b;
        }
        c.kind = Command.Kind.block;
        return c;
    default: return c;
    }
}

unittest
{
    auto lines = splitLines("# c\nCARDS data/x\nSEED 007\nDECK A X*3 Y\n\nSTART\nA PASS\r\n");
    auto m = parseSetup(lines);
    assert(m.cfg.seed == 7 && m.cardsPath == "data/x" && m.startLine == 5);
    assert(m.zones[0][SetupZone.deck].length == 2 && m.zones[0][SetupZone.deck][0].count == 3);
    assert(lines[6] == "A PASS");
}

unittest
{
    import std.exception : assertThrown;
    assertThrown!SetupException(parseSetup(splitLines("CARDS x\nSEED 1\n")));
    assertThrown!SetupException(parseSetup(splitLines("CARDS x\nSEED 1\nSEED 2\nSTART\n")));
    assertThrown!SetupException(parseSetup(splitLines("CARDS x\nSEED -1\nSTART\n")));
    assertThrown!SetupException(parseSetup(splitLines("CARDS x\nSEED 1\nDECK A X*0\nSTART\n")));
    assertThrown!SetupException(parseSetup(splitLines("CARDS x\nSEED 1\nSTART now\n")));
}

unittest
{
    auto c = parseCommand("A PLAY 2 #5 B ~3");
    assert(c.kind == Command.Kind.play && c.n1 == 2 && c.toks.length == 3);
    assert(parseCommand("B BLOCK #4:#2 #9:#2").ids == [4, 9]);
    assert(parseCommand("A ATTACK #x").kind == Command.Kind.bad);
    assert(parseCommand("a PASS").kind == Command.Kind.bad);
    assert(parseCommand("DUMP x").kind == Command.Kind.bad);
    assert(parseCommand("A PLAY 99999999999999999999").kind == Command.Kind.bad);
}
