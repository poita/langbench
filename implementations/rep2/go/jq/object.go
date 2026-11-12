package jq

import (
	"slices"
	"sync/atomic"
)

// smallObject is the largest object that is searched linearly; bigger objects
// get a hash index.
const smallObject = 16

// objIndex is a key -> position map that may be shared by an object and the
// objects obtained from it by appending new keys (see mergeObjects). n is the
// number of keys the map covers; an object whose length is below that must
// ignore positions >= its length, and only the object whose length equals n
// (the "tip") may extend the map.
type objIndex struct {
	m map[string]int
	n int
}

// Object is an insertion-ordered string-keyed map. Lookup is O(1) expected.
//
// Build an Object with NewObject and Set, then treat it as immutable. Set must
// not be called once the object has been shared.
type Object struct {
	keys  []string
	vals  []Value
	index *objIndex             // only when len(keys) > smallObject
	order atomic.Pointer[[]int] // positions sorted by key; computed at most once
}

// NewObject returns an empty object with room for n entries.
func NewObject(n int) *Object {
	return &Object{keys: make([]string, 0, n), vals: make([]Value, 0, n)}
}

// Len returns the number of keys.
func (o *Object) Len() int { return len(o.keys) }

// At returns the i'th entry in insertion order.
func (o *Object) At(i int) (string, Value) { return o.keys[i], o.vals[i] }

func (o *Object) find(k string) int {
	if o.index != nil {
		if i, ok := o.index.m[k]; ok && i < len(o.keys) {
			return i
		}
		return -1
	}
	for i, s := range o.keys {
		if len(s) == len(k) && s == k {
			return i
		}
	}
	return -1
}

// Get returns the value stored under k.
func (o *Object) Get(k string) (Value, bool) {
	if i := o.find(k); i >= 0 {
		return o.vals[i], true
	}
	return nil, false
}

// Set stores v under k. An existing key keeps its position and takes the new
// value; a new key is appended.
func (o *Object) Set(k string, v Value) {
	if i := o.find(k); i >= 0 {
		o.vals[i] = v
		return
	}
	o.append(k, v)
}

// append adds a key known not to be present.
func (o *Object) append(k string, v Value) {
	o.keys = append(o.keys, k)
	o.vals = append(o.vals, v)
	o.order.Store(nil)
	if o.index != nil {
		o.index.m[k] = len(o.keys) - 1
		o.index.n = len(o.keys)
	} else if len(o.keys) > smallObject {
		o.buildIndex()
	}
}

func (o *Object) buildIndex() {
	m := make(map[string]int, len(o.keys)*2)
	for i, k := range o.keys {
		m[k] = i
	}
	o.index = &objIndex{m: m, n: len(o.keys)}
}

// Copy returns a shallow copy that can be extended independently.
func (o *Object) Copy(extra int) *Object {
	c := &Object{
		keys: make([]string, len(o.keys), len(o.keys)+extra),
		vals: make([]Value, len(o.vals), len(o.vals)+extra),
	}
	copy(c.keys, o.keys)
	copy(c.vals, o.vals)
	if len(c.keys) > smallObject {
		c.buildIndex()
	}
	return c
}

// sortedOrder returns the positions of the keys in ascending key order. It is
// computed at most once per object state.
func (o *Object) sortedOrder() []int {
	if p := o.order.Load(); p != nil {
		return *p
	}
	ord := make([]int, len(o.keys))
	for i := range ord {
		ord[i] = i
	}
	slices.SortFunc(ord, func(a, b int) int {
		ka, kb := o.keys[a], o.keys[b]
		switch {
		case ka < kb:
			return -1
		case ka > kb:
			return 1
		}
		return 0
	})
	o.order.Store(&ord)
	return ord
}

// SortedKeys returns the keys in ascending code point order.
func (o *Object) SortedKeys() []string {
	ord := o.sortedOrder()
	out := make([]string, len(ord))
	for i, p := range ord {
		out[i] = o.keys[p]
	}
	return out
}

// extend returns o with the entries of b appended, sharing o's storage. It
// reports false (doing nothing) unless o is the tip of its index and none of
// b's keys is already present.
func (o *Object) extend(b *Object) (*Object, bool) {
	if o.index == nil || o.index.n != len(o.keys) {
		return nil, false
	}
	for _, k := range b.keys {
		if o.find(k) >= 0 {
			return nil, false
		}
	}
	r := &Object{index: o.index}
	r.keys = append(o.keys, b.keys...)
	r.vals = append(o.vals, b.vals...)
	for i, k := range b.keys {
		o.index.m[k] = len(o.keys) + i
	}
	o.index.n = len(r.keys)
	return r, true
}
