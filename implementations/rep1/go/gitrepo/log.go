package gitrepo

import "container/heap"

type walkItem struct {
	id   ID
	c    *Commit
	date uint64
	seq  int
}

// walkHeap orders by committer date descending, then insertion order.
type walkHeap []walkItem

func (h walkHeap) Len() int { return len(h) }
func (h walkHeap) Less(i, j int) bool {
	if h[i].date != h[j].date {
		return h[i].date > h[j].date
	}
	return h[i].seq < h[j].seq
}
func (h walkHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h *walkHeap) Push(x any)   { *h = append(*h, x.(walkItem)) }
func (h *walkHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}

// Walk visits commits reachable from start in git's default order: reverse
// chronological by committer date, ties broken in favour of the commit
// discovered first. At most limit commits are visited (limit < 0 means no
// limit). start must be a commit id; a missing or damaged commit among those
// the walk needs to load is an error, and no further commits are visited
// after the error.
func (r *Repository) Walk(start ID, limit int, visit func(id ID, c *Commit)) error {
	c, err := r.Commit(start)
	if err != nil {
		return err
	}
	h := &walkHeap{}
	seen := map[ID]struct{}{start: {}}
	seq := 0
	heap.Push(h, walkItem{start, c, c.CommitterTime, seq})
	seq++
	for emitted := 0; h.Len() > 0 && (limit < 0 || emitted < limit); emitted++ {
		it := heap.Pop(h).(walkItem)
		visit(it.id, it.c)
		for _, p := range it.c.Parents {
			if _, ok := seen[p]; ok {
				continue
			}
			seen[p] = struct{}{}
			pc, err := r.Commit(p)
			if err != nil {
				return err
			}
			heap.Push(h, walkItem{p, pc, pc.CommitterTime, seq})
			seq++
		}
	}
	return nil
}
