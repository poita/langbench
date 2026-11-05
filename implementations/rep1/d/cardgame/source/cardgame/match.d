/**
 * Match files: setup parsing (SPEC 4.1, 8) and script execution (4.2, 24).
 *
 * `simulate` is the library's main entry point: it takes the text of a match
 * file and returns the complete log the command-line tool prints.
 */
module cardgame.match;

import std.algorithm : canFind;
import std.conv : to;

import cardgame.actions;
import cardgame.cards;
import cardgame.engine;
import cardgame.game;
import cardgame.parser;
import cardgame.report;
import cardgame.rng;

/// Callback used to read the card database named by a `CARDS` line.
alias FileReader = string delegate(string path);

/// Setup failures that end the run with a single `FATAL` line.
class SetupError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(msg, file, line);
    }
}

private struct DeckEntry
{
    string id;
    int count;
}

private enum ZoneSlot : int
{
    deck,
    hand,
    field,
    ash,
    rift,
}

private struct Setup
{
    Config cfg;
    DeckEntry[][5][2] zones;
}

private bool isSpace(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t';
}

/// Split a line into words on runs of spaces and tabs.
string[] splitWords(string line) @safe pure
{
    string[] words;
    size_t i = 0;
    while (i < line.length)
    {
        while (i < line.length && isSpace(line[i]))
            i++;
        immutable start = i;
        while (i < line.length && !isSpace(line[i]))
            i++;
        if (i > start)
            words ~= line[start .. i];
    }
    return words;
}

private bool isCommentOrBlank(string line) @safe pure
{
    foreach (c; line)
    {
        if (isSpace(c))
            continue;
        return c == '#';
    }
    return true;
}

/// Parse a run of decimal digits; returns false on anything else.
/// Values beyond 64 bits set `overflow`.
private bool parseDecimal(string s, out ulong value, out bool overflow) @safe pure
{
    value = 0;
    overflow = false;
    if (s.length == 0)
        return false;
    foreach (c; s)
        if (c < '0' || c > '9')
            return false;
    foreach (c; s)
    {
        immutable d = c - '0';
        if (value > (ulong.max - d) / 10)
        {
            overflow = true;
            value = ulong.max;
            continue;
        }
        if (!overflow)
            value = value * 10 + d;
    }
    return true;
}

private long setupNumber(string s, long lo, long hi) @safe pure
{
    ulong v;
    bool of;
    if (!parseDecimal(s, v, of) || of || v < lo || v > hi)
        throw new SetupError("bad number");
    return cast(long) v;
}

private int playerOf(string s) @safe pure
{
    if (s == "A")
        return 0;
    if (s == "B")
        return 1;
    throw new SetupError("bad player");
}

private DeckEntry parseEntry(string w) @safe pure
{
    DeckEntry e;
    e.count = 1;
    auto star = w.canFind('*');
    if (!star)
    {
        if (w.length == 0)
            throw new SetupError("bad entry");
        e.id = w;
        return e;
    }
    size_t at = 0;
    while (w[at] != '*')
        at++;
    e.id = w[0 .. at];
    if (e.id.length == 0)
        throw new SetupError("bad entry");
    e.count = cast(int) setupNumber(w[at + 1 .. $], 1, 1000);
    return e;
}

/// Parse the setup block; `startIndex` receives the index of the `START` line.
private Setup parseSetup(string[] lines, out size_t startIndex)
{
    Setup s;
    bool haveCards, haveSeed, haveStart;
    bool[string] seen;
    bool[2] seenCap;

    void once(string key)
    {
        if (key in seen)
            throw new SetupError("duplicate line");
        seen[key] = true;
    }

    foreach (i, line; lines)
    {
        if (isCommentOrBlank(line))
            continue;
        auto w = splitWords(line);
        switch (w[0])
        {
        case "START":
            if (w.length != 1)
                throw new SetupError("START takes no argument");
            haveStart = true;
            startIndex = i;
            break;
        case "CARDS":
            once("CARDS");
            if (w.length != 2)
                throw new SetupError("CARDS");
            s.cfg.cardsPath = w[1];
            haveCards = true;
            break;
        case "SEED":
            once("SEED");
            if (w.length != 2)
                throw new SetupError("SEED");
            {
                ulong v;
                bool of;
                if (!parseDecimal(w[1], v, of) || of)
                    throw new SetupError("SEED");
                s.cfg.seed = v;
            }
            haveSeed = true;
            break;
        case "SPIRE":
            once("SPIRE");
            if (w.length != 2)
                throw new SetupError("SPIRE");
            s.cfg.spire = cast(int) setupNumber(w[1], 1, 1_000_000);
            break;
        case "OPENING":
            once("OPENING");
            if (w.length != 2)
                throw new SetupError("OPENING");
            s.cfg.opening = cast(int) setupNumber(w[1], 0, 20);
            break;
        case "MAXCAP":
            once("MAXCAP");
            if (w.length != 2)
                throw new SetupError("MAXCAP");
            s.cfg.maxCap = cast(int) setupNumber(w[1], 1, 100);
            break;
        case "HANDMAX":
            once("HANDMAX");
            if (w.length != 2)
                throw new SetupError("HANDMAX");
            s.cfg.handMax = cast(int) setupNumber(w[1], 0, 100);
            break;
        case "TURNLIMIT":
            once("TURNLIMIT");
            if (w.length != 2)
                throw new SetupError("TURNLIMIT");
            s.cfg.turnLimit = cast(int) setupNumber(w[1], 1, 100_000);
            break;
        case "FIRST":
            once("FIRST");
            if (w.length != 2)
                throw new SetupError("FIRST");
            s.cfg.first = playerOf(w[1]);
            break;
        case "SHUFFLE":
            once("SHUFFLE");
            if (w.length != 2 || (w[1] != "on" && w[1] != "off"))
                throw new SetupError("SHUFFLE");
            s.cfg.shuffle = w[1] == "on";
            break;
        case "TRACE":
            once("TRACE");
            if (w.length != 2)
                throw new SetupError("TRACE");
            switch (w[1])
            {
            case "none":
                s.cfg.trace = TraceMode.none;
                break;
            case "legal":
                s.cfg.trace = TraceMode.legal;
                break;
            case "state":
                s.cfg.trace = TraceMode.state;
                break;
            default:
                throw new SetupError("TRACE");
            }
            break;
        case "CAP":
            if (w.length != 3)
                throw new SetupError("CAP");
            {
                immutable p = playerOf(w[1]);
                if (seenCap[p])
                    throw new SetupError("duplicate CAP");
                seenCap[p] = true;
                s.cfg.cap[p] = cast(int) setupNumber(w[2], 0, 100);
            }
            break;
        case "DECK":
        case "HAND":
        case "FIELD":
        case "ASH":
        case "RIFT":
            {
                if (w.length < 3)
                    throw new SetupError("zone line");
                immutable p = playerOf(w[1]);
                immutable slot = w[0] == "DECK" ? ZoneSlot.deck : w[0] == "HAND" ? ZoneSlot.hand
                    : w[0] == "FIELD" ? ZoneSlot.field : w[0] == "ASH" ? ZoneSlot.ash : ZoneSlot.rift;
                foreach (word; w[2 .. $])
                    s.zones[p][slot] ~= parseEntry(word);
            }
            break;
        default:
            throw new SetupError("unknown setup word");
        }
        if (haveStart)
            break;
    }
    if (!haveCards || !haveSeed || !haveStart)
        throw new SetupError("missing required line");
    return s;
}

/// Build the game described by a validated setup and run it to the first decision point.
private Game startGame(Setup s, CardDb db)
{
    auto g = new Game(db, s.cfg);
    g.rng = Rng(s.cfg.seed);
    g.ev("GAME-START", Pl(g.first));
    int[] fieldObjs;
    foreach (p; 0 .. 2)
        foreach (slot; 0 .. 5)
            foreach (e; s.zones[p][slot])
                foreach (_; 0 .. e.count)
                {
                    immutable oid = g.newObject(db.byId[e.id], p);
                    final switch (cast(ZoneSlot) slot)
                    {
                    case ZoneSlot.deck:
                        putInZone(g, oid, ZoneKind.vault);
                        break;
                    case ZoneSlot.hand:
                        putInZone(g, oid, ZoneKind.hand);
                        break;
                    case ZoneSlot.field:
                        fieldObjs ~= oid;
                        break;
                    case ZoneSlot.ash:
                        putInZone(g, oid, ZoneKind.ash);
                        break;
                    case ZoneSlot.rift:
                        putInZone(g, oid, ZoneKind.rift);
                        break;
                    }
                }
    foreach (oid; fieldObjs)
        placeOnField(g, oid, g.objs[oid].owner, 0);
    if (s.cfg.shuffle)
        foreach (p; 0 .. 2)
        {
            g.rng.shuffle(g.vault[p]);
            g.ev("SHUFFLE", Pl(p));
        }
    drawCards(g, g.first, s.cfg.opening, false);
    drawCards(g, 1 - g.first, s.cfg.opening, false);
    settle(g);
    if (!g.over)
        advance(g);
    return g;
}

// ------------------------------------------------------------------- script

private bool parseTarget(string w, out Target t) @safe pure
{
    if (w == "A")
    {
        t = Target.player(0);
        return true;
    }
    if (w == "B")
    {
        t = Target.player(1);
        return true;
    }
    if (w.length < 2 || (w[0] != '#' && w[0] != '~'))
        return false;
    ulong v;
    bool of;
    if (!parseDecimal(w[1 .. $], v, of) || of)
        return false;
    immutable id = v > int.max ? 0 : cast(int) v;
    t = w[0] == '#' ? Target.object(id) : Target.chain(id);
    return true;
}

private bool parseObjRef(string w, out long v) @safe pure
{
    ulong u;
    bool of;
    if (w.length < 2 || w[0] != '#' || !parseDecimal(w[1 .. $], u, of) || of)
        return false;
    v = u > long.max ? long.max : cast(long) u;
    return true;
}

private bool parseNumber(string w, out long v) @safe pure
{
    ulong u;
    bool of;
    if (!parseDecimal(w, u, of) || of)
        return false;
    v = u > long.max ? long.max : cast(long) u;
    return true;
}

private enum ActionKind
{
    pass,
    concede,
    play,
    act,
    attack,
    block,
}

private struct Action
{
    ActionKind kind;
    int player;
    long pos, index;
    Target[] targets;
    long[] objs;
    BlockPair[] pairs;
}

/// Parse an action line; false means `bad-syntax`.
private bool parseAction(string[] w, out Action a) @safe pure
{
    a.player = w[0] == "A" ? 0 : 1;
    if (w.length < 2)
        return false;
    switch (w[1])
    {
    case "PASS":
        a.kind = ActionKind.pass;
        return w.length == 2;
    case "CONCEDE":
        a.kind = ActionKind.concede;
        return w.length == 2;
    case "PLAY":
        a.kind = ActionKind.play;
        if (w.length < 3 || !parseNumber(w[2], a.pos))
            return false;
        foreach (t; w[3 .. $])
        {
            Target tg;
            if (!parseTarget(t, tg))
                return false;
            a.targets ~= tg;
        }
        return true;
    case "ACT":
        a.kind = ActionKind.act;
        if (w.length < 4 || !parseObjRef(w[2], a.pos) || !parseNumber(w[3], a.index))
            return false;
        foreach (t; w[4 .. $])
        {
            Target tg;
            if (!parseTarget(t, tg))
                return false;
            a.targets ~= tg;
        }
        return true;
    case "ATTACK":
        a.kind = ActionKind.attack;
        foreach (t; w[2 .. $])
        {
            long v;
            if (!parseObjRef(t, v))
                return false;
            a.objs ~= v;
        }
        return true;
    case "BLOCK":
        a.kind = ActionKind.block;
        foreach (t; w[2 .. $])
        {
            size_t colon = t.length;
            foreach (i, c; t)
                if (c == ':')
                {
                    colon = i;
                    break;
                }
            if (colon == t.length)
                return false;
            long b, at;
            if (!parseObjRef(t[0 .. colon], b) || !parseObjRef(t[colon + 1 .. $], at))
                return false;
            a.pairs ~= BlockPair(b, at);
        }
        return true;
    default:
        return false;
    }
}

private void printBlock(Game g, TraceMode m)
{
    if (m == TraceMode.legal)
        writeLegal(g);
    else if (m == TraceMode.state)
        writeDump(g);
}

private void runScriptLine(Game g, string line, size_t lineNo)
{
    auto w = splitWords(line);
    void err(string kind)
    {
        g.raw("ERR " ~ lineNo.to!string ~ " " ~ kind);
    }

    switch (w[0])
    {
    case "DUMP":
    case "LEGAL":
    case "VAULT":
        if (w.length != 1)
            return err("bad-syntax");
        if (w[0] == "DUMP")
            writeDump(g);
        else if (w[0] == "LEGAL")
            writeLegal(g);
        else
            writeVault(g);
        return;
    case "CARD":
        if (w.length != 2)
            return err("bad-syntax");
        writeCard(g, w[1]);
        return;
    case "A":
    case "B":
        break;
    default:
        return err("bad-syntax");
    }

    Action a;
    if (!parseAction(w, a))
        return err("bad-syntax");
    if (g.over)
        return err("game-over");
    if (a.player != g.holder)
        return err("not-your-turn");
    final switch (a.kind)
    {
    case ActionKind.concede:
        break;
    case ActionKind.pass:
    case ActionKind.play:
    case ActionKind.act:
        if (g.dec != DecKind.priority)
            return err("wrong-decision");
        break;
    case ActionKind.attack:
        if (g.dec != DecKind.attackers)
            return err("wrong-decision");
        break;
    case ActionKind.block:
        if (g.dec != DecKind.blockers)
            return err("wrong-decision");
        break;
    }

    string failure;
    final switch (a.kind)
    {
    case ActionKind.concede:
        doConcede(g, a.player);
        break;
    case ActionKind.pass:
        doPass(g, a.player);
        break;
    case ActionKind.play:
        failure = doPlay(g, a.player, a.pos, a.targets);
        break;
    case ActionKind.act:
        failure = doAct(g, a.player, a.pos, a.index, a.targets);
        break;
    case ActionKind.attack:
        failure = doAttack(g, a.player, a.objs);
        break;
    case ActionKind.block:
        failure = doBlock(g, a.player, a.pairs);
        break;
    }
    if (failure !is null)
        return err(failure);
    printBlock(g, g.cfg.trace);
}

private string[] splitInput(string input) @safe pure
{
    string[] lines;
    size_t start = 0;
    foreach (i, c; input)
        if (c == '\n')
        {
            lines ~= stripCr(input[start .. i]);
            start = i + 1;
        }
    if (start < input.length)
        lines ~= stripCr(input[start .. $]);
    return lines;
}

private string stripCr(string s) @safe pure
{
    return s.length && s[$ - 1] == '\r' ? s[0 .. $ - 1] : s;
}

/**
 * Run a whole match file and return its log.
 *
 * Params:
 *   input    = the text of the match file
 *   readFile = loads the card database named by the `CARDS` line
 */
string simulate(string input, scope FileReader readFile)
{
    auto lines = splitInput(input);
    Setup setup;
    size_t startIndex;
    try
        setup = parseSetup(lines, startIndex);
    catch (SetupError)
        return "FATAL bad-setup\n";

    CardDb db;
    try
        db = parseDatabase(readFile(setup.cfg.cardsPath));
    catch (Exception)
        return "FATAL bad-database\n";

    foreach (p; 0 .. 2)
        foreach (slot; 0 .. 5)
            foreach (e; setup.zones[p][slot])
                if (!(e.id in db.byId))
                    return "FATAL unknown-card\n";

    auto g = startGame(setup, db);
    foreach (i; startIndex + 1 .. lines.length)
    {
        if (isCommentOrBlank(lines[i]))
            continue;
        runScriptLine(g, lines[i], i + 1);
    }
    if (!g.over)
        g.ev("RESULT", "pending", "none");
    return g.output();
}
