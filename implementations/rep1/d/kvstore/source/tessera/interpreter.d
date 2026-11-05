/// The command-language front end: runs command lines against a `Database`
/// and formats the result blocks of `results.txt`.
module tessera.interpreter;

import tessera.ast;
import tessera.bytes;
import tessera.database;
import tessera.errors;
import tessera.parser;
import tessera.render;
import tessera.value;

/// Splits `commands.txt` into lines: LF terminates a line, so a trailing LF
/// does not start another, and an empty input has no lines.
string[] splitLines(const(char)[] text) pure @trusted
{
    string[] lines;
    size_t start = 0;
    foreach (i, c; text)
        if (c == '\n')
        {
            lines ~= text[start .. i].idup;
            start = i + 1;
        }
    if (start < text.length)
        lines ~= text[start .. $].idup;
    return lines;
}

/// Runs command lines and accumulates the text of `results.txt`.
final class Interpreter
{
    /// The database being operated on.
    Database db;
    private ByteBuffer results;
    private ByteBuffer payload;
    private size_t lineNo;

    this(Database db) pure nothrow @safe { this.db = db; }

    /// The accumulated `results.txt` content.
    const(ubyte)[] output() const pure nothrow @safe { return results.data; }

    /// Execute a whole script, rolling back an open transaction at the end.
    void runScript(const(char)[] script)
    {
        foreach (line; splitLines(script))
            runLine(line);
        db.finish();
    }

    /// Execute one command line and append its result block.
    void runLine(string line)
    {
        lineNo++;
        payload.clear();
        ByteBuffer status;
        try
        {
            auto cmd = parseCommand(line);
            execute(cmd, status);
        }
        catch (TesseraException e)
        {
            status.clear();
            payload.clear();
            status.putText("error ");
            status.putText(kindName(e.kind));
        }
        results.put('[');
        putUnsigned(results, lineNo);
        results.putText("] ");
        results.put(status.data);
        results.put('\n');
        results.put(payload.data);
    }

    private void line(const(char)[] text = null)
    {
        payload.putText("  ");
        payload.putText(text);
        payload.put('\n');
    }

    private void putRow(ref Row r, bool withDoc)
    {
        payload.putText("  ");
        renderString(payload, r.key);
        if (withDoc)
        {
            payload.putText(" = ");
            renderValue(payload, r.doc);
        }
        payload.put('\n');
    }

    private void execute(ref Command cmd, ref ByteBuffer st)
    {
        final switch (cmd.kind)
        {
        case CommandKind.begin:
            db.begin();
            st.putText("ok begin");
            break;
        case CommandKind.commit:
            auto info = db.commit();
            st.putText("ok commit ");
            putUnsigned(st, info.txnId);
            st.putText(" frames ");
            putUnsigned(st, info.frames);
            break;
        case CommandKind.rollback:
            db.rollback();
            st.putText("ok rollback");
            break;
        case CommandKind.checkpoint:
            auto n = db.checkpoint();
            st.putText("ok checkpoint pages ");
            putUnsigned(st, n);
            break;
        case CommandKind.stat:
            auto s = db.stat();
            st.putText("ok stat");
            void stat(string name, ulong v)
            {
                payload.putText("  ");
                payload.putText(name);
                payload.put(' ');
                putUnsigned(payload, v);
                payload.put('\n');
            }

            stat("pages", s.pages);
            stat("free", s.freePages);
            stat("freehead", s.freeHead);
            stat("docs", s.docs);
            stat("root", s.root);
            stat("height", s.height);
            stat("commits", s.commits);
            stat("indexes", s.indexes);
            stat("wal", s.walSize);
            break;
        case CommandKind.indexes:
            auto list = db.indexes();
            st.putText("ok indexes ");
            putUnsigned(st, list.length);
            foreach (ref ix; list)
            {
                payload.putText("  ");
                putUnsigned(payload, ix.slot);
                payload.put(' ');
                payload.putText(ix.path);
                payload.putText(" root ");
                putUnsigned(payload, ix.root);
                payload.putText(" entries ");
                putUnsigned(payload, ix.entries);
                payload.put('\n');
            }
            break;
        case CommandKind.put:
            immutable created = db.put(cmd.key, cmd.value);
            st.putText(created ? "ok put created" : "ok put replaced");
            break;
        case CommandKind.get:
            auto doc = db.get(cmd.key);
            st.putText("ok get value");
            payload.putText("  ");
            renderValue(payload, doc);
            payload.put('\n');
            break;
        case CommandKind.delete_:
            db.remove(cmd.key);
            st.putText("ok delete removed");
            break;
        case CommandKind.update:
            db.update(cmd.key, cmd.path, cmd.value);
            st.putText("ok update updated");
            break;
        case CommandKind.unset:
            db.unset(cmd.key, cmd.path);
            st.putText("ok unset updated");
            break;
        case CommandKind.scan:
            auto rows = db.scan(cmd.scan);
            st.putText("ok scan ");
            putUnsigned(st, rows.length);
            foreach (ref r; rows)
                putRow(r, !cmd.scan.keysOnly);
            break;
        case CommandKind.find:
            auto res = db.find(cmd.pred, cmd.hasLimit ? cmd.limit : -1);
            st.putText("ok find ");
            putUnsigned(st, res.rows.length);
            st.putText(" plan ");
            st.putText(res.plan);
            foreach (ref r; res.rows)
                putRow(r, true);
            break;
        case CommandKind.createIndex:
            auto n = db.createIndex(cmd.path);
            st.putText("ok create index ");
            st.putText(joinPath(cmd.path));
            st.putText(" entries ");
            putUnsigned(st, n);
            break;
        case CommandKind.dropIndex:
            auto n = db.dropIndex(cmd.path);
            st.putText("ok drop index ");
            st.putText(joinPath(cmd.path));
            st.putText(" pages ");
            putUnsigned(st, n);
            break;
        }
    }
}
