package value

import (
	"slices"
	"strings"
)

// indexThreshold is the object size above which a hash index is used for key
// lookup; smaller objects are scanned linearly.
const indexThreshold = 8

// Entry is one key/value pair of an object.
type Entry struct {
	Key string
	Val Value
}

// Object is an insertion-ordered string-keyed map. Keys keep the position at
// which they were first inserted.
//
// An Object is mutable only through Set, and only while it is a private
// builder (see NewObject). Once wrapped with ObjectValue it must be treated as
// immutable.
type Object struct {
	entries []Entry
	index   map[string]int32 // key -> position; built lazily when large
	order   []int32          // positions sorted by key; built lazily
}

// NewObject returns an empty builder object with room for n entries.
func NewObject(n int) *Object {
	return &Object{entries: make([]Entry, 0, n)}
}

// ObjectFromEntries builds an object from entries, which are copied. Repeated
// keys keep their first position and take their last value.
func ObjectFromEntries(entries []Entry) *Object {
	o := &Object{entries: make([]Entry, len(entries))}
	copy(o.entries, entries)
	if !o.hasDuplicates() {
		return o
	}
	b := NewObject(len(entries))
	for _, e := range entries {
		b.Set(e.Key, e.Val)
	}
	return b
}

func (o *Object) hasDuplicates() bool {
	n := len(o.entries)
	if n <= indexThreshold {
		for i := 1; i < n; i++ {
			for j := 0; j < i; j++ {
				if o.entries[i].Key == o.entries[j].Key {
					return true
				}
			}
		}
		return false
	}
	idx := make(map[string]int32, n)
	for i, e := range o.entries {
		if _, ok := idx[e.Key]; ok {
			return true
		}
		idx[e.Key] = int32(i)
	}
	o.index = idx
	return false
}

// Len returns the number of entries.
func (o *Object) Len() int { return len(o.entries) }

// Entries returns the entries in insertion order. The slice must not be
// modified.
func (o *Object) Entries() []Entry { return o.entries }

func (o *Object) find(key string) int {
	if len(o.entries) <= indexThreshold {
		for i := range o.entries {
			if o.entries[i].Key == key {
				return i
			}
		}
		return -1
	}
	if o.index == nil {
		o.index = make(map[string]int32, len(o.entries))
		for i, e := range o.entries {
			o.index[e.Key] = int32(i)
		}
	}
	if i, ok := o.index[key]; ok {
		return int(i)
	}
	return -1
}

// Get returns the value stored under key.
func (o *Object) Get(key string) (Value, bool) {
	if i := o.find(key); i >= 0 {
		return o.entries[i].Val, true
	}
	return Null, false
}

// Has reports whether key is present.
func (o *Object) Has(key string) bool { return o.find(key) >= 0 }

// Set stores val under key: an existing key keeps its position, a new key is
// appended. Set mutates o, so it must only be used on a builder that has not
// been published as a Value yet.
func (o *Object) Set(key string, val Value) {
	o.order = nil
	if i := o.find(key); i >= 0 {
		o.entries[i].Val = val
		return
	}
	o.entries = append(o.entries, Entry{key, val})
	if o.index != nil {
		o.index[key] = int32(len(o.entries) - 1)
	}
}

// Clone returns a private builder copy of o with room for extra more entries.
func (o *Object) Clone(extra int) *Object {
	c := &Object{entries: make([]Entry, len(o.entries), len(o.entries)+extra)}
	copy(c.entries, o.entries)
	return c
}

// SortedOrder returns the positions of the entries sorted by key (code point
// order, which is UTF-8 byte order). The permutation is computed once and
// memoised; the returned slice must not be modified.
func (o *Object) SortedOrder() []int32 {
	if o.order == nil && len(o.entries) > 0 {
		ord := make([]int32, len(o.entries))
		for i := range ord {
			ord[i] = int32(i)
		}
		es := o.entries
		slices.SortFunc(ord, func(a, b int32) int { return strings.Compare(es[a].Key, es[b].Key) })
		o.order = ord
	}
	return o.order
}

// SortedKeys returns the keys in code point order.
func (o *Object) SortedKeys() []string {
	ord := o.SortedOrder()
	keys := make([]string, len(ord))
	for i, p := range ord {
		keys[i] = o.entries[p].Key
	}
	return keys
}

// ObjectFromUniqueEntries builds an object from entries that are known to
// have distinct keys; the entries are copied and no duplicate check is made.
func ObjectFromUniqueEntries(entries []Entry) *Object {
	o := &Object{entries: make([]Entry, len(entries))}
	copy(o.entries, entries)
	return o
}
