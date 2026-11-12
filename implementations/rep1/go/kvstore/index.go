package tessera

import (
	"bytes"

	"example.com/tessera/value"
)

// indexKey computes the index entry key for doc at the given path:
// vkey(value) followed by the raw document key. ok is false when the path is
// missing or resolves to a list or an object (SPEC §14.2).
func indexKey(segs []string, doc value.Value, key []byte) (ik []byte, ok bool) {
	v, found := doc.Lookup(segs)
	if !found {
		return nil, false
	}
	n := value.VKeyLen(v)
	if n < 0 {
		return nil, false
	}
	ik = make([]byte, 0, n+len(key))
	ik, _ = value.AppendVKey(ik, v)
	return append(ik, key...), true
}

// vkeyLen returns the length of the vkey that starts index key k.
func vkeyLen(k []byte) int {
	switch k[0] {
	case 0x30:
		return 9
	case 0x40:
		for i := 1; i+1 < len(k); {
			if k[i] != 0 {
				i++
			} else if k[i+1] == 0xFF {
				i += 2
			} else {
				return i + 2
			}
		}
		return len(k)
	}
	return 1
}

// docKeyOf recovers the document key from an index key.
func docKeyOf(k []byte) []byte { return k[vkeyLen(k):] }

// indexKeys holds, per directory slot, the entry key of one document.
type indexKeys [MaxIndexes]struct {
	key []byte
	ok  bool
}

// keysFor computes the entry key of doc for every live index.
func (db *DB) keysFor(doc value.Value, key []byte) (ks indexKeys) {
	for i := range db.hdr.slots {
		s := &db.hdr.slots[i]
		if s.live {
			ks[i].key, ks[i].ok = indexKey(s.segs, doc, key)
		}
	}
	return ks
}

// checkIndexKeys fails with index-key-too-long if any entry is too long.
func (ks *indexKeys) check() error {
	for i := range ks {
		if ks[i].ok && len(ks[i].key) > MaxIndexKey {
			return newErr(ErrIndexKeyTooLong)
		}
	}
	return nil
}

func (db *DB) indexInsert(slot int, k []byte) {
	db.indexTree(slot).insert(cell{key: k})
	db.hdr.slots[slot].entries++
}

func (db *DB) indexDelete(slot int, k []byte) {
	db.indexTree(slot).remove(k)
	db.hdr.slots[slot].entries--
}

// maintainIndexes applies §14.3 step 3 for a write whose old and new entry
// keys are given.
func (db *DB) maintainIndexes(old, new *indexKeys) {
	for i := range db.hdr.slots {
		if !db.hdr.slots[i].live {
			continue
		}
		o, w := &old[i], &new[i]
		switch {
		case !o.ok && !w.ok:
		case !o.ok && w.ok:
			db.indexInsert(i, w.key)
		case o.ok && !w.ok:
			db.indexDelete(i, o.key)
		case !bytes.Equal(o.key, w.key):
			db.indexDelete(i, o.key)
			db.indexInsert(i, w.key) // net entry count unchanged
		}
	}
}
