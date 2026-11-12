package tessera

import (
	"bytes"
	"strconv"

	"example.com/tessera/value"
)

// Result is the outcome of one command: a status text and payload lines, as
// printed in results.txt (SPEC §19) without the "[k] " prefix or indentation.
type Result struct {
	Status string
	Lines  [][]byte
}

func errResult(err error) Result {
	return Result{Status: "error " + string(KindOf(err))}
}

func renderEntry(e Entry, keysOnly bool) []byte {
	b := value.AppendQuoted(nil, string(e.Key))
	if keysOnly {
		return b
	}
	b = append(b, " = "...)
	return value.AppendRender(b, e.Doc)
}

// Exec parses and runs one line of the command language and returns its
// result. Failures are reported in the result, never as a panic.
func (db *DB) Exec(line string) Result {
	cmd, err := ParseCommand(line)
	if err != nil {
		return errResult(err)
	}
	return db.Run(cmd)
}

// Run executes a parsed command.
func (db *DB) Run(c *Command) Result {
	switch c.Kind {
	case CmdBegin:
		if err := db.Begin(); err != nil {
			return errResult(err)
		}
		return Result{Status: "ok begin"}
	case CmdCommit:
		info, err := db.Commit()
		if err != nil {
			return errResult(err)
		}
		return Result{Status: "ok commit " + strconv.FormatUint(info.TxnID, 10) + " frames " + strconv.Itoa(info.Frames)}
	case CmdRollback:
		if err := db.Rollback(); err != nil {
			return errResult(err)
		}
		return Result{Status: "ok rollback"}
	case CmdCheckpoint:
		n, err := db.Checkpoint()
		if err != nil {
			return errResult(err)
		}
		return Result{Status: "ok checkpoint pages " + strconv.Itoa(n)}
	case CmdPut:
		created, err := db.Put(c.Key, c.Value)
		if err != nil {
			return errResult(err)
		}
		if created {
			return Result{Status: "ok put created"}
		}
		return Result{Status: "ok put replaced"}
	case CmdGet:
		v, err := db.Get(c.Key)
		if err != nil {
			return errResult(err)
		}
		return Result{Status: "ok get value", Lines: [][]byte{value.AppendRender(nil, v)}}
	case CmdDelete:
		if err := db.Delete(c.Key); err != nil {
			return errResult(err)
		}
		return Result{Status: "ok delete removed"}
	case CmdUpdate:
		if err := db.Update(c.Key, c.Path, c.Value); err != nil {
			return errResult(err)
		}
		return Result{Status: "ok update updated"}
	case CmdUnset:
		if err := db.Unset(c.Key, c.Path); err != nil {
			return errResult(err)
		}
		return Result{Status: "ok unset updated"}
	case CmdScan:
		entries := db.Scan(c.Scan)
		r := Result{Status: "ok scan " + strconv.Itoa(len(entries))}
		for _, e := range entries {
			r.Lines = append(r.Lines, renderEntry(e, c.Scan.KeysOnly))
		}
		return r
	case CmdFind:
		limit := -1
		if c.HasLimit {
			limit = c.Limit
		}
		entries, plan := db.Find(c.Pred, limit)
		r := Result{Status: "ok find " + strconv.Itoa(len(entries)) + " plan " + plan}
		for _, e := range entries {
			r.Lines = append(r.Lines, renderEntry(e, false))
		}
		return r
	case CmdCreateIndex:
		text := pathText(c.Path)
		n, err := db.CreateIndex(text)
		if err != nil {
			return errResult(err)
		}
		return Result{Status: "ok create index " + text + " entries " + strconv.Itoa(n)}
	case CmdDropIndex:
		text := pathText(c.Path)
		n, err := db.DropIndex(text)
		if err != nil {
			return errResult(err)
		}
		return Result{Status: "ok drop index " + text + " pages " + strconv.Itoa(n)}
	case CmdIndexes:
		infos := db.Indexes()
		r := Result{Status: "ok indexes " + strconv.Itoa(len(infos))}
		for _, in := range infos {
			r.Lines = append(r.Lines, []byte(strconv.Itoa(in.Slot)+" "+in.Path+" root "+
				strconv.FormatUint(uint64(in.Root), 10)+" entries "+strconv.FormatUint(uint64(in.Entries), 10)))
		}
		return r
	case CmdStat:
		s := db.Stat()
		u := func(v uint64) string { return strconv.FormatUint(v, 10) }
		return Result{Status: "ok stat", Lines: [][]byte{
			[]byte("pages " + u(uint64(s.Pages))),
			[]byte("free " + u(uint64(s.Free))),
			[]byte("freehead " + u(uint64(s.FreeHead))),
			[]byte("docs " + u(uint64(s.Docs))),
			[]byte("root " + u(uint64(s.Root))),
			[]byte("height " + strconv.Itoa(s.Height)),
			[]byte("commits " + u(s.Commits)),
			[]byte("indexes " + strconv.Itoa(s.Indexes)),
			[]byte("wal " + strconv.Itoa(s.WALSize)),
		}}
	}
	return Result{Status: "error syntax"}
}

// Output is everything a script run leaves behind (SPEC §2.2).
type Output struct {
	Results     []byte // results.txt
	DatabaseTDB []byte // main.tdb
	LogTWAL     []byte // main.twal
}

// splitLines splits a command script into its lines: pieces separated by LF,
// where a trailing LF terminates the last line and an empty script has none.
func splitLines(script []byte) [][]byte {
	if len(script) == 0 {
		return nil
	}
	lines := bytes.Split(script, []byte{'\n'})
	if script[len(script)-1] == '\n' {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// RunScript opens a database from the given main file and log (either may be
// nil), runs every line of the script, rolls back a transaction left open and
// returns the results text together with the final file contents.
func RunScript(mainFile, logFile, script []byte) Output {
	db := Open(mainFile, logFile)
	var out bytes.Buffer
	for i, line := range splitLines(script) {
		r := db.Exec(string(line))
		out.WriteByte('[')
		out.WriteString(strconv.Itoa(i + 1))
		out.WriteString("] ")
		out.WriteString(r.Status)
		out.WriteByte('\n')
		for _, l := range r.Lines {
			out.WriteString("  ")
			out.Write(l)
			out.WriteByte('\n')
		}
	}
	if db.InTransaction() {
		_ = db.Rollback()
	}
	return Output{Results: out.Bytes(), DatabaseTDB: db.DatabaseFile(), LogTWAL: db.LogFile()}
}
