"""The KBL evaluator: scopes, statements, rules, and step construction."""
from kiln_err import KilnError, vtype, need_type, as_strlist
from kiln_vfs import is_ws_path, is_ident, is_generated
from kbl_lex import lex_file
from kbl_parse import FileParser
from kbl_ast import (EInt, EBool, EStr, EVar, EList, ECall, EIndex, EUnary,
                     EBinary, SLet, SSet, SInclude, SAbort, SDefault, SPhony,
                     SUse, SWhen, SEach, SRule, SStep)
from kbl_funcs import (BUILTINS, call_builtin, cmp_vals, val_eq,
                       render_scalar, wrap64)

MAX_RULE_DEPTH = 64

# Parsing is a pure function of a file's path and bytes, so results are
# shared across the builds of one session.
_PARSE_CACHE = {}

# name -> (argument types, min file inputs, max file inputs or None,
#          depfile required, default cost)
COMMANDS = {
    b"write": ((b"str",), 0, 0, False, 1),
    b"copy": ((), 1, 1, False, 1),
    b"concat": ((), 1, None, False, 2),
    b"upper": ((), 1, 1, False, 2),
    b"lower": ((), 1, 1, False, 2),
    b"grep": ((b"str",), 1, 1, False, 3),
    b"replace": ((b"str", b"str"), 1, 1, False, 3),
    b"sort_lines": ((), 1, 1, False, 4),
    b"reverse_lines": ((), 1, 1, False, 2),
    b"dedup": ((), 1, 1, False, 3),
    b"number": ((), 1, 1, False, 2),
    b"indent": ((b"int",), 1, 1, False, 2),
    b"wrap": ((b"str", b"str"), 1, 1, False, 1),
    b"count_lines": ((), 1, None, False, 2),
    b"hash": ((), 1, None, False, 3),
    b"preprocess": ((), 1, 1, True, 6),
}

_ESCAPE_MAP = {
    0x5C: b"\\\\",
    0x22: b'\\"',
    0x0A: b"\\n",
    0x09: b"\\t",
    0x0D: b"\\r",
}


def escape_cmd_string(s):
    out = bytearray()
    for c in s:
        e = _ESCAPE_MAP.get(c)
        if e is not None:
            out += e
        elif c < 0x20 or c == 0x7F:
            out += b"\\x%02x" % c
        else:
            out.append(c)
    return bytes(out)


def render_command(name, args):
    """The canonical command string used by the log, the state file and
    change detection."""
    pieces = []
    for v in args:
        if vtype(v) == b"int":
            pieces.append(b"%d" % v)
        else:
            pieces.append(b'"' + escape_cmd_string(v) + b'"')
    return name + b"(" + b", ".join(pieces) + b")"


class Scope(object):
    __slots__ = ("vars", "parent")

    def __init__(self, parent=None):
        self.vars = {}
        self.parent = parent

    def lookup(self, name):
        s = self
        while s is not None:
            if name in s.vars:
                return s.vars[name]
            s = s.parent
        raise KilnError(b"E_UNKNOWN_VAR", name)

    def define(self, name, value):
        if name in self.vars:
            raise KilnError(b"E_REDEFINE", name)
        self.vars[name] = value

    def assign(self, name, value):
        s = self
        while s is not None:
            if name in s.vars:
                s.vars[name] = value
                return
            s = s.parent
        raise KilnError(b"E_SET_UNDEFINED", name)


class Step(object):
    __slots__ = ("serial", "outs", "ins", "afters", "cost", "depfile",
                 "cmd_name", "cmd_args", "cmd_string")

    def __init__(self, serial):
        self.serial = serial
        self.outs = []
        self.ins = []
        self.afters = []
        self.cost = None
        self.depfile = None
        self.cmd_name = None
        self.cmd_args = None
        self.cmd_string = None

    @property
    def primary(self):
        return self.outs[0]

    @property
    def full_outs(self):
        if self.depfile is None:
            return list(self.outs)
        return list(self.outs) + [self.depfile]

    @property
    def file_inputs(self):
        return [p for p in self.ins if not p.startswith(b"@")]


def check_target_ref(ref):
    """Validate the shape of an ``in`` / ``after`` / phony-dependency entry."""
    if ref.startswith(b"@"):
        if not is_ident(ref[1:]):
            raise KilnError(b"E_BAD_PATH", ref)
    elif not is_ws_path(ref):
        raise KilnError(b"E_BAD_PATH", ref)


class Build(object):
    """Everything one build's evaluation produces."""

    def __init__(self, workspace):
        self.workspace = workspace
        self.steps = []
        self.phony = {}
        self.phony_order = []
        self.rules = {}
        self.defaults = []
        self.include_stack = []
        self.rule_depth = 0
        self._parsed = {}

    # ---- expressions ----

    def eval(self, node, scope):
        cls = node.__class__
        if cls is EInt:
            return node.value
        if cls is EBool:
            return node.value
        if cls is EVar:
            return scope.lookup(node.name)
        if cls is EStr:
            out = bytearray()
            for kind, payload in node.parts:
                if kind == "lit":
                    out += payload
                else:
                    out += render_scalar(self.eval(payload, scope))
            return bytes(out)
        if cls is EList:
            return [self.eval(e, scope) for e in node.items]
        if cls is ECall:
            # The callee is checked before any argument is evaluated.
            if node.name not in BUILTINS:
                raise KilnError(b"E_UNKNOWN_FUNC", node.name)
            args = [self.eval(a, scope) for a in node.args]
            return call_builtin(self, node.name, args)
        if cls is EIndex:
            return self.eval_index(node, scope)
        if cls is EUnary:
            return self.eval_unary(node, scope)
        if cls is EBinary:
            return self.eval_binary(node, scope)
        raise AssertionError("unknown node")

    def eval_index(self, node, scope):
        target = self.eval(node.target, scope)
        idx = self.eval(node.index, scope)
        need_type(idx, b"int", b"index")
        need_type(target, b"str|list", b"index target")
        n = len(target)
        i = idx
        if i < 0:
            i = n + i
        if i < 0 or i >= n:
            raise KilnError(b"E_ARG", b"fn index: out of range")
        if vtype(target) == b"str":
            return target[i:i + 1]
        return target[i]

    def eval_unary(self, node, scope):
        v = self.eval(node.operand, scope)
        if node.op == b"!":
            need_type(v, b"bool", b"operator !")
            return not v
        need_type(v, b"int", b"operator -")
        return wrap64(-v)

    def eval_binary(self, node, scope):
        op = node.op
        if op == b"||":
            left = self.eval(node.left, scope)
            need_type(left, b"bool", b"operator ||")
            if left:
                return True
            right = self.eval(node.right, scope)
            need_type(right, b"bool", b"operator ||")
            return right
        if op == b"&&":
            left = self.eval(node.left, scope)
            need_type(left, b"bool", b"operator &&")
            if not left:
                return False
            right = self.eval(node.right, scope)
            need_type(right, b"bool", b"operator &&")
            return right
        left = self.eval(node.left, scope)
        right = self.eval(node.right, scope)
        if op == b"==":
            return val_eq(left, right)
        if op == b"!=":
            return not val_eq(left, right)
        if op in (b"<", b"<=", b">", b">="):
            c = cmp_vals(left, right)
            if op == b"<":
                return c < 0
            if op == b"<=":
                return c <= 0
            if op == b">":
                return c > 0
            return c >= 0
        site = b"operator " + op
        if op == b"++":
            need_type(left, b"list", site)
            need_type(right, b"list", site)
            return list(left) + list(right)
        if op == b"~":
            need_type(left, b"str", site)
            need_type(right, b"str", site)
            return left + right
        need_type(left, b"int", site)
        need_type(right, b"int", site)
        if op == b"+":
            return wrap64(left + right)
        if op == b"-":
            return wrap64(left - right)
        if op == b"*":
            return wrap64(left * right)
        if right == 0:
            raise KilnError(b"E_DIV_ZERO")
        q = abs(left) // abs(right)
        if (left < 0) != (right < 0):
            q = -q
        if op == b"/":
            return wrap64(q)
        return wrap64(left - q * right)

    # ---- statements ----

    def parse_build_file(self, path):
        got = self._parsed.get(path)
        if got is not None:
            return got
        src = self.workspace.read(path)
        key = (path, src)
        stmts = _PARSE_CACHE.get(key)
        if stmts is None:
            lines = lex_file(src, path)
            stmts = FileParser(lines, path).parse_file()
            _PARSE_CACHE[key] = stmts
        self._parsed[path] = stmts
        return stmts

    def run_file(self, path, scope):
        self.include_stack.append(path)
        self.exec_block(self.parse_build_file(path), scope)
        self.include_stack.pop()

    def exec_block(self, stmts, scope):
        for st in stmts:
            self.exec_stmt(st, scope)

    def exec_stmt(self, st, scope):
        cls = st.__class__
        if cls is SLet:
            scope.define(st.name, self.eval(st.expr, scope))
        elif cls is SSet:
            scope.assign(st.name, self.eval(st.expr, scope))
        elif cls is SInclude:
            self.do_include(st, scope)
        elif cls is SAbort:
            msg = self.eval(st.expr, scope)
            need_type(msg, b"str", b"abort message")
            raise KilnError(b"E_ABORT", msg)
        elif cls is SDefault:
            v = self.eval(st.expr, scope)
            self.defaults.extend(as_strlist(v, b"default"))
        elif cls is SPhony:
            self.do_phony(st, scope)
        elif cls is SWhen:
            self.do_when(st, scope)
        elif cls is SEach:
            self.do_each(st, scope)
        elif cls is SRule:
            if st.name in self.rules:
                raise KilnError(b"E_REDEFINE", st.name)
            self.rules[st.name] = (st.params, st.body, scope)
        elif cls is SUse:
            self.do_use(st, scope)
        elif cls is SStep:
            self.do_step(st, scope)
        else:
            raise AssertionError("unknown statement")

    def do_include(self, st, scope):
        path = self.eval(st.expr, scope)
        need_type(path, b"str", b"include path")
        if not is_ws_path(path):
            raise KilnError(b"E_BAD_PATH", path)
        if not self.workspace.exists(path):
            raise KilnError(b"E_INCLUDE_MISSING", path)
        if path in self.include_stack:
            raise KilnError(b"E_INCLUDE_CYCLE", path)
        self.run_file(path, scope)

    def do_phony(self, st, scope):
        v = self.eval(st.expr, scope)
        deps = as_strlist(v, b"phony " + st.name)
        for d in deps:
            check_target_ref(d)
        if st.name in self.phony:
            raise KilnError(b"E_DUP_PHONY", st.name)
        self.phony[st.name] = deps
        self.phony_order.append(st.name)

    def do_when(self, st, scope):
        for cond, body in st.branches:
            if cond is None:
                self.exec_block(body, Scope(scope))
                return
            v = self.eval(cond, scope)
            need_type(v, b"bool", b"when condition")
            if v:
                self.exec_block(body, Scope(scope))
                return

    def do_each(self, st, scope):
        subject = self.eval(st.expr, scope)
        need_type(subject, b"list", b"each subject")
        for i, elem in enumerate(subject):
            child = Scope(scope)
            if st.ivar is not None:
                child.vars[st.ivar] = i
            child.vars[st.var] = elem
            self.exec_block(st.body, child)

    def do_use(self, st, scope):
        entry = self.rules.get(st.name)
        if entry is None:
            raise KilnError(b"E_UNKNOWN_RULE", st.name)
        if self.rule_depth + 1 > MAX_RULE_DEPTH:
            raise KilnError(b"E_RULE_RECURSION", st.name)
        params, body, defscope = entry
        evaluated = [(kw, self.eval(e, scope)) for kw, e in st.args]
        child = Scope(defscope)
        positional = [v for kw, v in evaluated if kw is None]
        if len(positional) > len(params):
            raise KilnError(
                b"E_ARITY",
                b"rule " + st.name + b": expected " + b"%d" % len(params) +
                b", got " + b"%d" % len(positional))
        pnames = [p[0] for p in params]
        for i, v in enumerate(positional):
            child.vars[pnames[i]] = v
        for kw, v in evaluated:
            if kw is None:
                continue
            if kw not in pnames:
                raise KilnError(
                    b"E_ARG", b"rule " + st.name + b": unknown argument " + kw)
            if kw in child.vars:
                raise KilnError(
                    b"E_ARG",
                    b"rule " + st.name + b": duplicate argument " + kw)
            child.vars[kw] = v
        for pname, default in params:
            if pname in child.vars:
                continue
            if default is None:
                raise KilnError(
                    b"E_ARG",
                    b"rule " + st.name + b": missing argument " + pname)
            child.vars[pname] = self.eval(default, child)
        self.rule_depth += 1
        try:
            self.exec_block(body, child)
        finally:
            self.rule_depth -= 1

    # ---- steps ----

    def do_step(self, st, scope):
        step = Step(len(self.steps))
        for field in st.fields:
            key = field[0]
            if key == b"cmd":
                if step.cmd_name is not None:
                    raise KilnError(b"E_STEP_FIELD", b"duplicate cmd")
                name = field[1]
                spec = COMMANDS.get(name)
                if spec is None:
                    raise KilnError(b"E_UNKNOWN_CMD", name)
                args = [self.eval(a, scope) for a in field[2]]
                argtypes = spec[0]
                if len(args) != len(argtypes):
                    raise KilnError(
                        b"E_ARITY",
                        b"cmd " + name + b": expected " + b"%d" % len(argtypes)
                        + b", got " + b"%d" % len(args))
                for i, want in enumerate(argtypes):
                    need_type(args[i], want,
                              b"cmd " + name + b" argument " + b"%d" % (i + 1))
                step.cmd_name = name
                step.cmd_args = args
                continue
            if key == b"cost":
                if step.cost is not None:
                    raise KilnError(b"E_STEP_FIELD", b"duplicate cost")
                v = self.eval(field[1], scope)
                need_type(v, b"int", b"field cost")
                if v < 0:
                    raise KilnError(b"E_ARG", b"field cost: negative")
                step.cost = v
                continue
            if key == b"depfile":
                if step.depfile is not None:
                    raise KilnError(b"E_STEP_FIELD", b"duplicate depfile")
                v = self.eval(field[1], scope)
                need_type(v, b"str", b"field depfile")
                step.depfile = v
                continue
            v = self.eval(field[1], scope)
            items = as_strlist(v, b"field " + key)
            if key == b"out":
                step.outs.extend(items)
            elif key == b"in":
                step.ins.extend(items)
            else:
                step.afters.extend(items)
        self.validate_step(step)
        self.steps.append(step)

    def validate_step(self, step):
        if step.cmd_name is None:
            raise KilnError(b"E_STEP_FIELD", b"missing cmd")
        if not step.outs:
            raise KilnError(b"E_STEP_FIELD", b"missing out")
        for p in step.full_outs:
            if not is_ws_path(p):
                raise KilnError(b"E_BAD_PATH", p)
            if not is_generated(p):
                raise KilnError(b"E_OUTPUT_PATH", p)
        for ref in step.ins:
            check_target_ref(ref)
        for ref in step.afters:
            check_target_ref(ref)
        name = step.cmd_name
        spec = COMMANDS[name]
        lo, hi = spec[1], spec[2]
        nin = len(step.file_inputs)
        if nin < lo or (hi is not None and nin > hi):
            want = b"%d-N" % lo if hi is None else b"%d-%d" % (lo, hi)
            raise KilnError(
                b"E_CMD_SHAPE",
                name + b": expected inputs " + want + b", got " + b"%d" % nin)
        if len(step.outs) != 1:
            raise KilnError(
                b"E_CMD_SHAPE",
                name + b": expected outputs 1, got " + b"%d" % len(step.outs))
        if spec[3] and step.depfile is None:
            raise KilnError(b"E_CMD_SHAPE", name + b": depfile required")
        if not spec[3] and step.depfile is not None:
            raise KilnError(b"E_CMD_SHAPE", name + b": depfile not allowed")
        if name == b"replace" and not step.cmd_args[0]:
            raise KilnError(b"E_ARG", b"cmd replace: empty pattern")
        if name == b"indent" and step.cmd_args[0] < 0:
            raise KilnError(b"E_ARG", b"cmd indent: negative")
        if step.cost is None:
            step.cost = spec[4]
        step.cmd_string = render_command(name, step.cmd_args)


def evaluate_build(workspace):
    """Run phase 2: evaluate ``main.kiln`` into a ``Build``."""
    build = Build(workspace)
    build.run_file(b"main.kiln", Scope(None))
    return build
