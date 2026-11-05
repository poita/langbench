// Package export writes the dump of a whole mailbox into an output
// directory: summary.txt, messages/NNNN.txt and parts/NNNN/PPP.bin.
package export

import (
	"os"
	"path/filepath"
	"strconv"

	"mimedump/mailbox"
	"mimedump/message"
	"mimedump/render"
)

// Write processes the messages of mb one at a time and writes the results
// under outDir, which is created if it does not exist.
func Write(mb *mailbox.Mailbox, outDir string) error {
	if err := os.MkdirAll(filepath.Join(outDir, "messages"), 0o755); err != nil {
		return err
	}
	summary := []byte("messages " + strconv.Itoa(mb.Len()) + "\n")
	for i := 0; i < mb.Len(); i++ {
		num := i + 1
		raw, err := mb.Message(i)
		if err != nil {
			return err
		}
		m := message.Parse(raw)
		id := mb.SourceID(i)

		name := filepath.Join(outDir, "messages", render.Number(num)+".txt")
		if err := os.WriteFile(name, render.Message(num, id, m), 0o644); err != nil {
			return err
		}
		if len(m.Attachments) > 0 {
			if err := os.MkdirAll(filepath.Join(outDir, "parts", render.Number(num)), 0o755); err != nil {
				return err
			}
			for _, p := range m.Attachments {
				path := filepath.Join(outDir, filepath.FromSlash(render.AttachmentPath(num, p.Index)))
				if err := os.WriteFile(path, p.Content, 0o644); err != nil {
					return err
				}
			}
		}
		summary = append(summary, render.SummaryLine(num, id, len(raw), m)...)
		summary = append(summary, '\n')
	}
	return os.WriteFile(filepath.Join(outDir, "summary.txt"), summary, 0o644)
}
