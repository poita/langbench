// Package diff computes shortest line-oriented edit scripts between two texts
// and applies edit scripts to produce the edited text.
//
// A script is a sequence of [Edit]s, each one of Keep (the next line of A is
// also in B), Delete (the next line of A is not in B) or Insert (a new line of
// B). Its cost is the number of deletions plus insertions. [Diff] returns a
// script of minimal cost, using Myers' O(ND) algorithm in linear space;
// [Apply] replays a script on A.
//
// Scripts have a simple text form, one line per edit, made of a tag character
// (' ', '-' or '+') directly followed by the line's text. [Script.String]
// renders it and [ParseScript] reads it back.
package diff
