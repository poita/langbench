/// langvm: a compiler and stack virtual machine for the Vellum language.
///
/// The pipeline is: module stream → tokens → AST → items and name resolution →
/// type checking → bytecode → execution. Use [runSource] for the whole pipeline or
/// [compile] and [execute] separately.
module langvm;

public import langvm.diag : CompileError, Panic, Pos;
public import langvm.driver : Compiled, Outcome, RunResult, compile, execute, runSource;
public import langvm.source : SourceModule, splitModules;
