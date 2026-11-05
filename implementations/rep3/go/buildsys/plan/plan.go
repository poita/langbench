// Package plan holds the result of evaluating build files: the list of build
// steps, the phony targets and the default target list. It also validates a
// step when its block closes.
package plan

import (
	"strings"

	"buildsys/cmds"
	"buildsys/diag"
	"buildsys/vfs"
)

// Step is one build step.
type Step struct {
	// Serial is the creation order of the step within its build (0-based).
	Serial int
	// Outs are the declared outputs; Outs[0] is the primary output.
	Outs []string
	// Depfile is the depfile path, or "" when the step has none.
	Depfile string
	// Ins are the declared inputs exactly as written (file paths and @phony
	// references); Afters are the order-only dependencies.
	Ins    []string
	Afters []string
	// FileInputs are the declared inputs that are not phony references.
	FileInputs []string
	// FullOuts are the declared outputs followed by the depfile, if any.
	FullOuts []string
	// Cost is the number of time units the command occupies a worker.
	Cost int64
	// Cmd is the command, and CmdString its canonical rendering.
	Cmd       *cmds.Command
	CmdString string
}

// Primary returns the step's primary output path.
func (s *Step) Primary() string { return s.Outs[0] }

// Phony is a phony target. Its dependencies are ordering-only.
type Phony struct {
	Name string
	Deps []string
}

// Build is the evaluated form of a workspace's build files.
type Build struct {
	Steps    []*Step
	Phonies  []*Phony
	Defaults []string

	phonyIdx map[string]int
}

// NewBuild returns an empty Build.
func NewBuild() *Build { return &Build{phonyIdx: make(map[string]int)} }

// HasPhony reports whether a phony target with the given name (no '@') exists.
func (b *Build) HasPhony(name string) bool { _, ok := b.phonyIdx[name]; return ok }

// PhonyIndex returns the declaration index of the named phony target.
func (b *Build) PhonyIndex(name string) (int, bool) { i, ok := b.phonyIdx[name]; return i, ok }

// AddPhony declares a phony target, failing with E_DUP_PHONY if the name is
// taken.
func (b *Build) AddPhony(name string, deps []string) error {
	if b.HasPhony(name) {
		return diag.New(diag.DupPhony, "%s", name)
	}
	b.phonyIdx[name] = len(b.Phonies)
	b.Phonies = append(b.Phonies, &Phony{Name: name, Deps: deps})
	return nil
}

// AddDefault appends target names to the default list.
func (b *Build) AddDefault(names ...string) { b.Defaults = append(b.Defaults, names...) }

// IsPhonyName reports whether s is identifier-shaped: [A-Za-z_][A-Za-z0-9_]*.
func IsPhonyName(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || i > 0 && c >= '0' && c <= '9' {
			continue
		}
		return false
	}
	return true
}

// CheckRef validates the shape of a reference written in `in`, `after` or a
// phony dependency list: "@name" with an identifier-shaped name, or a
// workspace path. It returns E_BAD_PATH otherwise.
func CheckRef(s string) error {
	if strings.HasPrefix(s, "@") {
		if IsPhonyName(s[1:]) {
			return nil
		}
		return diag.New(diag.BadPath, "%s", s)
	}
	if vfs.IsWorkspacePath(s) {
		return nil
	}
	return diag.New(diag.BadPath, "%s", s)
}

// Draft accumulates the fields of a `step` block until it is closed.
type Draft struct {
	Outs       []string
	Ins        []string
	Afters     []string
	Cost       int64
	HasCost    bool
	Depfile    string
	HasDepfile bool
	Cmd        *cmds.Command
}

// Finish validates the draft in the order the specification gives and, if all
// checks pass, returns the finished step (without a serial number).
func (d *Draft) Finish() (*Step, error) {
	if d.Cmd == nil {
		return nil, diag.New(diag.StepField, "missing cmd")
	}
	if len(d.Outs) == 0 {
		return nil, diag.New(diag.StepField, "missing out")
	}
	check := func(p string) error {
		if !vfs.IsWorkspacePath(p) {
			return diag.New(diag.BadPath, "%s", p)
		}
		if !vfs.IsGenerated(p) {
			return diag.New(diag.OutputPath, "%s", p)
		}
		return nil
	}
	for _, p := range d.Outs {
		if err := check(p); err != nil {
			return nil, err
		}
	}
	if d.HasDepfile {
		if err := check(d.Depfile); err != nil {
			return nil, err
		}
	}
	for _, list := range [][]string{d.Ins, d.Afters} {
		for _, r := range list {
			if err := CheckRef(r); err != nil {
				return nil, err
			}
		}
	}
	var fileIns []string
	for _, r := range d.Ins {
		if !strings.HasPrefix(r, "@") {
			fileIns = append(fileIns, r)
		}
	}
	if err := d.Cmd.Spec.CheckShape(len(fileIns), len(d.Outs), d.HasDepfile); err != nil {
		return nil, err
	}
	if err := d.Cmd.CheckArgs(); err != nil {
		return nil, err
	}
	s := &Step{
		Outs:       d.Outs,
		Ins:        d.Ins,
		Afters:     d.Afters,
		FileInputs: fileIns,
		Cmd:        d.Cmd,
		CmdString:  d.Cmd.String(),
		Cost:       d.Cmd.Spec.DefaultCost,
	}
	if d.HasCost {
		s.Cost = d.Cost
	}
	s.FullOuts = append(s.FullOuts, d.Outs...)
	if d.HasDepfile {
		s.Depfile = d.Depfile
		s.FullOuts = append(s.FullOuts, d.Depfile)
	}
	return s, nil
}

// AddStep assigns the next serial number to s and appends it to the build.
func (b *Build) AddStep(s *Step) {
	s.Serial = len(b.Steps)
	b.Steps = append(b.Steps, s)
}
