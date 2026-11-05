// Package jsonpointer evaluates RFC 6901 JSON Pointers over jsonvalue trees.
package jsonpointer

import (
	"strings"

	"example.com/jsonschema/jsonvalue"
)

// Tokens splits a JSON Pointer into its unescaped reference tokens
// ("~1" becomes "/" and "~0" becomes "~"). The empty pointer has no tokens.
// ok is false if the pointer is non-empty and does not start with '/'.
func Tokens(ptr string) (tokens []string, ok bool) {
	if ptr == "" {
		return nil, true
	}
	if ptr[0] != '/' {
		return nil, false
	}
	parts := strings.Split(ptr[1:], "/")
	for i, p := range parts {
		if strings.IndexByte(p, '~') >= 0 {
			p = strings.ReplaceAll(p, "~1", "/")
			p = strings.ReplaceAll(p, "~0", "~")
		}
		parts[i] = p
	}
	return parts, true
}

// Resolve evaluates ptr starting at root and returns a pointer to the value
// it designates inside the tree (not a copy), or nil if the pointer does not
// resolve.
func Resolve(root *jsonvalue.Value, ptr string) *jsonvalue.Value {
	tokens, ok := Tokens(ptr)
	if !ok {
		return nil
	}
	cur := root
	for _, t := range tokens {
		switch cur.Kind() {
		case jsonvalue.KindObject:
			cur = cur.Object().Get(t)
			if cur == nil {
				return nil
			}
		case jsonvalue.KindArray:
			i, ok := arrayIndex(t)
			arr := cur.Array()
			if !ok || i >= len(arr) {
				return nil
			}
			cur = &arr[i]
		default:
			return nil
		}
	}
	return cur
}

// arrayIndex parses a canonical array index: digits without leading zeros.
func arrayIndex(t string) (int, bool) {
	if t == "" || (len(t) > 1 && t[0] == '0') || len(t) > 9 {
		return 0, false
	}
	n := 0
	for i := 0; i < len(t); i++ {
		if t[i] < '0' || t[i] > '9' {
			return 0, false
		}
		n = n*10 + int(t[i]-'0')
	}
	return n, true
}
