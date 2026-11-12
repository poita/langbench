package kbl

import (
	"strconv"
	"strings"

	"buildsys/cmds"
	"buildsys/kerr"
	"buildsys/plan"
	"buildsys/vfs"
)

// execStep builds, validates and records one step.
func (it *interp) execStep(s *stepStmt, sc *scope) error {
	st := &plan.Step{}
	var (
		haveCost, haveDepfile, haveCmd bool
		cost                           int64
	)
	for _, f := range s.fields {
		switch f.kind {
		case "out", "in", "after":
			v, err := it.eval(f.e, sc)
			if err != nil {
				return err
			}
			names, err := strList(v, "field "+f.kind)
			if err != nil {
				return err
			}
			switch f.kind {
			case "out":
				st.Outputs = append(st.Outputs, names...)
			case "in":
				st.Inputs = append(st.Inputs, names...)
			default:
				st.After = append(st.After, names...)
			}
		case "cost":
			if haveCost {
				return kerr.New(kerr.StepField, "duplicate cost")
			}
			haveCost = true
			v, err := it.eval(f.e, sc)
			if err != nil {
				return err
			}
			if v.K != KInt {
				return kerr.NewType("field cost", "int", v.K.String())
			}
			if v.I < 0 {
				return kerr.New(kerr.Arg, "field cost: negative")
			}
			cost = v.I
		case "depfile":
			if haveDepfile {
				return kerr.New(kerr.StepField, "duplicate depfile")
			}
			haveDepfile = true
			v, err := it.eval(f.e, sc)
			if err != nil {
				return err
			}
			if v.K != KStr {
				return kerr.NewType("field depfile", "str", v.K.String())
			}
			st.Depfile = v.S
		case "cmd":
			if haveCmd {
				return kerr.New(kerr.StepField, "duplicate cmd")
			}
			haveCmd = true
			spec, ok := cmds.Lookup(f.cmd)
			if !ok {
				return kerr.New(kerr.UnknownCmd, "%s", f.cmd)
			}
			vals := make([]Value, len(f.args))
			for i, a := range f.args {
				v, err := it.eval(a, sc)
				if err != nil {
					return err
				}
				vals[i] = v
			}
			if len(vals) != len(spec.Params) {
				return kerr.New(kerr.Arity, "cmd %s: expected %d, got %d", spec.Name, len(spec.Params), len(vals))
			}
			args := make([]cmds.Arg, len(vals))
			for i, v := range vals {
				want := spec.Params[i]
				wantKind := KStr
				if want == cmds.Int {
					wantKind = KInt
				}
				if v.K != wantKind {
					return kerr.NewType("cmd "+spec.Name+" argument "+strconv.Itoa(i+1), want.String(), v.K.String())
				}
				if want == cmds.Int {
					args[i] = cmds.IntArg(v.I)
				} else {
					args[i] = cmds.StrArg(v.S)
				}
			}
			st.Spec, st.Args = spec, args
		}
	}
	hasDepfile := haveDepfile
	if err := validateStep(st, haveCmd, hasDepfile); err != nil {
		return err
	}
	st.Command = cmds.Render(st.Spec.Name, st.Args)
	st.Cost = st.Spec.DefaultCost
	if haveCost {
		st.Cost = int(cost)
	}
	for _, in := range st.Inputs {
		if !strings.HasPrefix(in, "@") {
			st.FileInputs = append(st.FileInputs, in)
		}
	}
	st.Serial = len(it.plan.Steps)
	it.plan.Steps = append(it.plan.Steps, st)
	return nil
}

// validateStep performs the checks made when a step block closes.
func validateStep(st *plan.Step, haveCmd, haveDepfile bool) error {
	if !haveCmd {
		return kerr.New(kerr.StepField, "missing cmd")
	}
	if len(st.Outputs) == 0 {
		return kerr.New(kerr.StepField, "missing out")
	}
	outs := st.Outputs
	if haveDepfile {
		outs = append(append([]string(nil), outs...), st.Depfile)
	}
	for _, p := range outs {
		if !vfs.ValidPath(p) {
			return kerr.New(kerr.BadPath, "%s", p)
		}
		if !vfs.IsGenerated(p) {
			return kerr.New(kerr.OutputPath, "%s", p)
		}
	}
	for _, list := range [][]string{st.Inputs, st.After} {
		for _, r := range list {
			if err := checkRef(r); err != nil {
				return err
			}
		}
	}
	fileInputs := 0
	for _, in := range st.Inputs {
		if !strings.HasPrefix(in, "@") {
			fileInputs++
		}
	}
	if err := st.Spec.CheckShape(fileInputs, len(st.Outputs), haveDepfile); err != nil {
		return err
	}
	return st.Spec.CheckArgs(st.Args)
}
