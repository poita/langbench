package engine

import "encoding/binary"

// writeOverflow stores data (the document bytes beyond the inline part) in a
// chain of overflow pages and returns the first page. The pages are
// allocated in chain order, first chunk first.
func (p *pager) writeOverflow(data []byte) uint32 {
	nPages := (len(data) + OvfPayload - 1) / OvfPayload
	pages := make([]uint32, nPages)
	for i := range pages {
		pages[i] = p.alloc()
	}
	for i, pg := range pages {
		chunk := data[i*OvfPayload:]
		if len(chunk) > OvfPayload {
			chunk = chunk[:OvfPayload]
		}
		img := make([]byte, PageSize)
		img[0] = typeOverflow
		if i+1 < nPages {
			binary.BigEndian.PutUint32(img[4:], pages[i+1])
		}
		binary.BigEndian.PutUint16(img[8:], uint16(len(chunk)))
		copy(img[12:], chunk)
		p.write(pg, img)
	}
	return pages[0]
}

// readOverflow appends the payloads of the chain starting at first to dst.
func (p *pager) readOverflow(dst []byte, first uint32) []byte {
	for pg := first; pg != 0; {
		img := p.read(pg)
		n := int(binary.BigEndian.Uint16(img[8:]))
		dst = append(dst, img[12:12+n]...)
		pg = binary.BigEndian.Uint32(img[4:])
	}
	return dst
}

// freeOverflow frees the chain starting at first, first page first.
func (p *pager) freeOverflow(first uint32) {
	var pages []uint32
	for pg := first; pg != 0; pg = binary.BigEndian.Uint32(p.read(pg)[4:]) {
		pages = append(pages, pg)
	}
	for _, pg := range pages {
		p.free(pg)
	}
}
