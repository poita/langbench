/// The public face of the library: compile a filter, run it on a value.
module jq.filter;

import std.array : appender;

import jq.ast : Node;
import jq.error;
import jq.interp;
import jq.parser;
import jq.value;

/// A compiled jq filter. Compile once, run on any number of inputs.
final class Filter
{
    private Node root_;
    private string source_;

    private this(Node root, string source)
    {
        root_ = root;
        source_ = source;
    }

    /// Compiles `source`. Throws `JqSyntaxError` if it is not a valid filter.
    static Filter compile(string source)
    {
        return new Filter(parseFilter(source), source);
    }

    /// The filter text this was compiled from.
    string source() const pure nothrow @nogc @safe
    {
        return source_;
    }

    /// Runs the filter on `input`, calling `sink` with each output as it is
    /// produced. If evaluation raises an error, the outputs already delivered
    /// stand and `JqError` is thrown.
    void run(Value input, scope void delegate(Value) sink) const
    {
        eval(cast() root_, input, null, sink);
    }

    /// Runs the filter and returns all outputs. Throws `JqError` on error
    /// (discarding the outputs produced before it; use `run` to keep them).
    Value[] collect(Value input) const
    {
        auto r = appender!(Value[])();
        run(input, (Value v) { r.put(v); });
        return r.data;
    }
}
