// Package regex is a small regular-expression engine for the ECMA-262 subset
// that JSON Schema's "pattern" and "patternProperties" keywords need, matching
// over Unicode code points.
//
// Supported syntax: alternation, concatenation, groups "(...)" and "(?:...)"
// (both plain grouping), the quantifiers * + ? {n} {n,} {n,m} (each optionally
// lazy, which makes no difference to whether a string matches), ".", the
// assertions ^ $ \b \B, character classes with ranges and negation, the class
// escapes \d \D \w \W \s \S, and the character escapes \n \r \t \f \v \0 \xHH
// \uHHHH (surrogate pairs combine) \cX and backslash-escaped punctuation.
// Backreferences, lookaround, named groups, Unicode property escapes and flags
// are not supported and are reported as syntax errors.
//
// Semantics follow ECMA-262 without flags: "." excludes the four line
// terminators, "^" matches only at the start and "$" only at the end of the
// subject, and \b is a boundary over [A-Za-z0-9_] only.
//
// The only question the engine answers is whether a pattern matches somewhere
// in a string. It does so with a Thompson-style simulation that advances all
// threads in lock step, so matching is O(P*L) for a pattern program of size P
// and a subject of length L, with no exponential backtracking.
package regex
