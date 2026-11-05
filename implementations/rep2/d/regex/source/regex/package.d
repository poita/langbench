/++
    A backtracking regular-expression engine for a defined subset of Perl
    syntax, with leftmost, greedy, ordered-choice semantics and capture
    group positions.

    Modules:
    $(UL
      $(LI `regex.pattern` – the high-level `Regex` API)
      $(LI `regex.parser`, `regex.ast`, `regex.charset` – pattern syntax tree)
      $(LI `regex.analysis` – nullability, anchoring, first-character sets)
      $(LI `regex.compiler`, `regex.program` – flat VM program)
      $(LI `regex.vm` – the backtracking interpreter)
      $(LI `regex.batch` – the batch input/output protocol of the CLI)
    )
+/
module regex;

public import regex.exception;
public import regex.pattern;
public import regex.batch;
public import regex.vm : Matcher;
