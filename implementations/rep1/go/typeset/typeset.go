// Package typeset is the Codexa typesetting engine: it reads a Codexa
// document and an optional settings file, lays the document out on numbered
// pages (total-fit line breaking, Liang hyphenation, footnotes, floating
// figures, a table of contents and running headers) and renders a complete
// description of every placed item.
//
// The two entry points are Typeset, which works on in-memory file systems,
// and the sub-packages for callers that want to drive individual stages.
package typeset

import (
	"errors"
	"io/fs"

	"typeset/codexa"
	"typeset/diag"
	"typeset/hyphen"
	"typeset/layout"
	"typeset/metric"
	"typeset/render"
	"typeset/settings"
)

// Output holds the files a run produces, keyed by file name. For a valid
// document these are "layout.txt" and "report.txt"; for an invalid one just
// "error.txt".
type Output struct {
	Files map[string][]byte
	// Err is the input error that was reported in error.txt, or nil.
	Err *diag.Error
}

// Typeset processes the document in input (document.cdx and, optionally,
// settings.cfg), reading font metrics from data/faces/*.cfm and hyphenation
// patterns from data/hyphen/*.chp of the data file system. An input error is
// reported in the Output; the returned error is non-nil only when the data
// files cannot be read.
func Typeset(input, data fs.FS) (*Output, error) {
	invalid := func(e *diag.Error) (*Output, error) {
		return &Output{Files: map[string][]byte{"error.txt": render.ErrorFile(e)}, Err: e}, nil
	}

	docSrc, err := fs.ReadFile(input, "document.cdx")
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return invalid(&diag.Error{File: "-", Code: diag.MissingDocument})
		}
		return nil, err
	}

	set := settings.Defaults()
	if src, err := fs.ReadFile(input, "settings.cfg"); err == nil {
		var e *diag.Error
		if set, e = settings.Parse(src); e != nil {
			return invalid(e)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}

	doc, e := codexa.Parse(docSrc)
	if e != nil {
		return invalid(e)
	}

	faces, err := metric.LoadSet(data, "faces")
	if err != nil {
		return nil, err
	}
	f, err := data.Open("hyphen/" + set.HyphenPatterns + ".chp")
	if err != nil {
		return nil, err
	}
	defer f.Close()
	pats, err := hyphen.Parse(f)
	if err != nil {
		return nil, err
	}

	res := layout.Layout(layout.Input{Doc: doc, Settings: set, Faces: faces, Patterns: pats})
	return &Output{Files: map[string][]byte{
		"layout.txt": render.Layout(res, set),
		"report.txt": render.Report(res.Stats),
	}}, nil
}
