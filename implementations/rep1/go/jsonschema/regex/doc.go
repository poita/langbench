// Package regex is a small ECMA-262-flavoured regular expression engine that
// answers one question: does the pattern match anywhere in a string?
//
// It supports the subset used by JSON Schema's pattern and patternProperties:
// alternation, plain and (?:...) groups, greedy and lazy quantifiers
// (*, +, ?, {n}, {n,}, {n,m}), '.', '^' and '$' (start and end of the whole
// string only), \b and \B over [A-Za-z0-9_], character classes with ranges
// and class escapes, and the usual character escapes. Matching is over
// Unicode code points and there are no flags.
//
// Because only membership is reported, the matcher is a backtracking search
// memoised on (instruction, position), so a match test costs O(P·L) for a
// program of P instructions and a subject of L code points, and patterns such
// as (a*)* cannot loop or blow up.
package regex
