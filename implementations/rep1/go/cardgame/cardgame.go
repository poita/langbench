// Package cardgame runs Spiremark matches: it reads a match file, loads the
// card database it names, simulates the match and writes the event log.
//
// The lower-level building blocks live in sub-packages: sexpr (s-expression
// reader), rng (pseudo-random numbers), cards (card model and validator),
// match (match-file parser) and engine (the rules engine).
package cardgame

import (
	"errors"
	"io"

	"cardgame/cards"
	"cardgame/engine"
	"cardgame/match"
)

// Run reads a match file from in and writes the resulting log to out. Fatal
// setup problems are reported as a single "FATAL <kind>" line, exactly like
// every other outcome; Run returns an error only for I/O failures.
func Run(in io.Reader, out io.Writer) error {
	data, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	return RunString(string(data), out)
}

// RunString is Run for a match file held in memory.
func RunString(src string, out io.Writer) error {
	fatal := func(kind string) error {
		_, err := io.WriteString(out, "FATAL "+kind+"\n")
		return err
	}
	file, err := match.ParseFile(src)
	if err != nil {
		return fatal("bad-setup")
	}
	db, err := cards.Load(file.Setup.CardsPath)
	if err != nil {
		return fatal("bad-database")
	}
	g, err := engine.New(db, file.Setup)
	if errors.Is(err, engine.ErrUnknownCard) {
		return fatal("unknown-card")
	}
	if err != nil {
		return err
	}
	for _, ln := range file.Script {
		if match.IsComment(ln.Text) {
			continue
		}
		cmd, perr := match.ParseCommand(ln.Text)
		if perr != nil {
			g.Reject(ln.No, "bad-syntax")
			continue
		}
		g.Exec(cmd, ln.No)
	}
	g.Finish()
	_, err = g.WriteTo(out)
	return err
}
