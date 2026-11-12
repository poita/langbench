package match

import (
	"bufio"
	"errors"
	"io"
	"strconv"
	"strings"

	"github.com/spiremark/cardgame/cards"
	"github.com/spiremark/cardgame/engine"
)

// Options customises Run.
type Options struct {
	// Load reads a card database. It defaults to cards.Load, which reads the
	// path from the filesystem relative to the working directory.
	Load func(path string) (*cards.Database, error)
}

// Run executes the match file read from in and writes the complete program
// output to out. It always produces the output the specification calls for,
// including FATAL lines; the returned error reports only I/O failures.
func Run(in io.Reader, out io.Writer, opt Options) error {
	data, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	load := opt.Load
	if load == nil {
		load = cards.Load
	}
	w := bufio.NewWriterSize(out, 1<<16)
	defer w.Flush()

	lines := splitLines(string(data))
	setup, err := ParseSetup(lines)
	if err != nil {
		_, _ = io.WriteString(w, "FATAL bad-setup\n")
		return nil
	}
	db, err := load(setup.CardsPath)
	if err != nil {
		_, _ = io.WriteString(w, "FATAL bad-database\n")
		return nil
	}
	g, err := engine.New(setup.Config, db, w)
	if errors.Is(err, engine.ErrUnknownCard) {
		_, _ = io.WriteString(w, "FATAL unknown-card\n")
		return nil
	} else if err != nil {
		return err
	}
	for i := setup.ScriptStart; i < len(lines); i++ {
		if isComment(lines[i]) {
			continue
		}
		execLine(g, db, setup.Trace, w, i+1, splitWords(lines[i]))
	}
	g.Finish()
	return nil
}

func splitLines(s string) []string {
	lines := strings.Split(s, "\n")
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	for i, l := range lines {
		lines[i] = strings.TrimSuffix(l, "\r")
	}
	return lines
}

func execLine(g *engine.Game, db *cards.Database, trace Trace, w io.Writer, lineNo int, words []string) {
	switch words[0] {
	case "DUMP", "LEGAL", "VAULT":
		if len(words) != 1 {
			errLine(w, lineNo, "bad-syntax")
			return
		}
		switch words[0] {
		case "DUMP":
			g.Dump(w)
		case "LEGAL":
			g.Legal(w)
		default:
			g.Vault(w)
		}
		return
	case "CARD":
		if len(words) != 2 {
			errLine(w, lineNo, "bad-syntax")
			return
		}
		if c, ok := db.Get(words[1]); ok {
			_, _ = io.WriteString(w, c.Block())
		} else {
			_, _ = io.WriteString(w, cards.UnknownBlock(words[1]))
		}
		return
	}
	act, ok := ParseAction(words)
	if !ok {
		errLine(w, lineNo, "bad-syntax")
		return
	}
	if err := g.Do(act); err != nil {
		var ae *engine.ActionError
		if errors.As(err, &ae) {
			errLine(w, lineNo, ae.Kind)
		}
		return
	}
	switch trace {
	case TraceLegal:
		g.Legal(w)
	case TraceState:
		g.Dump(w)
	}
}

func errLine(w io.Writer, lineNo int, kind string) {
	_, _ = io.WriteString(w, "ERR "+strconv.Itoa(lineNo)+" "+kind+"\n")
}
