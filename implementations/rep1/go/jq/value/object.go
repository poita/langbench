package value

import (
	"slices"
	"strings"
	"sync/atomic"
)

// indexThreshold is the entry count above which an object keeps a hash index
// (key -> position); smaller objects are searched linearly.
const indexThreshold = 16

// Entry is one key/value pair of an object.
type Entry struct {
	Key   string
	Value Value
}

// Object is an immutable, insertion-ordered string-keyed map. Build one with
// an ObjectBuilder. An Object may be shared freely, including between
// goroutines.
type Object struct {
	entries []Entry
	index   map[string]int32        // nil while len(entries) <= indexThreshold
	order   atomic.Pointer[[]int32] // memoised sorted-key permutation
}

// Len returns the number of entries.
func (o *Object) Len() int { return len(o.entries) }

// Entries returns the entries in insertion order. The slice is shared and
// must not be modified.
func (o *Object) Entries() []Entry { return o.entries }

func (o *Object) find(key string) int {
	if o.index != nil {
		if i, ok := o.index[key]; ok {
			return int(i)
		}
		return -1
	}
	for i := range o.entries {
		if o.entries[i].Key == key {
			return i
		}
	}
	return -1
}

// Get returns the value stored under key.
func (o *Object) Get(key string) (Value, bool) {
	if i := o.find(key); i >= 0 {
		return o.entries[i].Value, true
	}
	return Null, false
}

// Has reports whether key is present.
func (o *Object) Has(key string) bool { return o.find(key) >= 0 }

// SortedOrder returns the permutation of entry positions that visits the
// entries in code-point (UTF-8 byte) order of their keys. It is computed on
// first use and memoised. The slice is shared and must not be modified.
func (o *Object) SortedOrder() []int32 {
	if p := o.order.Load(); p != nil {
		return *p
	}
	ord := make([]int32, len(o.entries))
	for i := range ord {
		ord[i] = int32(i)
	}
	slices.SortFunc(ord, func(a, b int32) int {
		return strings.Compare(o.entries[a].Key, o.entries[b].Key)
	})
	o.order.Store(&ord)
	return ord
}

// SortedKeys returns the keys in code-point order.
func (o *Object) SortedKeys() []string {
	ord := o.SortedOrder()
	keys := make([]string, len(ord))
	for i, p := range ord {
		keys[i] = o.entries[p].Key
	}
	return keys
}

// ObjectBuilder constructs an Object. Setting an existing key replaces its
// value but keeps its original position. A builder must not be used after
// Build.
type ObjectBuilder struct {
	o *Object
}

// NewObjectBuilder returns an empty builder with room for capacity entries.
func NewObjectBuilder(capacity int) *ObjectBuilder {
	return &ObjectBuilder{o: &Object{entries: make([]Entry, 0, capacity)}}
}

// Builder returns a builder initialised with a copy of o's entries and room
// for extra more.
func (o *Object) Builder(extra int) *ObjectBuilder {
	es := make([]Entry, len(o.entries), len(o.entries)+extra)
	copy(es, o.entries)
	return &ObjectBuilder{o: &Object{entries: es}}
}

// Len returns the current number of entries.
func (b *ObjectBuilder) Len() int { return len(b.o.entries) }

// Get looks a key up in the object under construction.
func (b *ObjectBuilder) Get(key string) (Value, bool) {
	b.ensureIndex()
	return b.o.Get(key)
}

func (b *ObjectBuilder) ensureIndex() {
	o := b.o
	if o.index == nil && len(o.entries) > indexThreshold {
		o.index = make(map[string]int32, len(o.entries)*2)
		for i, e := range o.entries {
			o.index[e.Key] = int32(i)
		}
	}
}

// Set stores v under key.
func (b *ObjectBuilder) Set(key string, v Value) {
	b.ensureIndex()
	o := b.o
	if i := o.find(key); i >= 0 {
		o.entries[i].Value = v
		return
	}
	o.entries = append(o.entries, Entry{key, v})
	if o.index != nil {
		o.index[key] = int32(len(o.entries) - 1)
	}
}

// Build finishes the object and returns it as a Value.
func (b *ObjectBuilder) Build() Value {
	b.ensureIndex()
	o := b.o
	b.o = nil
	return Value{kind: KindObject, ref: o}
}

// ObjectFromEntries builds an object directly from entries whose keys are
// known to be distinct. It takes ownership of the slice.
func ObjectFromEntries(entries []Entry) Value {
	b := &ObjectBuilder{o: &Object{entries: entries}}
	return b.Build()
}
