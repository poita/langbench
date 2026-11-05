package syntax

// Interner maps identifier spellings to dense integer ids starting at 0, so
// that later phases can index arrays by name. The zero value is not usable;
// create one with NewInterner. An Interner is not safe for concurrent use.
type Interner struct {
	ids   map[string]int32
	names []string
}

// NewInterner returns an empty Interner.
func NewInterner() *Interner {
	return &Interner{ids: make(map[string]int32)}
}

// Intern returns the id of name, assigning the next free id if it is new.
func (in *Interner) Intern(name string) int32 {
	if id, ok := in.ids[name]; ok {
		return id
	}
	return in.add(name)
}

// internBytes is Intern for a byte slice; looking up an existing name does
// not allocate.
func (in *Interner) internBytes(b []byte) int32 {
	if id, ok := in.ids[string(b)]; ok {
		return id
	}
	return in.add(string(b))
}

func (in *Interner) add(name string) int32 {
	id := int32(len(in.names))
	in.ids[name] = id
	in.names = append(in.names, name)
	return id
}

// Lookup returns the id of name and whether it has been interned.
func (in *Interner) Lookup(name string) (int32, bool) {
	id, ok := in.ids[name]
	return id, ok
}

// Name returns the spelling of an id.
func (in *Interner) Name(id int32) string { return in.names[id] }

// Len returns the number of distinct names interned so far.
func (in *Interner) Len() int { return len(in.names) }
