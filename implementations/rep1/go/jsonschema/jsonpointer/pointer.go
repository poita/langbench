// Package jsonpointer implements RFC 6901 JSON Pointer over jsonvalue values.
package jsonpointer

import (
	"errors"
	"strconv"
	"strings"

	"example.com/jsonschema/jsonvalue"
)

// ErrNotFound is returned when a pointer does not lead to a value.
var ErrNotFound = errors.New("jsonpointer: no such value")

// ErrSyntax is returned for a string that is not a JSON Pointer.
var ErrSyntax = errors.New("jsonpointer: invalid pointer syntax")

// Parse splits ptr into its unescaped reference tokens. The empty pointer
// yields no tokens (it refers to the whole document); any other pointer must
// start with '/'.
func Parse(ptr string) ([]string, error) {
	if ptr == "" {
		return nil, nil
	}
	if ptr[0] != '/' {
		return nil, ErrSyntax
	}
	toks := strings.Split(ptr[1:], "/")
	for i, t := range toks {
		toks[i] = Unescape(t)
	}
	return toks, nil
}

// Unescape decodes "~1" to "/" and "~0" to "~" in a reference token.
func Unescape(tok string) string {
	if !strings.Contains(tok, "~") {
		return tok
	}
	tok = strings.ReplaceAll(tok, "~1", "/")
	return strings.ReplaceAll(tok, "~0", "~")
}

// Escape encodes "~" as "~0" and "/" as "~1" so tok can be used in a pointer.
func Escape(tok string) string {
	tok = strings.ReplaceAll(tok, "~", "~0")
	return strings.ReplaceAll(tok, "/", "~1")
}

// Eval follows ptr from root and returns the value it designates.
func Eval(root jsonvalue.Value, ptr string) (jsonvalue.Value, error) {
	toks, err := Parse(ptr)
	if err != nil {
		return jsonvalue.Value{}, err
	}
	cur := root
	for _, t := range toks {
		switch cur.Kind() {
		case jsonvalue.ObjectKind:
			o, _ := cur.Object()
			next, ok := o.Get(t)
			if !ok {
				return jsonvalue.Value{}, ErrNotFound
			}
			cur = next
		case jsonvalue.Array:
			a, _ := cur.Array()
			i, ok := arrayIndex(t)
			if !ok || i >= len(a) {
				return jsonvalue.Value{}, ErrNotFound
			}
			cur = a[i]
		default:
			return jsonvalue.Value{}, ErrNotFound
		}
	}
	return cur, nil
}

// arrayIndex parses a canonical array index: "0" or digits without a leading zero.
func arrayIndex(t string) (int, bool) {
	if t == "" || (len(t) > 1 && t[0] == '0') {
		return 0, false
	}
	for i := 0; i < len(t); i++ {
		if t[i] < '0' || t[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.Atoi(t)
	return n, err == nil
}
