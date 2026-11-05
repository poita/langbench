/// The compile-and-run pipeline: module stream in, program output (or one diagnostic) out.
module langvm.driver;

import langvm.ast;
import langvm.bytecode;
import langvm.check;
import langvm.compiler;
import langvm.diag;
import langvm.lexer;
import langvm.parser;
import langvm.resolve;
import langvm.source;
import langvm.stdlib;
import langvm.vm;
import langvm.world;

/// A successfully compiled program, ready to run.
final class Compiled
{
    /// The bytecode program.
    Program program;
    /// The semantic world (modules, declarations).
    World world;
}

/// How a run ended.
enum Outcome
{
    /// `main` returned.
    finished,
    /// The program was rejected with a diagnostic.
    compileError,
    /// The program panicked at run time.
    panicked,
}

/// The result of compiling and running a program.
struct RunResult
{
    /// What happened.
    Outcome outcome;
    /// Exactly the bytes to write to stdout (program output, panic line, or diagnostic line).
    string stdout;
}

/// Compiles a module stream.
/// Throws: [CompileError] for the single diagnostic the specification prescribes.
Compiled compile(string input)
{
    auto mods = splitModules(input);
    // pass 1: lexing, every module in stream order
    Token[][] toks;
    foreach (m; mods)
        toks ~= Lexer.lex(m.lines);
    // pass 2: parsing
    ModuleAst[] asts;
    foreach (i, m; mods)
        asts ~= Parser.parseModule(m.name, toks[i]);
    // pass 3: items
    auto world = buildWorld(asts);
    // pass 4: bodies
    new Checker(world).run();
    auto c = new Compiled;
    c.world = world;
    c.program = new Compiler(world).compile();
    return c;
}

/// Runs a compiled program. Program output (and a final panic line, if any) is returned.
RunResult execute(Compiled c)
{
    auto impls = builtinImplementations();
    BuiltinFn[] table;
    foreach (b; c.world.builtins)
    {
        auto p = b.name in impls;
        assert(p !is null, "missing built-in " ~ b.name);
        table ~= *p;
    }
    auto vm = new VM(c.program, table);
    RunResult r;
    try
    {
        vm.runMain();
        r.outcome = Outcome.finished;
    }
    catch (Panic p)
    {
        vm.writeText("panic: ");
        vm.writeText(p.msg);
        vm.writeText("\n");
        r.outcome = Outcome.panicked;
    }
    r.stdout = cast(string) vm.written.idup;
    return r;
}

/// Compiles and runs `input`; a rejected program yields its one diagnostic line.
RunResult runSource(string input)
{
    Compiled c;
    try
    {
        c = compile(input);
    }
    catch (CompileError e)
    {
        RunResult r;
        r.outcome = Outcome.compileError;
        r.stdout = e.msg ~ "\n";
        return r;
    }
    return execute(c);
}
