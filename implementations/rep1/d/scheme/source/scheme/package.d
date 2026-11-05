/// A small Scheme interpreter.
///
/// Import this module to get the whole public API:
///
/// $(UL
///   $(LI `Interpreter` – evaluate programs (`scheme.interp`))
///   $(LI `runProgram` – one-shot convenience wrapper)
///   $(LI `BigInt` – the hand-written arbitrary-precision integer (`scheme.bignum`))
///   $(LI `Reader`, `Compiler`, `print` – the pipeline stages)
/// )
module scheme;

public import scheme.bignum;
public import scheme.compiler;
public import scheme.errors;
public import scheme.interp;
public import scheme.output;
public import scheme.printer;
public import scheme.reader;
public import scheme.symbols;
public import scheme.value;

/// Evaluate a Scheme program in a fresh interpreter and return its output.
string runProgram(string source)
{
    return new Interpreter().run(source);
}
