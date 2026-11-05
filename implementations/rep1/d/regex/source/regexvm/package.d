/// regexvm: a backtracking-VM regular expression engine.
///
/// Public API: `Regex`, `Match`, `Span`, `RegexException`, plus the batch
/// driver `runBatch` used by the command-line tool.  The remaining modules
/// (`parser`, `analysis`, `compiler`, `program`, `vm`, ...) are the
/// implementation stages and are public for testing and inspection.
module regexvm;

public import regexvm.regex;
public import regexvm.errors;
public import regexvm.batch;
public import regexvm.output;
public import regexvm.input;
