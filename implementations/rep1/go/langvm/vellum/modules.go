package vellum

import (
	"strings"

	"langvm/diag"
	"langvm/lexer"
)

// Module is one module of the input stream: its name and body (the lines
// after its header, joined with LF).
type Module struct {
	Name string
	Body []rune
}

// isModuleName reports whether s is a valid module name: an identifier of at
// most 200 characters that is not a keyword and not a lone underscore.
func isModuleName(s string) bool {
	if s == "" || len(s) > 200 || s == "_" || lexer.IsKeyword(s) {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		letter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
		if i == 0 && !letter {
			return false
		}
		if !letter && !(c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

// SplitModules implements pass 0 (SPEC section 2).
func SplitModules(src []byte) ([]Module, *diag.Error) {
	text := string(src)
	var lines []string
	if text != "" {
		lines = strings.Split(text, "\n")
		if lines[len(lines)-1] == "" {
			lines = lines[:len(lines)-1]
		}
	}
	for i, l := range lines {
		lines[i] = strings.TrimSuffix(l, "\r")
	}
	const prefix = "@module "
	isHeader := func(l string) bool {
		return strings.HasPrefix(l, prefix) && isModuleName(l[len(prefix):])
	}
	if len(lines) == 0 || !isHeader(lines[0]) {
		return nil, diag.New(diag.BadModule, diag.Pos{Line: 1, Col: 1})
	}
	for i, l := range lines {
		if strings.HasPrefix(l, "@") && !isHeader(l) {
			return nil, diag.New(diag.BadModule, diag.Pos{Line: i + 1, Col: 1})
		}
	}
	var mods []Module
	seen := map[string]bool{}
	for i := 0; i < len(lines); {
		name := lines[i][len(prefix):]
		if seen[name] {
			return nil, diag.New(diag.DupModule, diag.Pos{Line: i + 1, Col: 1})
		}
		seen[name] = true
		j := i + 1
		for j < len(lines) && !strings.HasPrefix(lines[j], "@") {
			j++
		}
		mods = append(mods, Module{Name: name, Body: []rune(strings.Join(lines[i+1:j], "\n"))})
		i = j
	}
	return mods, nil
}
