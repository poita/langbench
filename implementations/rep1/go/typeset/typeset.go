// Package typeset is a typesetting engine for the Codexa markup language:
// total-fit line breaking, Liang hyphenation, footnotes, floating figures,
// a generated table of contents and running headers, producing an exact
// integer description of every placed item.
//
// The usual entry points are LoadResources (read the font and hyphenation
// data once) and Typeset (run one document through the pipeline).
package typeset

import (
	"fmt"

	"typeset/diag"
	"typeset/hyphen"
	"typeset/layout"
	"typeset/markup"
	"typeset/metrics"
	"typeset/render"
	"typeset/settings"
)

// Resources are the font metrics and hyphenation pattern sets, which never
// change between documents.
type Resources struct {
	Faces    *metrics.Set
	Patterns map[string]*hyphen.Set
}

// LoadResources reads data/faces/*.cfm and data/hyphen/*.chp below dataDir.
func LoadResources(dataDir string) (*Resources, error) {
	faces, err := metrics.LoadDir(dataDir)
	if err != nil {
		return nil, fmt.Errorf("loading faces: %w", err)
	}
	r := &Resources{Faces: faces, Patterns: map[string]*hyphen.Set{}}
	for _, name := range []string{"english", "minimal"} {
		s, err := hyphen.LoadDir(dataDir, name)
		if err != nil {
			return nil, fmt.Errorf("loading patterns %s: %w", name, err)
		}
		r.Patterns[name] = s
	}
	return r, nil
}

// Input is one document to typeset. Document is document.cdx and Settings is
// settings.cfg; the Has flags say whether each file exists (an existing but
// empty file is valid).
type Input struct {
	Document    []byte
	HasDocument bool
	Settings    []byte
	HasSettings bool
}

// Result is the outcome of typesetting one document: either an input error,
// or the text of layout.txt and report.txt.
type Result struct {
	Err    *diag.Error
	Layout string
	Report string
}

// ErrorText returns the content of error.txt for a failed Result.
func (r *Result) ErrorText() string { return r.Err.Error() + "\n" }

// Typeset runs the whole pipeline on one input.
func Typeset(in Input, res *Resources) *Result {
	if !in.HasDocument {
		return &Result{Err: diag.New("-", 0, 0, "missing-document")}
	}
	var cfg *settings.Settings
	var derr *diag.Error
	if in.HasSettings {
		cfg, derr = settings.Parse(in.Settings)
	} else {
		cfg, derr = settings.Parse(nil)
	}
	if derr != nil {
		return &Result{Err: derr}
	}
	doc, derr := markup.Parse(in.Document)
	if derr != nil {
		return &Result{Err: derr}
	}
	laid := layout.Layout(doc, cfg, res.Faces, res.Patterns[cfg.HyphenPatterns])
	geometry := [6]int64{cfg.PageWidth, cfg.PageHeight, cfg.BodyX(), cfg.BodyY(), cfg.BodyWidth(), cfg.BodyHeight()}
	return &Result{Layout: render.Layout(laid, geometry), Report: render.Report(laid)}
}
