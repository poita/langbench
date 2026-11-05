/**
 * Build steps and the sixteen built-in commands' static descriptions.
 */
module kiln.step;

import kiln.hash;
import kiln.value;

import std.array : appender;
import std.conv : to;

/// The built-in commands.
enum Cmd : ubyte
{
    write,
    copy,
    concat,
    upper,
    lower,
    grep,
    replace,
    sort_lines,
    reverse_lines,
    dedup,
    number,
    indent,
    wrap,
    count_lines,
    hash,
    preprocess,
}

/// Static description of a command.
struct CmdInfo
{
    string name;
    /// Argument type codes: `S` for str, `I` for int.
    string sig;
    int minInputs;
    /// -1 means "no upper bound".
    int maxInputs;
    bool usesDepfile;
    long defaultCost;
}

/// Command table indexed by `Cmd`.
immutable CmdInfo[] cmdTable = [
    CmdInfo("write", "S", 0, 0, false, 1),
    CmdInfo("copy", "", 1, 1, false, 1),
    CmdInfo("concat", "", 1, -1, false, 2),
    CmdInfo("upper", "", 1, 1, false, 2),
    CmdInfo("lower", "", 1, 1, false, 2),
    CmdInfo("grep", "S", 1, 1, false, 3),
    CmdInfo("replace", "SS", 1, 1, false, 3),
    CmdInfo("sort_lines", "", 1, 1, false, 4),
    CmdInfo("reverse_lines", "", 1, 1, false, 2),
    CmdInfo("dedup", "", 1, 1, false, 3),
    CmdInfo("number", "", 1, 1, false, 2),
    CmdInfo("indent", "I", 1, 1, false, 2),
    CmdInfo("wrap", "SS", 1, 1, false, 1),
    CmdInfo("count_lines", "", 1, -1, false, 2),
    CmdInfo("hash", "", 1, -1, false, 3),
    CmdInfo("preprocess", "", 1, 1, true, 6),
];

static assert(cmdTable.length == 16);

private immutable int[string] cmdIds = () {
    int[string] r;
    foreach (i, c; cmdTable)
        r[c.name] = cast(int) i;
    return r;
}();

/// Looks up a command by name; returns false when there is none.
bool findCommand(string name, out Cmd cmd)
{
    if (auto p = name in cmdIds)
    {
        cmd = cast(Cmd)*p;
        return true;
    }
    return false;
}

/// A fully validated build step.
final class Step
{
    /// Creation order across the whole build.
    int serial;
    /// Declared outputs, inputs and order-only dependencies.
    string[] outs, ins, afters;
    /// The depfile path, or null.
    string depfile;
    Cmd cmd;
    Value[] args;
    long cost;
    /// Canonical command string, rendered once.
    string canon;
    /// The declared inputs that are not phony references.
    string[] fileInputs;
    /// Declared outputs followed by the depfile.
    string[] fullOutputs;

    /// The first declared output.
    string primary() const
    {
        return outs[0];
    }
}

/// Renders a string argument with the escaping of the canonical command form.
string quoteArgument(string s)
{
    static immutable hex = "0123456789abcdef";
    auto app = appender!(char[]);
    app.put('"');
    foreach (immutable char c; s)
    {
        switch (c)
        {
        case '\\':
            app.put("\\\\");
            break;
        case '"':
            app.put("\\\"");
            break;
        case '\n':
            app.put("\\n");
            break;
        case '\t':
            app.put("\\t");
            break;
        case '\r':
            app.put("\\r");
            break;
        default:
            if (c < 0x20 || c == 0x7f)
            {
                app.put("\\x");
                app.put(hex[(c >> 4) & 15]);
                app.put(hex[c & 15]);
            }
            else
                app.put(c);
        }
    }
    app.put('"');
    return (() @trusted => cast(string) app.data)();
}

/// The canonical rendering `name(arg, arg, ...)` of a command invocation.
string canonicalCommand(Cmd cmd, const(Value)[] args)
{
    auto app = appender!string;
    app.put(cmdTable[cmd].name);
    app.put('(');
    foreach (i, ref a; args)
    {
        if (i > 0)
            app.put(", ");
        if (a.type == VType.int_)
            app.put(a.i.to!string);
        else
            app.put(quoteArgument(a.s));
    }
    app.put(')');
    return app.data;
}
