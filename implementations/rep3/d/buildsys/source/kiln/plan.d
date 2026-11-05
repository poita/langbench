/// The result of evaluating the build files: steps, phony targets, defaults.
module kiln.plan;

import kiln.commands;

/// One build step.
final class StepDef
{
    int serial;
    string[] outs;          /// declared outputs; the first is the primary output
    string depfile;         /// depfile path (valid when `hasDepfile`)
    bool hasDepfile;
    string[] ins;           /// declared inputs (files and `@phony` references)
    string[] afters;        /// order-only references
    string[] fileInputs;    /// declared inputs that are not phony references
    immutable(CmdSpec)* spec;
    CmdArg[] args;
    long cost;
    string canon;           /// canonical command string

    /// The primary output path.
    @property string primary() const
    {
        return outs[0];
    }

    /// Declared outputs followed by the depfile, if any.
    string[] fullOutputs() const
    {
        auto r = outs.dup;
        if (hasDepfile)
            r ~= depfile;
        return r;
    }
}

/// A phony target (ordering only).
final class PhonyDef
{
    string name;
    string[] deps;
}

/// Everything a build's evaluation phase produces.
final class Plan
{
    StepDef[] steps;
    PhonyDef[] phonies;
    int[string] phonyIndex;
    string[] defaults;
}
