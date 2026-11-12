/**
 * The result of evaluating a workspace's build files: steps, phony targets
 * and default targets.
 */
module kiln.model;

import kiln.value : Value;

/// One build step: a command that produces files from files.
final class Step
{
    /// Creation order across the whole build; breaks every scheduling tie.
    int serial;
    /// Declared outputs, in order (never empty once validated).
    string[] outs;
    /// Declared inputs (file paths and `@phony` references), in order.
    string[] ins;
    /// Order-only dependencies.
    string[] afters;
    /// Command name and evaluated arguments.
    string cmdName;
    Value[] cmdArgs;
    /// Whether a `cost` field was given, and its value.
    bool hasCost;
    long cost;
    /// The depfile path, if any.
    bool hasDepfile;
    string depfile;

    /// The declared outputs followed by the depfile.
    string[] fullOuts;
    /// Declared inputs that are not phony references, in order.
    string[] fileInputs;
    /// Canonical command string, e.g. `write("hi\n")`.
    string cmdString;
    /// The cost the scheduler charges (explicit or the command default).
    long effectiveCost;

    /// The step's primary output.
    string primary() const @safe pure nothrow @nogc
    {
        return outs[0];
    }
}

/// A phony target: a named group of ordering-only dependencies.
struct Phony
{
    string name;
    string[] deps;
}

/// Everything evaluation produces.
final class BuildPlan
{
    Step[] steps;
    Phony[] phonies;
    size_t[string] phonyIndex;
    string[] defaults;
}
