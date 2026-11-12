/// langvm: a compiler and stack virtual machine for the Vellum language.
///
/// The pipeline follows SPEC.md section 16: source text -> tokens -> syntax
/// tree -> items and name resolution -> type checking -> bytecode -> execution.
///
/// Typical use:
/// ---
/// import langvm;
/// string output = interpretToString("@module main\nfn main() { print(\"hi\"); }\n");
/// ---
module langvm;

public import langvm.bytecode : Program;
public import langvm.diag : CompileError, Kind, Pos;
public import langvm.driver : Sink, compile, execute, interpret, interpretToString;
public import langvm.vm : Panic;
