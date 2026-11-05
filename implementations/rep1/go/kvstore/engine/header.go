package engine

import "encoding/binary"

// IndexSlot is one entry of the index directory in the header page.
type IndexSlot struct {
	Live    bool
	Path    string // path text
	Root    uint32 // root page of the index tree, 0 when empty
	Entries uint32 // number of entries in the index
}

// Header is the decoded header page (page 1).
type Header struct {
	PageCount    uint32
	FreeHead     uint32
	FreeCount    uint32
	PrimaryRoot  uint32
	PrimaryCount uint32
	Commits      uint64
	Dir          [MaxIndexes]IndexSlot
}

// IndexCount returns the number of live index slots.
func (h *Header) IndexCount() int {
	n := 0
	for i := range h.Dir {
		if h.Dir[i].Live {
			n++
		}
	}
	return n
}

var headerMagic = []byte("TESSERA1")

func decodeHeader(img []byte) Header {
	var h Header
	be := binary.BigEndian
	h.PageCount = be.Uint32(img[12:])
	h.FreeHead = be.Uint32(img[16:])
	h.FreeCount = be.Uint32(img[20:])
	h.PrimaryRoot = be.Uint32(img[24:])
	h.PrimaryCount = be.Uint32(img[28:])
	h.Commits = be.Uint64(img[32:])
	for s := range h.Dir {
		b := img[128+48*s : 128+48*s+48]
		if b[0] != 1 {
			continue
		}
		n := int(b[1])
		if n > 30 {
			n = 30
		}
		h.Dir[s] = IndexSlot{
			Live:    true,
			Path:    string(b[2 : 2+n]),
			Root:    be.Uint32(b[32:]),
			Entries: be.Uint32(b[36:]),
		}
	}
	return h
}

// encode returns the canonical 1024-byte header page.
func (h *Header) encode() []byte {
	img := make([]byte, PageSize)
	be := binary.BigEndian
	copy(img, headerMagic)
	be.PutUint16(img[8:], 1)
	be.PutUint16(img[10:], PageSize)
	be.PutUint32(img[12:], h.PageCount)
	be.PutUint32(img[16:], h.FreeHead)
	be.PutUint32(img[20:], h.FreeCount)
	be.PutUint32(img[24:], h.PrimaryRoot)
	be.PutUint32(img[28:], h.PrimaryCount)
	be.PutUint64(img[32:], h.Commits)
	be.PutUint32(img[40:], uint32(h.IndexCount()))
	for s := range h.Dir {
		d := &h.Dir[s]
		if !d.Live {
			continue
		}
		b := img[128+48*s : 128+48*s+48]
		b[0] = 1
		b[1] = byte(len(d.Path))
		copy(b[2:32], d.Path)
		be.PutUint32(b[32:], d.Root)
		be.PutUint32(b[36:], d.Entries)
	}
	return img
}

// freshHeaderImage returns page 1 of a freshly initialised database.
func freshHeaderImage() []byte {
	h := Header{PageCount: 1}
	return h.encode()
}
