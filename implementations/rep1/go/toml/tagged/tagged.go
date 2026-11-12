// Package tagged converts TOML document trees to and from the "tagged JSON"
// format used by the toml-test suite.
//
// In tagged JSON a table is an object, an array is an array, and a scalar is
// an object {"type": T, "value": V} whose members are both strings. Marshal
// writes it compactly with every object's keys sorted.
package tagged

import (
	"encoding/json"
	"errors"
	"fmt"

	"example.com/toml"
)

// Marshal returns the compact, key-sorted tagged JSON form of t.
func Marshal(t *toml.Table) []byte {
	return appendTable(make([]byte, 0, 1024), t)
}

func appendNode(b []byte, n toml.Node) []byte {
	switch n := n.(type) {
	case *toml.Table:
		return appendTable(b, n)
	case *toml.Array:
		b = append(b, '[')
		for i, it := range n.Items {
			if i > 0 {
				b = append(b, ',')
			}
			b = appendNode(b, it)
		}
		return append(b, ']')
	case *toml.Value:
		b = append(b, `{"type":`...)
		b = appendString(b, n.Type.String())
		b = append(b, `,"value":`...)
		b = appendString(b, n.Text)
		return append(b, '}')
	}
	return b
}

func appendTable(b []byte, t *toml.Table) []byte {
	b = append(b, '{')
	for i, k := range t.Keys() {
		if i > 0 {
			b = append(b, ',')
		}
		b = appendString(b, k)
		b = append(b, ':')
		n, _ := t.Get(k)
		b = appendNode(b, n)
	}
	return append(b, '}')
}

const hexDigits = "0123456789abcdef"

func appendString(b []byte, s string) []byte {
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			b = append(b, '\\', '"')
		case c == '\\':
			b = append(b, '\\', '\\')
		case c == '\b':
			b = append(b, '\\', 'b')
		case c == '\f':
			b = append(b, '\\', 'f')
		case c == '\n':
			b = append(b, '\\', 'n')
		case c == '\r':
			b = append(b, '\\', 'r')
		case c == '\t':
			b = append(b, '\\', 't')
		case c < 0x20:
			b = append(b, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&15])
		default:
			b = append(b, c)
		}
	}
	return append(b, '"')
}

// Unmarshal parses tagged JSON into a table. The root must be a JSON object.
func Unmarshal(data []byte) (*toml.Table, error) {
	var raw any
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	obj, ok := raw.(map[string]any)
	if !ok {
		return nil, errors.New("tagged: root is not an object")
	}
	n, err := convert(obj)
	if err != nil {
		return nil, err
	}
	return n.(*toml.Table), nil
}

func convert(raw any) (toml.Node, error) {
	switch r := raw.(type) {
	case map[string]any:
		if v, ok := asValue(r); ok {
			return v, nil
		}
		t := toml.NewTable()
		for k, x := range r {
			n, err := convert(x)
			if err != nil {
				return nil, err
			}
			t.Set(k, n)
		}
		return t, nil
	case []any:
		a := toml.NewArray()
		a.Items = make([]toml.Node, 0, len(r))
		for _, x := range r {
			n, err := convert(x)
			if err != nil {
				return nil, err
			}
			a.Items = append(a.Items, n)
		}
		return a, nil
	}
	return nil, fmt.Errorf("tagged: unexpected JSON value %v", raw)
}

// asValue reports whether obj is a value node: exactly the two string
// members "type" and "value", with a known type name.
func asValue(obj map[string]any) (*toml.Value, bool) {
	if len(obj) != 2 {
		return nil, false
	}
	ts, ok1 := obj["type"].(string)
	vs, ok2 := obj["value"].(string)
	if !ok1 || !ok2 {
		return nil, false
	}
	typ, ok := toml.ParseType(ts)
	if !ok {
		return nil, false
	}
	return &toml.Value{Type: typ, Text: vs}, true
}
