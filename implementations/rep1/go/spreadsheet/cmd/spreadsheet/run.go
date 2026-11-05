package main

import (
	"strings"

	"example.com/spreadsheet"
)

// Run executes the commands in input against a fresh sheet and returns the
// text produced by get and dump commands. Malformed lines are ignored.
func Run(input string) []byte {
	sheet := spreadsheet.New()
	out := make([]byte, 0, 1<<16)
	for len(input) > 0 {
		var line string
		if i := strings.IndexByte(input, '\n'); i >= 0 {
			line, input = input[:i], input[i+1:]
		} else {
			line, input = input, ""
		}
		line = strings.TrimSuffix(line, "\r")
		cmd, rest, _ := strings.Cut(line, " ")
		switch cmd {
		case "set":
			name, content, _ := strings.Cut(rest, " ")
			_ = sheet.Set(name, content)
		case "clear":
			_ = sheet.Clear(rest)
		case "get":
			v, err := sheet.Get(rest)
			if err != nil {
				continue
			}
			out = v.AppendTo(out)
			out = append(out, '\n')
		case "dump":
			out = sheet.AppendDump(out)
		}
	}
	return out
}
