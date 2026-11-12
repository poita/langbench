package value

import (
	"slices"
	"strings"
	"sync"
)

// linearMax is the largest object size for which lookups scan the key slice
// instead of using a hash index.
const linearMax = 8

// Object is an immutable, insertion-ordered map from string keys to Values.
// Create objects with a Builder, Merge or DeepMerge. An Object is safe for
// concurrent use.
type Object struct {
	keys []string
	vals []Value

	idxOnce sync.Once
	idx     map[string]int

	ordOnce sync.Once
	ord     []int // positions of keys in ascending key order
}

// Len returns the number of keys.
func (o *Object) Len() int { return len(o.keys) }

// Get returns the value stored under key and whether it exists. Lookup is
// O(1) expected.
func (o *Object) Get(key string) (Value, bool) {
	if i := o.find(key); i >= 0 {
		return o.vals[i], true
	}
	return nil, false
}

// Has reports whether key exists.
func (o *Object) Has(key string) bool { return o.find(key) >= 0 }

// Keys returns the keys in insertion order. The slice must not be modified.
func (o *Object) Keys() []string { return o.keys }

// Values returns the values in insertion order. The slice must not be
// modified.
func (o *Object) Values() []Value { return o.vals }

// At returns the i'th key and value in insertion order.
func (o *Object) At(i int) (string, Value) { return o.keys[i], o.vals[i] }

// SortedKeys returns a new slice with the keys sorted by code point. The
// sort order is computed at most once per object.
func (o *Object) SortedKeys() []string {
	ord := o.order()
	out := make([]string, len(ord))
	for i, p := range ord {
		out[i] = o.keys[p]
	}
	return out
}

// order returns the insertion positions sorted by key; computed once.
func (o *Object) order() []int {
	o.ordOnce.Do(func() {
		ord := make([]int, len(o.keys))
		for i := range ord {
			ord[i] = i
		}
		slices.SortFunc(ord, func(a, b int) int { return strings.Compare(o.keys[a], o.keys[b]) })
		o.ord = ord
	})
	return o.ord
}

func (o *Object) find(key string) int {
	if len(o.keys) <= linearMax {
		return linearFind(o.keys, key)
	}
	o.idxOnce.Do(func() { o.idx = buildIndex(o.keys) })
	if i, ok := o.idx[key]; ok {
		return i
	}
	return -1
}

// findNoBuild is like find but never builds a hash index; it is used when a
// scan is cheaper than building one.
func (o *Object) findNoBuild(key string) int {
	if len(o.keys) > linearMax && o.idx != nil {
		// idx is only read here when it was installed by a completed Do; reading
		// it racily is avoided by going through find in that case.
		return o.find(key)
	}
	return linearFind(o.keys, key)
}

func linearFind(keys []string, key string) int {
	for i, k := range keys {
		if len(k) == len(key) && k == key {
			return i
		}
	}
	return -1
}

func buildIndex(keys []string) map[string]int {
	m := make(map[string]int, len(keys))
	for i, k := range keys {
		m[k] = i
	}
	return m
}

// Builder constructs an Object by inserting keys one at a time. Setting an
// existing key replaces its value but keeps its original position. A Builder
// must not be used after Build is called.
type Builder struct {
	keys []string
	vals []Value
	idx  map[string]int
}

// NewBuilder returns a Builder with room for hint keys.
func NewBuilder(hint int) *Builder {
	return &Builder{keys: make([]string, 0, hint), vals: make([]Value, 0, hint)}
}

// Set inserts or replaces key.
func (b *Builder) Set(key string, v Value) {
	var pos int
	if b.idx != nil {
		if p, ok := b.idx[key]; ok {
			b.vals[p] = v
			return
		}
	} else if pos = linearFind(b.keys, key); pos >= 0 {
		b.vals[pos] = v
		return
	}
	b.keys = append(b.keys, key)
	b.vals = append(b.vals, v)
	if b.idx != nil {
		b.idx[key] = len(b.keys) - 1
	} else if len(b.keys) > linearMax {
		b.idx = buildIndex(b.keys)
	}
}

// Len returns the number of keys set so far.
func (b *Builder) Len() int { return len(b.keys) }

// Build returns the finished Object.
func (b *Builder) Build() *Object {
	o := &Object{keys: b.keys, vals: b.vals}
	if b.idx != nil {
		o.idx = b.idx
		o.idxOnce.Do(func() {})
	}
	return o
}

// Merge returns a with every key of b set in order (jq's object +): existing
// keys keep their position and take b's value, new keys are appended. It costs
// O(|a| + |b|).
func Merge(a, b *Object) *Object { return merge(a, b, false) }

// DeepMerge is like Merge but, when both values under a key are objects, they
// are merged recursively (jq's object *).
func DeepMerge(a, b *Object) *Object { return merge(a, b, true) }

func merge(a, b *Object, deep bool) *Object {
	if len(b.keys) == 0 {
		return a
	}
	if len(a.keys) == 0 {
		return b
	}
	keys := make([]string, len(a.keys), len(a.keys)+len(b.keys))
	vals := make([]Value, len(a.keys), len(a.keys)+len(b.keys))
	copy(keys, a.keys)
	copy(vals, a.vals)
	// A scan of a per key of b is cheaper than building a's index when b is
	// small; otherwise build (and cache) the index on a.
	useIndex := len(b.keys) > linearMax
	for i, k := range b.keys {
		var p int
		if useIndex {
			p = a.find(k)
		} else {
			p = a.findNoBuild(k)
		}
		bv := b.vals[i]
		if p < 0 {
			keys = append(keys, k)
			vals = append(vals, bv)
			continue
		}
		if deep {
			if ao, ok := a.vals[p].(*Object); ok {
				if bo, ok := bv.(*Object); ok {
					vals[p] = merge(ao, bo, true)
					continue
				}
			}
		}
		vals[p] = bv
	}
	return &Object{keys: keys, vals: vals}
}
