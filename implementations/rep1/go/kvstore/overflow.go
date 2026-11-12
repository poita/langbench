package tessera

import "encoding/binary"

// writeOverflow stores rest (the document bytes beyond the inline part) in a
// new chain of overflow pages, allocated in chain order, and returns the first
// page (SPEC §9).
func (db *DB) writeOverflow(rest []byte) uint32 {
	count := (len(rest) + OvfPayload - 1) / OvfPayload
	pages := make([]uint32, count)
	for i := range pages {
		pages[i] = db.allocPage()
	}
	for i, p := range pages {
		chunk := rest[i*OvfPayload:]
		if len(chunk) > OvfPayload {
			chunk = chunk[:OvfPayload]
		}
		img := make([]byte, PageSize)
		img[0] = typeOverflow
		if i+1 < count {
			binary.BigEndian.PutUint32(img[4:], pages[i+1])
		}
		binary.BigEndian.PutUint16(img[8:], uint16(len(chunk)))
		copy(img[12:], chunk)
		db.writePage(p, img)
	}
	return pages[0]
}

// makeCell builds the primary leaf cell for a document, allocating its
// overflow chain before anything else happens.
func (db *DB) makeCell(key, ser []byte) cell {
	c := cell{key: key, docLen: uint32(len(ser))}
	if len(ser) <= MaxInline {
		c.inline = ser
		return c
	}
	c.inline = ser[:MaxInline:MaxInline]
	c.overflow = db.writeOverflow(ser[MaxInline:])
	return c
}

// readDoc returns the serialised document of a primary leaf cell.
func (db *DB) readDoc(c *cell) []byte {
	if c.overflow == 0 {
		return c.inline
	}
	out := make([]byte, 0, c.docLen)
	out = append(out, c.inline...)
	for p := c.overflow; p != 0; {
		img := db.readPage(p)
		n := int(binary.BigEndian.Uint16(img[8:]))
		out = append(out, img[12:12+n]...)
		p = binary.BigEndian.Uint32(img[4:])
	}
	return out
}

// freeOverflow frees a chain in chain order (SPEC §9).
func (db *DB) freeOverflow(first uint32) {
	var pages []uint32
	for p := first; p != 0; p = binary.BigEndian.Uint32(db.readPage(p)[4:]) {
		pages = append(pages, p)
	}
	for _, p := range pages {
		db.freePage(p)
	}
}
