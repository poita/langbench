/// Build steps and phony targets produced by evaluating build files.
module kiln.step;

import kiln.bytes : decimal;
import kiln.commands : CmdInfo;
import kiln.value;

/// A build step: one command with declared inputs and outputs.
final class Step
{
    int serial; /// creation order across the whole build
    string[] outs; /// declared outputs
    string[] ins; /// declared inputs (files and phony references)
    string[] afters; /// order-only dependencies
    long cost; /// simulated cost
    string depfile; /// depfile path, or null
    const(CmdInfo)* cmd;
    Value[] args; /// command arguments (`str` or `int` values)
    string canonical; /// canonical command string
    string[] fileInputs; /// declared inputs that are not phony references
    string[] fullOutputs; /// declared outputs followed by the depfile

    /// The primary output path.
    string primary() const @safe
    {
        return outs[0];
    }
}

/// A phony target declaration.
struct PhonyDecl
{
    string name; /// without the leading `@`
    string[] deps;
}

/// Renders a command in canonical form: `name(arg, arg, ...)`.
string canonicalCommand(string name, const(Value)[] args) @safe
{
    string r = name ~ "(";
    foreach (i, ref a; args)
    {
        if (i)
            r ~= ", ";
        if (a.type == Value.Type.integer)
            r ~= decimal(a.num);
        else
            r ~= quoteString(a.s);
    }
    return r ~ ")";
}

/// Quotes a string for the canonical command rendering.
string quoteString(const(char)[] s) @safe
{
    static immutable hex = "0123456789abcdef";
    char[] r;
    r.reserve(s.length + 2);
    r ~= '"';
    foreach (c; s)
    {
        switch (c)
        {
        case '\\':
            r ~= `\\`;
            break;
        case '"':
            r ~= `\"`;
            break;
        case '\n':
            r ~= `\n`;
            break;
        case '\t':
            r ~= `\t`;
            break;
        case '\r':
            r ~= `\r`;
            break;
        default:
            if (cast(ubyte) c < 0x20 || c == 0x7f)
            {
                r ~= `\x`;
                r ~= hex[(cast(ubyte) c) >> 4];
                r ~= hex[(cast(ubyte) c) & 15];
            }
            else
                r ~= c;
        }
    }
    r ~= '"';
    return (() @trusted => cast(string) r)();
}
