package engine

import (
	"bytes"
	"sort"

	"example.com/kvstore/kverr"
	"example.com/kvstore/query"
	"example.com/kvstore/value"
)

// DB is an open Tessera database. It is not safe for concurrent use.
type DB struct {
	pager
}

// Open opens a database from the contents of the main file and the log. A
// nil or empty mainFile means a fresh database. The log is recovered as
// described by the specification: committed transactions are replayed into
// the overlay and the log is trimmed after the last intact commit record; an
// invalid or missing log is discarded. The inputs are not modified.
func Open(mainFile, walFile []byte) *DB {
	db := &DB{}
	if len(mainFile) == 0 {
		db.main = freshHeaderImage()
	} else {
		db.main = append([]byte(nil), mainFile...)
	}
	var validEnd int
	db.overlay, validEnd = scanWAL(walFile)
	if validEnd == walHeaderSize {
		db.wal = walHeader()
	} else {
		db.wal = append([]byte(nil), walFile[:validEnd]...)
	}
	db.dirty = map[uint32][]byte{}
	hdrImg := db.main[:PageSize]
	if img, ok := db.overlay[1]; ok {
		hdrImg = img
	}
	db.hdr = decodeHeader(hdrImg)
	return db
}

// Images returns the current contents of the main file and the log.
func (db *DB) Images() (mainFile, walFile []byte) { return db.main, db.wal }

// InTxn reports whether an explicit or implicit transaction is open.
func (db *DB) InTxn() bool { return db.inTxn }

// Begin opens an explicit transaction.
func (db *DB) Begin() error {
	if db.inTxn {
		return kverr.TxnActive
	}
	db.begin()
	return nil
}

// Commit commits the open transaction, returning its id and frame count.
func (db *DB) Commit() (txn uint64, frames int, err error) {
	if !db.inTxn {
		return 0, 0, kverr.NoTxn
	}
	txn, frames = db.commit()
	return txn, frames, nil
}

// Rollback discards the open transaction.
func (db *DB) Rollback() error {
	if !db.inTxn {
		return kverr.NoTxn
	}
	db.rollback()
	return nil
}

// Checkpoint copies the log into the main file and returns the number of
// pages copied.
func (db *DB) Checkpoint() (int, error) {
	if db.inTxn {
		return 0, kverr.TxnActive
	}
	return db.checkpoint(), nil
}

// Stats is a snapshot of the engine's counters.
type Stats struct {
	Pages, Free, FreeHead, Docs, Root, Height, Commits, Indexes, WAL uint64
}

// Stat returns the engine's current counters, including uncommitted changes.
func (db *DB) Stat() Stats {
	return Stats{
		Pages:    uint64(db.hdr.PageCount),
		Free:     uint64(db.hdr.FreeCount),
		FreeHead: uint64(db.hdr.FreeHead),
		Docs:     uint64(db.hdr.PrimaryCount),
		Root:     uint64(db.hdr.PrimaryRoot),
		Height:   uint64(db.primary().height()),
		Commits:  db.hdr.Commits,
		Indexes:  uint64(db.hdr.IndexCount()),
		WAL:      uint64(len(db.wal)),
	}
}

// IndexInfo describes a live index.
type IndexInfo struct {
	Slot    int
	Path    string
	Root    uint32
	Entries uint32
}

// Indexes lists the live indexes in slot order.
func (db *DB) Indexes() []IndexInfo {
	var out []IndexInfo
	for s := range db.hdr.Dir {
		if d := &db.hdr.Dir[s]; d.Live {
			out = append(out, IndexInfo{s, d.Path, d.Root, d.Entries})
		}
	}
	return out
}

func (db *DB) primary() *tree {
	return &tree{p: &db.pager, leaf: typeLeaf, root: &db.hdr.PrimaryRoot}
}

func (db *DB) indexTree(slot int) *tree {
	return &tree{p: &db.pager, leaf: typeIdxLeaf, root: &db.hdr.Dir[slot].Root}
}

// atomic runs fn inside the open transaction, or inside an implicit one that
// is committed on success and rolled back on failure.
func (db *DB) atomic(fn func() error) error {
	if db.inTxn {
		return fn()
	}
	db.begin()
	if err := fn(); err != nil {
		db.rollback()
		return err
	}
	db.commit()
	return nil
}

// stored describes an existing primary cell.
type stored struct {
	docLen   uint32
	overflow uint32
	inline   []byte
}

func (db *DB) findDoc(key []byte) (stored, bool) {
	img, i, ok := db.primary().lookup(key)
	if !ok {
		return stored{}, false
	}
	dl, ov, in := rawLeafCell(img, i)
	return stored{dl, ov, in}, true
}

// docBytes returns the serialised document of a stored cell.
func (db *DB) docBytes(s stored) []byte {
	buf := make([]byte, 0, s.docLen)
	buf = append(buf, s.inline...)
	if s.overflow != 0 {
		buf = db.readOverflow(buf, s.overflow)
	}
	return buf
}

func (db *DB) readDoc(s stored) value.Value {
	v, err := value.Deserialize(db.docBytes(s))
	if err != nil {
		panic("engine: corrupt document: " + err.Error())
	}
	return v
}

// Get returns the document stored under key.
func (db *DB) Get(key []byte) (value.Value, error) {
	s, ok := db.findDoc(key)
	if !ok {
		return value.Value{}, kverr.NotFound
	}
	return db.readDoc(s), nil
}

// entryKeys computes, for every live index slot, the index key of doc, or
// reports an index key longer than MaxIndexKey.
type entrySet [MaxIndexes]struct {
	key []byte
	ok  bool
}

func (db *DB) entryKeys(doc value.Value, key []byte) (es entrySet, err error) {
	for s := range db.hdr.Dir {
		d := &db.hdr.Dir[s]
		if !d.Live {
			continue
		}
		k, ok := entryKey(doc, value.ParsePath(d.Path), key)
		if ok && len(k) > MaxIndexKey {
			return es, kverr.IndexKeyTooLong
		}
		es[s].key, es[s].ok = k, ok
	}
	return es, nil
}

func (db *DB) anyIndex() bool { return db.hdr.IndexCount() > 0 }

// storeDoc writes the document under key (replacing any existing one) and
// updates the indexes. old is the existing cell, if any, and oldEntries its
// index keys. Callers have validated everything.
func (db *DB) storeDoc(key []byte, ser []byte, old *stored, oldEntries, newEntries *entrySet) {
	if old != nil && old.overflow != 0 {
		db.freeOverflow(old.overflow)
	}
	c := cell{key: key, docLen: uint32(len(ser))}
	if len(ser) <= MaxInline {
		c.inline = ser
	} else {
		c.inline = ser[:MaxInline]
		c.overflow = db.writeOverflow(ser[MaxInline:])
	}
	db.primary().insert(c)
	if old == nil {
		db.hdr.PrimaryCount++
	}
	for s := range db.hdr.Dir {
		d := &db.hdr.Dir[s]
		if !d.Live {
			continue
		}
		var o, w []byte
		var oOK, wOK bool
		if oldEntries != nil {
			o, oOK = oldEntries[s].key, oldEntries[s].ok
		}
		w, wOK = newEntries[s].key, newEntries[s].ok
		t := db.indexTree(s)
		switch {
		case !oOK && !wOK:
		case !oOK && wOK:
			t.insert(cell{key: w})
			d.Entries++
		case oOK && !wOK:
			t.remove(o)
			d.Entries--
		case bytes.Equal(o, w):
		default:
			t.remove(o)
			t.insert(cell{key: w})
		}
	}
}

// Put stores doc under key, reporting whether the key was new.
func (db *DB) Put(key []byte, doc value.Value) (created bool, err error) {
	ser := value.Serialize(doc)
	if len(ser) > value.MaxDoc {
		return false, kverr.DocTooLarge
	}
	newEntries, err := db.entryKeys(doc, key)
	if err != nil {
		return false, err
	}
	err = db.atomic(func() error {
		old, existed := db.findDoc(key)
		var oldEntries *entrySet
		if existed && db.anyIndex() {
			es, _ := db.entryKeys(db.readDoc(old), key)
			oldEntries = &es
		}
		var op *stored
		if existed {
			op = &old
		}
		db.storeDoc(key, ser, op, oldEntries, &newEntries)
		created = !existed
		return nil
	})
	return created, err
}

// Update sets the field at path to v in the document stored under key.
func (db *DB) Update(key []byte, path value.Path, v value.Value) error {
	old, ok := db.findDoc(key)
	if !ok {
		return kverr.NotFound
	}
	oldDoc := db.readDoc(old)
	newDoc, err := value.Set(oldDoc, path, v)
	if err != nil {
		return err
	}
	if newDoc.Depth() > value.MaxDepth {
		return kverr.Depth
	}
	ser := value.Serialize(newDoc)
	if len(ser) > value.MaxDoc {
		return kverr.DocTooLarge
	}
	return db.rewrite(key, old, oldDoc, newDoc, ser)
}

// Unset removes the field at path from the document stored under key.
func (db *DB) Unset(key []byte, path value.Path) error {
	old, ok := db.findDoc(key)
	if !ok {
		return kverr.NotFound
	}
	oldDoc := db.readDoc(old)
	newDoc, err := value.Unset(oldDoc, path)
	if err != nil {
		return err
	}
	return db.rewrite(key, old, oldDoc, newDoc, value.Serialize(newDoc))
}

func (db *DB) rewrite(key []byte, old stored, oldDoc, newDoc value.Value, ser []byte) error {
	newEntries, err := db.entryKeys(newDoc, key)
	if err != nil {
		return err
	}
	var oldEntries entrySet
	if db.anyIndex() {
		oldEntries, _ = db.entryKeys(oldDoc, key)
	}
	return db.atomic(func() error {
		db.storeDoc(key, ser, &old, &oldEntries, &newEntries)
		return nil
	})
}

// Delete removes the document stored under key.
func (db *DB) Delete(key []byte) error {
	old, ok := db.findDoc(key)
	if !ok {
		return kverr.NotFound
	}
	return db.atomic(func() error {
		var oldEntries entrySet
		if db.anyIndex() {
			oldEntries, _ = db.entryKeys(db.readDoc(old), key)
		}
		if old.overflow != 0 {
			db.freeOverflow(old.overflow)
		}
		db.primary().remove(key)
		db.hdr.PrimaryCount--
		for s := range db.hdr.Dir {
			d := &db.hdr.Dir[s]
			if d.Live && oldEntries[s].ok {
				db.indexTree(s).remove(oldEntries[s].key)
				d.Entries--
			}
		}
		return nil
	})
}

// Entry is one result of a scan or find.
type Entry struct {
	Key []byte
	Doc value.Value // zero for key-only scans
}

// ScanOptions selects keys for Scan.
type ScanOptions struct {
	From, To       []byte // inclusive lower and exclusive upper bound
	HasFrom, HasTo bool
	Limit          int // -1 for no limit
	Reverse        bool
	KeysOnly       bool
}

// Scan returns the documents (or just the keys) in the key range, in
// ascending or descending key order, truncated to Limit.
func (db *DB) Scan(o ScanOptions) []Entry {
	if o.Limit == 0 {
		return nil
	}
	t := db.primary()
	c := t.seek(o.From)
	type ref struct {
		key []byte
		st  stored
	}
	var refs []ref
	for ; c.valid(); c.next() {
		k := c.key()
		if o.HasTo && bytes.Compare(k, o.To) >= 0 {
			break
		}
		var r ref
		r.key = k
		if !o.KeysOnly {
			dl, ov, in := rawLeafCell(c.img, c.cellIdx())
			r.st = stored{dl, ov, in}
		}
		refs = append(refs, r)
		if !o.Reverse && o.Limit > 0 && len(refs) >= o.Limit {
			break
		}
	}
	if o.Reverse {
		for i, j := 0, len(refs)-1; i < j; i, j = i+1, j-1 {
			refs[i], refs[j] = refs[j], refs[i]
		}
		if o.Limit >= 0 && len(refs) > o.Limit {
			refs = refs[:o.Limit]
		}
	}
	out := make([]Entry, len(refs))
	for i, r := range refs {
		out[i].Key = r.key
		if !o.KeysOnly {
			out[i].Doc = db.readDoc(r.st)
		}
	}
	return out
}

// Find evaluates pred against the store and returns the matching documents
// in ascending key order (at most limit of them; limit < 0 means no limit)
// together with the plan text: "scan" or "index <path>".
func (db *DB) Find(pred query.Node, limit int) ([]Entry, string) {
	slot, leaf := db.choosePlan(pred)
	if slot < 0 {
		return db.findScan(pred, limit), "scan"
	}
	plan := "index " + db.hdr.Dir[slot].Path
	if limit == 0 {
		return nil, plan
	}
	keys := db.candidates(slot, leaf)
	sort.Slice(keys, func(i, j int) bool { return bytes.Compare(keys[i], keys[j]) < 0 })
	var out []Entry
	for _, k := range keys {
		s, ok := db.findDoc(k)
		if !ok {
			continue
		}
		doc := db.readDoc(s)
		if query.Eval(pred, doc) {
			out = append(out, Entry{Key: k, Doc: doc})
			if limit >= 0 && len(out) >= limit {
				break
			}
		}
	}
	return out, plan
}

func (db *DB) findScan(pred query.Node, limit int) []Entry {
	if limit == 0 {
		return nil
	}
	var out []Entry
	c := db.primary().seek(nil)
	for ; c.valid(); c.next() {
		dl, ov, in := rawLeafCell(c.img, c.cellIdx())
		doc := db.readDoc(stored{dl, ov, in})
		if query.Eval(pred, doc) {
			out = append(out, Entry{Key: c.key(), Doc: doc})
			if limit >= 0 && len(out) >= limit {
				break
			}
		}
	}
	return out
}

// choosePlan picks the best usable index leaf of the predicate (§17.3). It
// returns the slot and the leaf, or slot -1 for a scan plan.
func (db *DB) choosePlan(pred query.Node) (slot int, best query.Cmp) {
	slot = -1
	for _, l := range query.Leaves(pred) {
		cmp, ok := l.(query.Cmp)
		if !ok || cmp.Op == query.Ne {
			continue
		}
		if cmp.Val.Kind == value.List || cmp.Val.Kind == value.Object {
			continue
		}
		text := cmp.Path.String()
		s := -1
		for i := range db.hdr.Dir {
			if db.hdr.Dir[i].Live && db.hdr.Dir[i].Path == text {
				s = i
				break
			}
		}
		if s < 0 {
			continue
		}
		if slot < 0 {
			slot, best = s, cmp
			continue
		}
		eqNew, eqBest := cmp.Op == query.Eq, best.Op == query.Eq
		switch {
		case eqNew && !eqBest:
			slot, best = s, cmp
		case eqNew == eqBest && text < best.Path.String():
			slot, best = s, cmp
		}
	}
	return slot, best
}

// candidates returns the primary keys of the index entries in the candidate
// range of the chosen leaf.
func (db *DB) candidates(slot int, leaf query.Cmp) [][]byte {
	v, _ := valueKey(nil, leaf.Val)
	t := db.indexTree(slot)
	var keys [][]byte
	add := func(k []byte) { keys = append(keys, k[valueKeyLen(k):]) }
	switch leaf.Op {
	case query.Eq:
		for c := t.seek(v); c.valid() && bytes.HasPrefix(c.key(), v); c.next() {
			add(c.key())
		}
	case query.Lt:
		for c := t.seek(nil); c.valid() && bytes.Compare(c.key(), v) < 0; c.next() {
			add(c.key())
		}
	case query.Le:
		for c := t.seek(nil); c.valid(); c.next() {
			k := c.key()
			if bytes.Compare(k, v) >= 0 && !bytes.HasPrefix(k, v) {
				break
			}
			add(k)
		}
	case query.Gt:
		for c := t.seek(v); c.valid(); c.next() {
			if bytes.HasPrefix(c.key(), v) {
				continue
			}
			add(c.key())
		}
	default: // Ge
		for c := t.seek(v); c.valid(); c.next() {
			add(c.key())
		}
	}
	return keys
}

// CreateIndex builds a secondary index on path and returns its entry count.
func (db *DB) CreateIndex(path value.Path) (entries int, err error) {
	text := path.String()
	free := -1
	for s := range db.hdr.Dir {
		d := &db.hdr.Dir[s]
		if d.Live && d.Path == text {
			return 0, kverr.IndexExists
		}
		if !d.Live && free < 0 {
			free = s
		}
	}
	if free < 0 {
		return 0, kverr.IndexLimit
	}
	var keys [][]byte
	for c := db.primary().seek(nil); c.valid(); c.next() {
		dl, ov, in := rawLeafCell(c.img, c.cellIdx())
		k, ok := entryKey(db.readDoc(stored{dl, ov, in}), path, c.key())
		if !ok {
			continue
		}
		if len(k) > MaxIndexKey {
			return 0, kverr.IndexKeyTooLong
		}
		keys = append(keys, k)
	}
	err = db.atomic(func() error {
		db.hdr.Dir[free] = IndexSlot{Live: true, Path: text}
		t := db.indexTree(free)
		for _, k := range keys {
			t.insert(cell{key: k})
			db.hdr.Dir[free].Entries++
		}
		return nil
	})
	return len(keys), err
}

// DropIndex removes the index on path and returns the number of pages freed.
func (db *DB) DropIndex(path value.Path) (pages int, err error) {
	text := path.String()
	slot := -1
	for s := range db.hdr.Dir {
		if d := &db.hdr.Dir[s]; d.Live && d.Path == text {
			slot = s
		}
	}
	if slot < 0 {
		return 0, kverr.IndexMissing
	}
	err = db.atomic(func() error {
		if root := db.hdr.Dir[slot].Root; root != 0 {
			pages = db.indexTree(slot).freeAll(root)
		}
		db.hdr.Dir[slot] = IndexSlot{}
		return nil
	})
	return pages, err
}
