/**
 * High-level API: compile a filter once, run it against many documents.
 */
module jq.program;

import jq.ast;
import jq.interp;
import jq.parser;
import jq.value;
import jq.json : toJson;

/// Outcome of running a filter.
struct RunStatus
{
    /// False if evaluation stopped on an uncaught error.
    bool ok = true;
    /// Description of the error when `ok` is false.
    string message;
}

/// A compiled jq filter.
final class Program
{
    private Node root;

    private this(Node root) { this.root = root; }

    /**
     * Compile `source`.
     *
     * Throws: `jq.lexer.FilterException` if the filter is malformed.
     */
    static Program compile(string source)
    {
        return new Program(parseFilter(source));
    }

    /**
     * Run the filter on `input`, calling `emit` for each result in order.
     * Evaluation stops at the first uncaught error; results emitted before it
     * have already been delivered.
     */
    RunStatus run(Value input, scope void delegate(Value) emit)
    {
        scope interp = new Interpreter();
        Exception thrown;
        const ok = interp.eval(root, input, null, (Value v) {
            try
                emit(v);
            catch (Exception e)
            {
                thrown = e;
                return false;
            }
            return true;
        });
        if (thrown !is null)
            throw thrown;
        if (ok)
            return RunStatus(true, null);
        return RunStatus(false, interp.err.type == Type.error ? interp.err.text : "error");
    }

    /// Collect all results (up to the first uncaught error) into an array.
    Value[] runAll(Value input, out RunStatus status)
    {
        Value[] results;
        status = run(input, (Value v) { results ~= v; });
        return results;
    }
}
