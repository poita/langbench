/**
 * The public face of the interpreter.
 */
module scheme.interpreter;

import scheme.analyzer;
import scheme.environment;
import scheme.evaluator;
import scheme.output;
import scheme.primitives;
import scheme.printer;
import scheme.reader;
import scheme.value;

/// Outcome of $(LREF Interpreter.run).
struct RunResult
{
    /// True if every form was evaluated without error.
    bool ok = true;
    /// The runtime error category when `!ok` and `syntaxError` is false.
    ErrorKind error;
    /// True if the program was malformed (reader or analyzer failure).
    bool syntaxError;
}

/**
 * A Scheme interpreter with its own global environment.
 *
 * Definitions persist between calls to `run`/`eval`, so one interpreter can
 * be fed a program in several pieces.
 */
final class Interpreter
{
    private SymbolTable symbols;
    private Output output;
    private Analyzer analyzer;
    private Evaluator evaluator;

    /**
     * Create an interpreter. Program output (from `display`/`newline`, the
     * printed results of top-level forms and error lines) goes to `sink` if
     * given; otherwise it is accumulated and can be fetched with $(LREF takeOutput).
     */
    this(OutputSink sink = null)
    {
        symbols = new SymbolTable;
        output = new Output(sink);
        analyzer = new Analyzer(symbols);
        evaluator = new Evaluator(output);
        installPrimitives(symbols);
    }

    /**
     * Run a whole program as the command-line tool does: evaluate each
     * top-level form in order, print the write form of every non-void value
     * followed by a newline and, on a runtime error, append
     * `error: <category>` and stop.
     */
    RunResult run(string source)
    {
        RunResult result;
        scope (exit)
            output.flush();
        try
        {
            auto reader = Reader(source, symbols);
            Value form;
            while (reader.read(form))
            {
                Value v = evaluator.eval(analyzer.analyze(form), null);
                if (v.kind != Kind.void_)
                {
                    printValue(output, v, false);
                    output.put('\n');
                }
            }
        }
        catch (SchemeError e)
        {
            output.put("error: ");
            output.put(categoryName(e.kind));
            output.put('\n');
            result.ok = false;
            result.error = e.kind;
        }
        catch (SyntaxError e)
        {
            output.put("error: syntax-error\n");
            result.ok = false;
            result.syntaxError = true;
        }
        return result;
    }

    /**
     * Evaluate all forms of `source` and return the value of the last one
     * (void for an empty program). Nothing is printed except by the program
     * itself. Throws `SchemeError` on runtime errors and `SyntaxError` on
     * malformed input.
     */
    Value eval(string source)
    {
        auto reader = Reader(source, symbols);
        Value form, result = Value.void_();
        while (reader.read(form))
            result = evaluator.eval(analyzer.analyze(form), null);
        return result;
    }

    /// Return (and clear) the output accumulated so far, for interpreters built without a sink.
    string takeOutput()
    {
        return output.take();
    }

    /// Look up a global variable; throws `SchemeError` if it is unbound.
    Value global(string name)
    {
        auto s = symbols.intern(name);
        if (!s.bound)
            throw new SchemeError(ErrorKind.unboundVariable);
        return s.value;
    }
}

/// Run `source` as a complete program and return everything it prints.
string runToString(string source)
{
    auto interp = new Interpreter;
    interp.run(source);
    return interp.takeOutput();
}

/// Default host stack size used by $(LREF withLargeStack).
enum defaultStackSize = 1024UL * 1024 * 1024;

/**
 * Run `dg` on a new thread with a large stack, wait for it and rethrow
 * anything it throws. Non-tail Scheme recursion nests on the host stack, so
 * programs that recurse deeply should be run through this.
 */
void withLargeStack(void delegate() dg, size_t stackBytes = defaultStackSize)
{
    import core.thread : Thread;

    Throwable failure;
    auto worker = new Thread({
        try
            dg();
        catch (Throwable t)
            failure = t;
    }, stackBytes);
    worker.start();
    worker.join();
    if (failure !is null)
        throw failure;
}

unittest
{
    // 10,000 nested calls, even in an unoptimised test build.
    string got;
    withLargeStack({
        got = runToString("(define (f n) (if (= n 0) 0 (+ 1 (f (- n 1))))) (f 100000)");
    });
    assert(got == "100000\n");
}
