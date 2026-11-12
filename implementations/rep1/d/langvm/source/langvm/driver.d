/// The compile-and-run pipeline behind the command-line tool.
module langvm.driver;

import langvm.bytecode : Program;
import langvm.checker : checkProgram;
import langvm.compiler : compileProgram;
import langvm.diag : CompileError;
import langvm.lexer : Token, lex;
import langvm.parser : parseModule;
import langvm.ast : Item;
import langvm.source : splitModules;
import langvm.symbols : buildWorld;
import langvm.vm : Panic, VM;

/// Where a program's output goes.
alias Sink = void delegate(const(char)[]);

/// Compile a module stream to bytecode, following the passes of SPEC.md
/// section 13.2. Throws `CompileError` for the first error found.
Program compile(const(char)[] input)
{
    auto mods = splitModules(input);
    Token[][] tokens;
    foreach (m; mods)
        tokens ~= lex(m);
    Item[][] items;
    foreach (t; tokens)
        items ~= parseModule(t);
    auto world = buildWorld(mods, items);
    auto bodies = checkProgram(world);
    return compileProgram(world, bodies);
}

/// Run a compiled program. Output goes to `sink`; a run-time panic appends
/// the `panic: ...` line and returns normally.
void execute(Program program, Sink sink)
{
    auto vm = new VM(program, sink);
    try
        vm.run();
    catch (Panic p)
        sink("panic: " ~ p.msg ~ "\n");
}

/// Everything the tool does: compile `input` and run it, or report the single
/// diagnostic line. The result is exactly what belongs on stdout.
void interpret(const(char)[] input, Sink sink)
{
    Program program;
    try
        program = compile(input);
    catch (CompileError e)
    {
        sink(e.diagnostic() ~ "\n");
        return;
    }
    execute(program, sink);
}

/// Like `interpret`, but collects the output into a string.
string interpretToString(const(char)[] input)
{
    import std.array : appender;

    auto buf = appender!string();
    interpret(input, (const(char)[] s) { buf.put(s); });
    return buf.data;
}
