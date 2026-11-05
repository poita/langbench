package value

import (
	"strings"

	"example.com/kvstore/kverr"
)

// Path is a field path: a sequence of object field names.
type Path []string

// String returns the path text: the segments joined by ".".
func (p Path) String() string { return strings.Join(p, ".") }

// ParsePath splits path text into segments. It does not validate the limits.
func ParsePath(text string) Path { return Path(strings.Split(text, ".")) }

// Lookup resolves p against v. Only object fields are traversed; a path into
// a list or scalar is missing.
func (v Value) Lookup(p Path) (Value, bool) {
	cur := v
	for _, seg := range p {
		next, ok := cur.Get(seg)
		if !ok {
			return Value{}, false
		}
		cur = next
	}
	return cur, true
}

// Set returns a copy of v with the value at p replaced by nv. Missing
// intermediate objects are created. It fails with kverr.NotObject when the
// document, or a value reached before the last segment, is present but not an
// object. v is not modified.
func Set(v Value, p Path, nv Value) (Value, error) {
	if len(p) == 0 {
		return nv, nil
	}
	if v.Kind != Object {
		return Value{}, kverr.NotObject
	}
	i, found := v.field(p[0])
	var child Value
	if len(p) == 1 {
		child = nv
	} else {
		sub := Value{Kind: Object}
		if found {
			sub = v.Fields[i].Value
		}
		var err error
		child, err = Set(sub, p[1:], nv)
		if err != nil {
			return Value{}, err
		}
	}
	fields := make([]Field, 0, len(v.Fields)+1)
	fields = append(fields, v.Fields[:i]...)
	fields = append(fields, Field{Name: p[0], Value: child})
	if found {
		fields = append(fields, v.Fields[i+1:]...)
	} else {
		fields = append(fields, v.Fields[i:]...)
	}
	return Value{Kind: Object, Fields: fields}, nil
}

// Unset returns a copy of v with the field at p removed. It fails with
// kverr.NotObject when a value along the path is not an object and with
// kverr.NoField when an object lacks the field; the first failure decides.
func Unset(v Value, p Path) (Value, error) {
	if v.Kind != Object {
		return Value{}, kverr.NotObject
	}
	i, found := v.field(p[0])
	if !found {
		return Value{}, kverr.NoField
	}
	fields := make([]Field, 0, len(v.Fields))
	fields = append(fields, v.Fields[:i]...)
	if len(p) > 1 {
		child, err := Unset(v.Fields[i].Value, p[1:])
		if err != nil {
			return Value{}, err
		}
		fields = append(fields, Field{Name: p[0], Value: child})
	}
	fields = append(fields, v.Fields[i+1:]...)
	return Value{Kind: Object, Fields: fields}, nil
}
