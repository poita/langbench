package tessera

import (
	"encoding/binary"
	"strings"
)

// indexSlot is one entry of the index directory (SPEC §8).
type indexSlot struct {
	live    bool
	path    string // path text, segments joined by "."
	segs    []string
	root    uint32
	entries uint32
}

// header is the decoded content of page 1 (SPEC §7.2).
type header struct {
	pageCount     uint32
	freeHead      uint32
	freeCount     uint32
	primaryRoot   uint32
	primaryCount  uint32
	commitCounter uint64
	slots         [MaxIndexes]indexSlot
}

var magicDB = []byte("TESSERA1")

func (h *header) indexCount() int {
	n := 0
	for i := range h.slots {
		if h.slots[i].live {
			n++
		}
	}
	return n
}

// encode renders page 1. Every byte not covered by a field is zero.
func (h *header) encode() []byte {
	p := make([]byte, PageSize)
	copy(p, magicDB)
	binary.BigEndian.PutUint16(p[8:], 1)
	binary.BigEndian.PutUint16(p[10:], PageSize)
	binary.BigEndian.PutUint32(p[12:], h.pageCount)
	binary.BigEndian.PutUint32(p[16:], h.freeHead)
	binary.BigEndian.PutUint32(p[20:], h.freeCount)
	binary.BigEndian.PutUint32(p[24:], h.primaryRoot)
	binary.BigEndian.PutUint32(p[28:], h.primaryCount)
	binary.BigEndian.PutUint64(p[32:], h.commitCounter)
	binary.BigEndian.PutUint32(p[40:], uint32(h.indexCount()))
	for i := range h.slots {
		s := &h.slots[i]
		if !s.live {
			continue
		}
		o := 128 + 48*i
		p[o] = 1
		p[o+1] = byte(len(s.path))
		copy(p[o+2:o+32], s.path)
		binary.BigEndian.PutUint32(p[o+32:], s.root)
		binary.BigEndian.PutUint32(p[o+36:], s.entries)
	}
	return p
}

// decodeHeader parses page 1.
func decodeHeader(p []byte) header {
	var h header
	h.pageCount = binary.BigEndian.Uint32(p[12:])
	h.freeHead = binary.BigEndian.Uint32(p[16:])
	h.freeCount = binary.BigEndian.Uint32(p[20:])
	h.primaryRoot = binary.BigEndian.Uint32(p[24:])
	h.primaryCount = binary.BigEndian.Uint32(p[28:])
	h.commitCounter = binary.BigEndian.Uint64(p[32:])
	for i := range h.slots {
		o := 128 + 48*i
		if p[o] == 0 {
			continue
		}
		n := int(p[o+1])
		if n > 30 {
			n = 30
		}
		path := string(p[o+2 : o+2+n])
		h.slots[i] = indexSlot{
			live:    true,
			path:    path,
			segs:    strings.Split(path, "."),
			root:    binary.BigEndian.Uint32(p[o+32:]),
			entries: binary.BigEndian.Uint32(p[o+36:]),
		}
	}
	return h
}

// freshHeader returns the header of a freshly initialised database (SPEC §7.3).
func freshHeader() header { return header{pageCount: 1} }
