package jsoncanon

// Canonicalize parses the JSON document in src and returns its canonical
// serialization, without a trailing newline.
//
// The canonical form has no whitespace outside strings. Object members are
// sorted by key in UTF-16 code unit order, and when a key occurs more than
// once only its last occurrence is kept. Strings escape only '"', '\', and
// U+0000–U+001F (as \b \f \n \r \t or lowercase \u00xx); everything else,
// including '/', is emitted as raw UTF-8. Numbers are echoed textually; if a
// number has an exponent it is rewritten as a lowercase 'e' followed by the
// exponent digits without leading zeros and without a '+' sign (a zero
// exponent is "0" and never negative).
//
// If src is not a valid document, the error is a *[SyntaxError].
func Canonicalize(src []byte) ([]byte, error) {
	v, err := Parse(src)
	if err != nil {
		return nil, err
	}
	return v.AppendCanonical(make([]byte, 0, len(src)+1)), nil
}
