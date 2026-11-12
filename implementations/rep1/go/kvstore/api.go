package tessera

import (
	"bytes"

	"example.com/tessera/value"
)

// ValidateKey checks the length rules for a primary key.
func ValidateKey(key []byte) error {
	if len(key) < 1 || len(key) > MaxKey {
		return newErr(ErrBadKey)
	}
	return nil
}

// ParsePath splits and validates a dotted field path such as "address.city".
// Every segment must be a non-empty identifier ([A-Za-z_][A-Za-z0-9_]*), there
// may be at most MaxSegments of them and the whole text at most MaxPath bytes.
func ParsePath(text string) ([]string, error) {
	if len(text) > MaxPath {
		return nil, newErr(ErrBadPath)
	}
	var segs []string
	start := 0
	for i := 0; i <= len(text); i++ {
		if i < len(text) && text[i] != '.' {
			continue
		}
		seg := text[start:i]
		if !isWord(seg) {
			return nil, newErr(ErrSyntax)
		}
		segs = append(segs, seg)
		start = i + 1
	}
	if len(segs) > MaxSegments {
		return nil, newErr(ErrBadPath)
	}
	return segs, nil
}

func isWord(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (i > 0 && c >= '0' && c <= '9')
		if !ok {
			return false
		}
	}
	return true
}

// lookup finds the cell of key in the primary tree.
func (db *DB) lookup(key []byte) (cell, bool) { return db.primary().find(key) }

// loadDoc reads and deserialises the document of a primary cell.
func (db *DB) loadDoc(c *cell) value.Value {
	v, err := value.Deserialize(db.readDoc(c))
	if err != nil {
		panic("tessera: corrupt document in database: " + err.Error())
	}
	return v
}

// Get returns the document stored under key.
func (db *DB) Get(key []byte) (value.Value, error) {
	if err := ValidateKey(key); err != nil {
		return value.Value{}, err
	}
	c, ok := db.lookup(key)
	if !ok {
		return value.Value{}, newErr(ErrNotFound)
	}
	return db.loadDoc(&c), nil
}

// Put stores doc under key, creating or replacing it (SPEC §14.3). It reports
// whether the key was new.
func (db *DB) Put(key []byte, doc value.Value) (created bool, err error) {
	if err := ValidateKey(key); err != nil {
		return false, err
	}
	if doc.Depth() > MaxDepth {
		return false, newErr(ErrDepth)
	}
	ser := value.Serialize(doc)
	if len(ser) > MaxDoc {
		return false, newErr(ErrDocTooLarge)
	}
	newKeys := db.keysFor(doc, key)
	if err := newKeys.check(); err != nil {
		return false, err
	}
	old, existed := db.lookup(key)
	var oldKeys indexKeys
	if existed {
		oldKeys = db.keysFor(db.loadDoc(&old), key)
	}
	db.write(key, ser, &old, existed, &oldKeys, &newKeys)
	return !existed, nil
}

// write performs the primary-tree and index changes of a put, update or unset.
func (db *DB) write(key, ser []byte, old *cell, existed bool, oldKeys, newKeys *indexKeys) {
	db.mutate(func() {
		if existed && old.overflow != 0 {
			db.freeOverflow(old.overflow)
		}
		c := db.makeCell(append([]byte(nil), key...), ser)
		if !db.primary().insert(c) {
			db.hdr.primaryCount++
		}
		db.maintainIndexes(oldKeys, newKeys)
	})
}

// Delete removes the document stored under key.
func (db *DB) Delete(key []byte) error {
	if err := ValidateKey(key); err != nil {
		return err
	}
	c, ok := db.lookup(key)
	if !ok {
		return newErr(ErrNotFound)
	}
	oldKeys := db.keysFor(db.loadDoc(&c), key)
	db.mutate(func() {
		if c.overflow != 0 {
			db.freeOverflow(c.overflow)
		}
		db.primary().remove(key)
		db.hdr.primaryCount--
		for i := range db.hdr.slots {
			if db.hdr.slots[i].live && oldKeys[i].ok {
				db.indexDelete(i, oldKeys[i].key)
			}
		}
	})
	return nil
}

// Update sets the field at path inside the document stored under key to v,
// creating missing intermediate objects (SPEC §18.3).
func (db *DB) Update(key []byte, path []string, v value.Value) error {
	if err := ValidateKey(key); err != nil {
		return err
	}
	c, ok := db.lookup(key)
	if !ok {
		return newErr(ErrNotFound)
	}
	old := db.loadDoc(&c)
	nd, err := value.Set(old, path, v)
	if err != nil {
		return newErr(ErrNotObject)
	}
	if nd.Depth() > MaxDepth {
		return newErr(ErrDepth)
	}
	if value.SerializedLen(nd) > MaxDoc {
		return newErr(ErrDocTooLarge)
	}
	newKeys := db.keysFor(nd, key)
	if err := newKeys.check(); err != nil {
		return err
	}
	oldKeys := db.keysFor(old, key)
	db.write(key, value.Serialize(nd), &c, true, &oldKeys, &newKeys)
	return nil
}

// Unset removes the field at path from the document stored under key.
func (db *DB) Unset(key []byte, path []string) error {
	if err := ValidateKey(key); err != nil {
		return err
	}
	c, ok := db.lookup(key)
	if !ok {
		return newErr(ErrNotFound)
	}
	old := db.loadDoc(&c)
	nd, err := value.Unset(old, path)
	if err != nil {
		if err == value.ErrNoField {
			return newErr(ErrNoField)
		}
		return newErr(ErrNotObject)
	}
	newKeys := db.keysFor(nd, key)
	oldKeys := db.keysFor(old, key)
	db.write(key, value.Serialize(nd), &c, true, &oldKeys, &newKeys)
	return nil
}

// ScanOptions selects and orders the keys returned by Scan.
type ScanOptions struct {
	From, To []byte // inclusive lower and exclusive upper bound, when HasFrom / HasTo
	HasFrom  bool
	HasTo    bool
	Limit    int // maximum number of results when HasLimit
	HasLimit bool
	Reverse  bool // descending key order
	KeysOnly bool // leave Entry.Doc unset
}

// Scan returns the keys in the selected range in ascending (or, with Reverse,
// descending) order. The limit is applied after ordering and the walk stops as
// soon as it is reached; documents are read only for returned entries.
func (db *DB) Scan(o ScanOptions) []Entry {
	if o.HasLimit && o.Limit <= 0 {
		return nil
	}
	var out []Entry
	emit := func(c *cell) bool {
		e := Entry{Key: c.key}
		if !o.KeysOnly {
			e.Doc = db.loadDoc(c)
		}
		out = append(out, e)
		return !(o.HasLimit && len(out) >= o.Limit)
	}
	from, to := o.From, o.To
	if o.HasFrom && from == nil {
		from = []byte{}
	}
	if o.HasTo && to == nil {
		to = []byte{}
	}
	if !o.Reverse {
		var start []byte
		if o.HasFrom {
			start = from
		}
		db.primary().walkFrom(start, func(c *cell) bool {
			if o.HasTo && bytes.Compare(c.key, to) >= 0 {
				return false
			}
			return emit(c)
		})
	} else {
		var start []byte
		if o.HasTo {
			start = to
		}
		db.primary().walkBackFrom(start, func(c *cell) bool {
			if o.HasFrom && bytes.Compare(c.key, from) < 0 {
				return false
			}
			return emit(c)
		})
	}
	return out
}

// IndexInfo describes a live index (SPEC §19.2).
type IndexInfo struct {
	Slot    int
	Path    string
	Root    uint32
	Entries uint32
}

// Indexes lists the live indexes in slot order.
func (db *DB) Indexes() []IndexInfo {
	var out []IndexInfo
	for i := range db.hdr.slots {
		if s := &db.hdr.slots[i]; s.live {
			out = append(out, IndexInfo{i, s.path, s.root, s.entries})
		}
	}
	return out
}

func (db *DB) findSlot(text string) int {
	for i := range db.hdr.slots {
		if db.hdr.slots[i].live && db.hdr.slots[i].path == text {
			return i
		}
	}
	return -1
}

// CreateIndex builds a secondary index on the dotted path and returns its
// number of entries (SPEC §14.4).
func (db *DB) CreateIndex(path string) (entries int, err error) {
	segs, err := ParsePath(path)
	if err != nil {
		return 0, err
	}
	if db.findSlot(path) >= 0 {
		return 0, newErr(ErrIndexExists)
	}
	if db.hdr.indexCount() == MaxIndexes {
		return 0, newErr(ErrIndexLimit)
	}
	// One pass over the primary tree, in key order, collecting the entries.
	var keys [][]byte
	tooLong := false
	db.primary().walkFrom(nil, func(c *cell) bool {
		doc := db.loadDoc(c)
		if ik, ok := indexKey(segs, doc, c.key); ok {
			if len(ik) > MaxIndexKey {
				tooLong = true
				return false
			}
			keys = append(keys, ik)
		}
		return true
	})
	if tooLong {
		return 0, newErr(ErrIndexKeyTooLong)
	}
	db.mutate(func() {
		slot := 0
		for db.hdr.slots[slot].live {
			slot++
		}
		db.hdr.slots[slot] = indexSlot{live: true, path: path, segs: segs}
		for _, k := range keys {
			db.indexInsert(slot, k)
		}
	})
	return len(keys), nil
}

// DropIndex removes the index on the dotted path and returns the number of
// pages freed (SPEC §14.5).
func (db *DB) DropIndex(path string) (pages int, err error) {
	if _, err := ParsePath(path); err != nil {
		return 0, err
	}
	slot := db.findSlot(path)
	if slot < 0 {
		return 0, newErr(ErrIndexMissing)
	}
	db.mutate(func() {
		if root := db.hdr.slots[slot].root; root != 0 {
			pages = db.indexTree(slot).freeTree(root)
		}
		db.hdr.slots[slot] = indexSlot{}
	})
	return pages, nil
}
