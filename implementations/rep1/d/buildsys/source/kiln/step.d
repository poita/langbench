/**
 * Build steps: the unit of work produced by evaluating a build file.
 */
module kiln.step;

import kiln.text : escapeForCommand;
import kiln.value : Value;

/// A build step.
final class Step
{
    /// Creation order across the whole build (0, 1, 2, ...).
    int serial;
    /// Declared outputs, in order (never empty once validated).
    string[] outs;
    /// Declared inputs (files and `@phony` references), in order.
    string[] ins;
    /// Order-only dependencies.
    string[] afters;
    /// The depfile path, if `hasDepfile`.
    string depfile;
    ///
    bool hasDepfile;
    /// The command name.
    string cmdName;
    /// The evaluated command arguments.
    Value[] cmdArgs;
    /// The cost in simulated time units.
    long cost;
    /// The canonical command string, e.g. `write("hi\n")`.
    string cmdString;
    /// Declared inputs that are not phony references (the hashed dependencies).
    string[] fileInputs;
    /// Declared outputs followed by the depfile.
    string[] fullOuts;

    /// The step's primary output: the first declared output.
    string primary() const @safe pure nothrow @nogc
    {
        return outs[0];
    }
}

/// Renders `name(arg, arg, ...)` canonically.
string canonicalCommand(string name, const(Value)[] args) @safe pure nothrow
{
    import std.conv : to;

    string r = name ~ "(";
    foreach (i, ref a; args)
    {
        if (i > 0)
            r ~= ", ";
        if (a.type == Value.Type.integer)
            r ~= a.num.to!string;
        else
            r ~= "\"" ~ escapeForCommand(a.text) ~ "\"";
    }
    return r ~ ")";
}

unittest
{
    assert(canonicalCommand("concat", []) == "concat()");
    assert(canonicalCommand("write", [Value.ofStr("hello\n")]) == `write("hello\n")`);
    assert(canonicalCommand("replace", [Value.ofStr("a\\b"), Value.ofStr("c")]) == `replace("a\\b", "c")`);
    assert(canonicalCommand("indent", [Value.ofInt(4)]) == "indent(4)");
    assert(canonicalCommand("grep", [Value.ofStr("ü")]) == "grep(\"ü\")");
}
