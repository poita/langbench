#!/usr/bin/env python3
"""OCaml oracle for the `typeinfer` problem (used by gen_tests.py only).

Translates a program into fully parenthesised OCaml with a prelude that
gives the built-ins and operators the types the spec assigns them, feeds it
to the `ocaml` toplevel, and returns one result per declaration: a
canonical type string or an error kind.

Two translation tricks make OCaml agree with the spec:

  * Every `let`-bound right-hand side (top-level or nested) becomes a thunk
    `fun () -> e` and each use of the name becomes `v_x ()`. A thunk is a
    syntactic value, so OCaml generalises it fully: this removes OCaml's
    value restriction, which the spec does not have, and instantiates the
    scheme afresh at every use exactly as the spec does. Bare expressions
    are thunked too and the leading `unit -> ` is stripped from their type.
  * Because everything is a thunk that is never called, the toplevel
    evaluates nothing, so it cannot loop or raise, and it keeps going after
    a type error, which mirrors the spec's continue-after-error rule.

The one remaining difference is error ordering inside a single declaration
that contains several errors: OCaml pushes expected types down into
sub-expressions, so it can report a different kind than the spec's
infer-then-unify order. Callers avoid such declarations.
"""
import importlib.util
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

spec = importlib.util.spec_from_file_location('ref', os.path.join(HERE, 'reference', 'main.py'))
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)

PRELUDE = """\
let ( = ) (a : int) (b : int) : bool = Stdlib.( = ) a b;;
let ( < ) (a : int) (b : int) : bool = Stdlib.( < ) a b;;
let ( > ) (a : int) (b : int) : bool = Stdlib.( > ) a b;;
let ( <= ) (a : int) (b : int) : bool = Stdlib.( <= ) a b;;
let ( >= ) (a : int) (b : int) : bool = Stdlib.( >= ) a b;;
let v_not (b : bool) : bool = not b;;
let v_fst = fst;;
let v_snd = snd;;
let v_hd = List.hd;;
let v_tl = List.tl;;
let v_null (l : 'a list) : bool = (match l with [] -> true | _ -> false);;
let v_map = List.map;;
let v_fold = List.fold_left;;
let v_length = List.length;;
"""

BUILTINS = ('not', 'fst', 'snd', 'hd', 'tl', 'null', 'map', 'fold', 'length')


def emit(node, thunks):
    """Fully parenthesised OCaml text for an expression AST. `thunks` is the
    set of names in scope that are bound to thunks (let-bound names)."""
    k = node[0]
    if k == 'int':
        return '0'
    if k == 'bool':
        return 'true'
    if k == 'unit':
        return '()'
    if k == 'var':
        return '(v_%s ())' % node[1] if node[1] in thunks else 'v_' + node[1]
    if k == 'fun':
        inner = thunks - set(node[1])
        return '(fun %s -> %s)' % (' '.join('v_' + p for p in node[1]), emit(node[2], inner))
    if k == 'app':
        return '(%s %s)' % (emit(node[1], thunks), emit(node[2], thunks))
    if k == 'let':
        return '(let v_%s = fun () -> %s in %s)' % (node[1], emit(node[2], thunks), emit(node[3], thunks | {node[1]}))
    if k == 'letrec':
        inner = thunks - {node[1]}
        return '(let rec v_%s = %s in %s)' % (node[1], emit(node[2], inner), emit(node[3], inner))
    if k == 'if':
        return '(if %s then %s else %s)' % tuple(emit(x, thunks) for x in node[1:])
    if k == 'tuple':
        return '(' + ', '.join(emit(x, thunks) for x in node[1]) + ')'
    if k == 'list':
        return '[' + '; '.join(emit(x, thunks) for x in node[1]) + ']'
    if k == 'cons':
        return '(%s :: %s)' % (emit(node[1], thunks), emit(node[2], thunks))
    if k == 'binop':
        return '(%s %s %s)' % (emit(node[2], thunks), node[1], emit(node[3], thunks))
    raise AssertionError(k)


def parse_program(src):
    parser = ref.Parser(ref.tokenize(src))
    decls = []
    while parser.peek()[0] != 'eof':
        decls.append(parser.declaration())
    return decls


def translate(decls):
    """One toplevel phrase per declaration. Each binds a unique `_dN`; a
    `let` or `let rec` additionally binds the user-visible name."""
    thunks = set()
    lines = []
    for i, d in enumerate(decls):
        if d[0] == 'expr':
            lines.append('let _d%d = fun () -> %s;;' % (i, emit(d[1], thunks)))
        elif d[0] == 'let':
            lines.append('let _d%d = fun () -> %s let v_%s = _d%d;;' % (i, emit(d[2], thunks), d[1], i))
            thunks.add(d[1])
        else:
            inner = thunks - {d[1]}
            lines.append('let _d%d = fun () -> let rec v_%s = %s in v_%s let v_%s = _d%d;;'
                         % (i, d[1], emit(d[2], inner), d[1], d[1], i))
            thunks.add(d[1])
    return lines


VAR_RE = re.compile(r"'[A-Za-z_][A-Za-z0-9_]*")


def canon_type(s):
    """Collapses whitespace and renames type variables in order of first
    appearance to the spec's 'a, 'b, ... scheme."""
    s = ' '.join(s.split())
    s = s.replace('( ', '(').replace(' )', ')')
    names = {}

    def rn(m):
        v = m.group(0)
        if v not in names:
            names[v] = ref.var_name(len(names))
        return names[v]

    return VAR_RE.sub(rn, s)


def classify(msg):
    if 'occurs inside' in msg:
        return 'occurs'
    if 'Unbound value' in msg:
        return 'unbound'
    known = ('expected', 'is not a function', 'too many arguments',
             'should not be', 'has type', 'no constructor', 'expects')
    if any(k in msg for k in known):
        return 'unify'
    raise RuntimeError('unrecognised ocaml error:\n' + msg)


VAL_RE = re.compile(r'^val (_d(\d+)|\S+) :')


def run_ocaml(src):
    """Returns a list with one entry per declaration: ('ok', canonical type)
    or ('error', kind)."""
    decls = parse_program(src)
    lines = translate(decls)
    p = subprocess.run(['ocaml', '-noinit', '-noprompt', '-no-version'],
                       input=PRELUDE + '\n'.join(lines) + '\n',
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError('ocaml failed:\n' + p.stderr + p.stdout)
    # The toplevel prints, in phrase order, either `val _dN : type = <fun>`
    # (possibly wrapped over several lines, followed by the alias's val) or a
    # located error. Errors are attributed to the declarations whose `val`
    # lines are missing between the ones that were printed.
    items = []  # ('val', index, text) or ('err', message)
    out = p.stdout.splitlines()
    i = 0
    while i < len(out):
        line = out[i]
        m = VAL_RE.match(line)
        if m:
            text = line
            i += 1
            while i < len(out) and out[i][:1] == ' ':
                text += ' ' + out[i].strip()
                i += 1
            if m.group(2) is not None:
                items.append(('val', int(m.group(2)), text))
            continue
        if line.startswith('Error'):
            text = line
            i += 1
            while i < len(out) and out[i][:1] == ' ':
                text += ' ' + out[i].strip()
                i += 1
            items.append(('err', text))
            continue
        i += 1
    results = [None] * len(decls)
    cur = 0
    pending = []
    for item in items:
        if item[0] == 'err':
            pending.append(item[1])
            continue
        _, idx, text = item
        if idx < cur or len(pending) != idx - cur:
            raise RuntimeError('cannot align ocaml output at declaration %d (%d pending errors, cur %d)' % (idx, len(pending), cur))
        for j, msg in enumerate(pending):
            results[cur + j] = ('error', classify(msg))
        pending = []
        ty = text.split(' : ', 1)[1]
        ty = ty[:ty.rindex(' = ')]
        if not ty.startswith('unit -> '):
            raise RuntimeError('unexpected type for declaration %d: %s' % (idx, ty))
        results[idx] = ('ok', canon_type(ty[len('unit -> '):]))
        cur = idx + 1
    if len(pending) != len(decls) - cur:
        raise RuntimeError('cannot align trailing ocaml errors (%d pending, %d declarations left)' % (len(pending), len(decls) - cur))
    for j, msg in enumerate(pending):
        results[cur + j] = ('error', classify(msg))
    return results


def spec_results(src):
    """Runs the reference and returns results in the same shape as run_ocaml."""
    out = []
    ref.run(src, out.append)
    return parse_output(''.join(out))


def parse_output(text):
    res = []
    for line in text.splitlines():
        if line.startswith('error: '):
            res.append(('error', line[7:]))
        else:
            res.append(('ok', line.split(' : ', 1)[1]))
    return res


if __name__ == '__main__':
    src = sys.stdin.read()
    for a, b in zip(spec_results(src), run_ocaml(src)):
        print(('ok ' if a == b else 'MISMATCH ') + str(a) + ' ' + str(b))
