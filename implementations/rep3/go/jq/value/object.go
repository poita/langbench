package value

import (
	"sort"
)

// indexThreshold is the object size above which lookups use a hash index.
const indexThreshold = 12

// Object is an insertion-ordered map from string keys to values. Objects are
// built with Set and then wrapped with ObjectValue; once published they must
// not be modified.
type Object struct {
	keys   []string
	vals   []Value
	index  map[string]int32 // built lazily once len(keys) > indexThreshold
	sorted []int32          // memoised permutation of entries in key order
}

// NewObject returns an empty object with room for n entries.
func NewObject(n int) *Object {
	return &Object{keys: make([]string, 0, n), vals: make([]Value, 0, n)}
}

// Len returns the number of entries.
func (o *Object) Len() int { return len(o.keys) }

// KeyAt and ValueAt return the i-th entry in insertion order.
func (o *Object) KeyAt(i int) string { return o.keys[i] }

// ValueAt returns the value of the i-th entry in insertion order.
func (o *Object) ValueAt(i int) Value { return o.vals[i] }

// find returns the position of key k, or -1.
func (o *Object) find(k string) int {
	if len(o.keys) <= indexThreshold {
		for i, kk := range o.keys {
			if kk == k {
				return i
			}
		}
		return -1
	}
	if o.index == nil {
		o.index = make(map[string]int32, len(o.keys))
		for i, kk := range o.keys {
			o.index[kk] = int32(i)
		}
	}
	if i, ok := o.index[k]; ok {
		return int(i)
	}
	return -1
}

// Get returns the value stored under k.
func (o *Object) Get(k string) (Value, bool) {
	if i := o.find(k); i >= 0 {
		return o.vals[i], true
	}
	return Null, false
}

// Has reports whether k is present.
func (o *Object) Has(k string) bool { return o.find(k) >= 0 }

// Set stores v under k: an existing key keeps its position and gets the new
// value, a new key is appended. Set must only be used on an object that is
// still being built.
func (o *Object) Set(k string, v Value) {
	if i := o.find(k); i >= 0 {
		o.vals[i] = v
		return
	}
	o.appendNew(k, v)
}

// appendNew appends a key known to be absent.
func (o *Object) appendNew(k string, v Value) {
	if o.index != nil {
		o.index[k] = int32(len(o.keys))
	}
	o.keys = append(o.keys, k)
	o.vals = append(o.vals, v)
}

// AppendNew appends a key the caller knows is not yet present.
func (o *Object) AppendNew(k string, v Value) { o.appendNew(k, v) }

// Copy returns a private builder holding the same entries, with room for
// extra more.
func (o *Object) Copy(extra int) *Object {
	n := len(o.keys)
	c := &Object{keys: make([]string, n, n+extra), vals: make([]Value, n, n+extra)}
	copy(c.keys, o.keys)
	copy(c.vals, o.vals)
	return c
}

// sortedOrder returns the entry positions in code-point order of key,
// computing it once.
func (o *Object) sortedOrder() []int32 {
	if o.sorted == nil {
		p := make([]int32, len(o.keys))
		for i := range p {
			p[i] = int32(i)
		}
		sort.Slice(p, func(a, b int) bool { return o.keys[p[a]] < o.keys[p[b]] })
		o.sorted = p
	}
	return o.sorted
}

// SortedKeys returns the keys in code-point order.
func (o *Object) SortedKeys() []string {
	p := o.sortedOrder()
	ks := make([]string, len(p))
	for i, j := range p {
		ks[i] = o.keys[j]
	}
	return ks
}

// Merge returns a + b: a copy of a with each entry of b set in order.
func Merge(a, b *Object) *Object {
	if b.Len() == 0 {
		return a
	}
	r := a.Copy(b.Len())
	if b.Len() <= 8 {
		// Few keys: linear scans avoid building a hash index for a.
		for i, k := range b.keys {
			found := false
			for j, kk := range r.keys[:a.Len()] {
				if kk == k {
					r.vals[j] = b.vals[i]
					found = true
					break
				}
			}
			if !found {
				r.keys = append(r.keys, k)
				r.vals = append(r.vals, b.vals[i])
			}
		}
		return r
	}
	for i, k := range b.keys {
		r.Set(k, b.vals[i])
	}
	return r
}

// DeepMerge returns a * b: like Merge, but when both values under a key are
// objects they are merged recursively.
func DeepMerge(a, b *Object) *Object {
	r := a.Copy(b.Len())
	for i, k := range b.keys {
		bv := b.vals[i]
		if j := r.find(k); j >= 0 {
			if av := r.vals[j]; av.kind == KindObject && bv.kind == KindObject {
				r.vals[j] = ObjectValue(DeepMerge(av.Obj(), bv.Obj()))
			} else {
				r.vals[j] = bv
			}
			continue
		}
		r.appendNew(k, bv)
	}
	return r
}

// Interner shares one string per distinct key text.
type Interner map[string]string

// Intern returns the shared string equal to b.
func (in Interner) Intern(b []byte) string {
	if s, ok := in[string(b)]; ok { // no allocation for map lookups
		return s
	}
	s := string(b)
	in[s] = s
	return s
}
