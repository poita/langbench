/// Batch driver implementing the command-line input/output contract:
/// many patterns, each followed by many subjects.
module regexvm.batch;

import regexvm.errors;
import regexvm.input;
import regexvm.output;
import regexvm.regex;

/// Processes a whole input document.
///
/// Input format: a line with the pattern count `N`; then for each pattern one
/// line holding the pattern (verbatim, possibly empty), a line with the
/// subject count `M`, and `M` subject lines (verbatim).  One result line per
/// subject is appended to `output`.
///
/// Throws: `InputFormatException` on malformed input, `RegexException` for an
/// invalid pattern.
void runBatch(const(ubyte)[] input, ref OutputBuffer output) @trusted
{
    auto lines = LineReader(input);
    const patterns = lines.nextCount();
    Match m;
    foreach (_; 0 .. patterns)
    {
        const patternLine = cast(const(char)[]) lines.nextLine();
        const subjects = lines.nextCount();
        auto re = new Regex(patternLine);
        foreach (__; 0 .. subjects)
        {
            const subject = cast(const(char)[]) lines.nextLine();
            re.matchFirst(subject, m);
            output.putResult(m);
        }
    }
}
