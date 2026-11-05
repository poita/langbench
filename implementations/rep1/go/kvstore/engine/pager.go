package engine

import (
	"encoding/binary"
	"sort"
)

var zeroPage = make([]byte, PageSize)

// pager is the three-layer page store: the open transaction's dirty set over
// the log overlay over the main file. It also owns the decoded header and the
// free list.
type pager struct {
	main    []byte            // main database file image
	overlay map[uint32][]byte // newest committed image of each logged page
	dirty   map[uint32][]byte // pages written by the open transaction
	hdr     Header            // current header (includes uncommitted changes)
	saved   Header            // header at the start of the open transaction
	wal     []byte            // log image
	inTxn   bool
}

// read returns the current image of page n. The returned slice must not be
// modified.
func (p *pager) read(n uint32) []byte {
	if img, ok := p.dirty[n]; ok {
		return img
	}
	if img, ok := p.overlay[n]; ok {
		return img
	}
	if int(n) <= len(p.main)/PageSize {
		return p.main[(n-1)*PageSize : n*PageSize]
	}
	return zeroPage
}

// write stores a full page image in the dirty set. The pager takes ownership
// of img.
func (p *pager) write(n uint32, img []byte) { p.dirty[n] = img }

// alloc allocates a page: the head of the free list, or a new page at the end
// of the file.
func (p *pager) alloc() uint32 {
	if p.hdr.FreeHead != 0 {
		n := p.hdr.FreeHead
		p.hdr.FreeHead = binary.BigEndian.Uint32(p.read(n)[4:])
		p.hdr.FreeCount--
		return n
	}
	p.hdr.PageCount++
	return p.hdr.PageCount
}

// free pushes page n onto the free list.
func (p *pager) free(n uint32) {
	img := make([]byte, PageSize)
	binary.BigEndian.PutUint32(img[4:], p.hdr.FreeHead)
	p.write(n, img)
	p.hdr.FreeHead = n
	p.hdr.FreeCount++
}

func (p *pager) begin() {
	p.saved = p.hdr
	p.inTxn = true
}

func (p *pager) rollback() {
	p.hdr = p.saved
	p.dirty = map[uint32][]byte{}
	p.inTxn = false
}

// commit makes the open transaction durable in the log and returns its id and
// the number of page frames written. It checkpoints when the log reaches
// WALLimit.
func (p *pager) commit() (txn uint64, frames int) {
	p.hdr.Commits++
	txn = p.hdr.Commits
	p.dirty[1] = p.hdr.encode()
	pages := make([]uint32, 0, len(p.dirty))
	for n := range p.dirty {
		pages = append(pages, n)
	}
	sort.Slice(pages, func(i, j int) bool { return pages[i] < pages[j] })
	for _, n := range pages {
		p.wal = appendRecord(p.wal, 1, txn, n, p.dirty[n])
		p.overlay[n] = p.dirty[n]
	}
	p.wal = appendRecord(p.wal, 2, txn, uint32(len(pages)), nil)
	p.dirty = map[uint32][]byte{}
	p.inTxn = false
	if len(p.wal) >= WALLimit {
		p.checkpoint()
	}
	return txn, len(pages)
}
