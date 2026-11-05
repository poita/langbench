"""AST node classes.

Every node carries the position of its first token.  The checker adds
annotations (`ty` and form-specific resolution fields) that the bytecode
compiler reads.
"""


class Node:
    __slots__ = ('line', 'col', 'ty')

    def pos(self):
        return (self.line, self.col)


def _mk(name, fields, base=Node):
    """Build a node class with `fields` after the base's slots."""
    ns = {'__slots__': tuple(fields)}

    def __init__(self, line, col, *args):
        self.line = line
        self.col = col
        self.ty = None
        for f, a in zip(fields, args):
            setattr(self, f, a)
    ns['__init__'] = __init__
    ns['__repr__'] = lambda self: '%s(%s)' % (
        name, ', '.join(repr(getattr(self, f, None)) for f in fields))
    return type(name, (base,), ns)


# --- types -----------------------------------------------------------------

TAList = _mk('TAList', ['elem'])
TAMap = _mk('TAMap', ['key', 'val'])
TATuple = _mk('TATuple', ['parts'])
TAFn = _mk('TAFn', ['params', 'ret'])
# mod may be None; nline/ncol locate the name token itself.
TAPath = _mk('TAPath', ['mod', 'name', 'args', 'nline', 'ncol'])

# --- expressions -----------------------------------------------------------

EInt = _mk('EInt', ['val'])
EFloat = _mk('EFloat', ['val'])
EStr = _mk('EStr', ['val'])
EChar = _mk('EChar', ['val'])
EBool = _mk('EBool', ['val'])
ESelf = _mk('ESelf', ['res'])
# res is the checker's resolution record.
EPath = _mk('EPath', ['mod', 'name', 'nline', 'ncol', 'res'])
EUnary = _mk('EUnary', ['op', 'operand', 'kind'])
EBinary = _mk('EBinary', ['op', 'left', 'right', 'kind'])
ECall = _mk('ECall', ['callee', 'args', 'res'])
EMethod = _mk('EMethod', ['recv', 'name', 'args', 'nline', 'ncol', 'res'])
EIndex = _mk('EIndex', ['obj', 'index', 'kind'])
EField = _mk('EField', ['obj', 'name', 'nline', 'ncol', 'idx'])
EStructLit = _mk('EStructLit', ['path', 'fields', 'decl', 'perm'])
EList = _mk('EList', ['elems'])
EMap = _mk('EMap', ['entries'])
ETuple = _mk('ETuple', ['parts'])
ELambda = _mk('ELambda', ['params', 'ret', 'body', 'info'])
EIf = _mk('EIf', ['cond', 'then', 'els'])
EMatch = _mk('EMatch', ['scrut', 'arms'])
EBlock = _mk('EBlock', ['stmts', 'tail', 'scope'])

# --- statements ------------------------------------------------------------

SLet = _mk('SLet', ['pat', 'ann', 'expr'])
SVar = _mk('SVar', ['name', 'ann', 'expr', 'bind'])
SAssign = _mk('SAssign', ['target', 'expr', 'bind'])
SExpr = _mk('SExpr', ['expr'])
SWhile = _mk('SWhile', ['cond', 'body'])
SForSeq = _mk('SForSeq', ['pat', 'seq', 'body', 'kind'])
SForRange = _mk('SForRange', ['pat', 'lo', 'hi', 'body'])
SBreak = _mk('SBreak', [])
SContinue = _mk('SContinue', [])
SReturn = _mk('SReturn', ['expr'])

# --- patterns --------------------------------------------------------------

PWild = _mk('PWild', [])
PInt = _mk('PInt', ['val'])
PFloat = _mk('PFloat', ['val'])
PStr = _mk('PStr', ['val'])
PChar = _mk('PChar', ['val'])
PBool = _mk('PBool', ['val'])
PBind = _mk('PBind', ['name', 'bind'])
# `bind`, when set by the checker, means this bare name is a binding and not a
# zero-payload variant pattern.
PVariant = _mk('PVariant', ['mod', 'name', 'subs', 'vd', 'bind'])
PStruct = _mk('PStruct', ['mod', 'name', 'fields', 'rest', 'decl', 'order'])
PTuple = _mk('PTuple', ['parts'])
PList = _mk('PList', ['elems', 'rest', 'restname', 'restbind'])


class Arm:
    __slots__ = ('pat', 'guard', 'body', 'block', 'line', 'col', 'scope')

    def __init__(self, pat, guard, body, block, line, col):
        self.pat = pat
        self.guard = guard
        self.body = body
        self.block = block
        self.line = line
        self.col = col
        self.scope = None


class Param:
    __slots__ = ('name', 'ann', 'line', 'col', 'ty', 'bind')

    def __init__(self, name, ann, line, col):
        self.name = name
        self.ann = ann
        self.line = line
        self.col = col
        self.ty = None
        self.bind = None


class GenParam:
    __slots__ = ('name', 'bounds', 'line', 'col', 'tp')

    def __init__(self, name, bounds, line, col):
        self.name = name
        self.bounds = bounds
        self.line = line
        self.col = col
        self.tp = None


class TraitRef:
    __slots__ = ('mod', 'name', 'line', 'col', 'nline', 'ncol', 'decl')

    def __init__(self, mod, name, line, col, nline, ncol):
        self.mod = mod
        self.name = name
        self.line = line
        self.col = col
        self.nline = nline
        self.ncol = ncol
        self.decl = None


# --- items -----------------------------------------------------------------

class Item:
    __slots__ = ('line', 'col')


class IUse(Item):
    __slots__ = ('name', 'nline', 'ncol', 'alias', 'aline', 'acol')


class IFn(Item):
    __slots__ = ('pub', 'name', 'nline', 'ncol', 'generics', 'params', 'ret',
                 'body', 'sig', 'info')


class IStruct(Item):
    __slots__ = ('pub', 'name', 'nline', 'ncol', 'generics', 'fields', 'decl')


class IEnum(Item):
    __slots__ = ('pub', 'name', 'nline', 'ncol', 'generics', 'variants', 'decl')


class ITrait(Item):
    __slots__ = ('pub', 'name', 'nline', 'ncol', 'methods', 'decl')


class IImpl(Item):
    __slots__ = ('generics', 'traitref', 'head', 'methods', 'impl')


class MethodDef:
    """A trait method signature (with an optional default body) or an impl
    method."""
    __slots__ = ('name', 'nline', 'ncol', 'line', 'col', 'params', 'ret',
                 'body', 'sig', 'info', 'index')

    def __init__(self, name, nline, ncol, line, col, params, ret, body):
        self.name = name
        self.nline = nline
        self.ncol = ncol
        self.line = line
        self.col = col
        self.params = params
        self.ret = ret
        self.body = body
        self.sig = None
        self.info = None
        self.index = -1


class FieldDef:
    __slots__ = ('name', 'ann', 'line', 'col')

    def __init__(self, name, ann, line, col):
        self.name = name
        self.ann = ann
        self.line = line
        self.col = col


class VariantDef:
    __slots__ = ('name', 'payloads', 'line', 'col')

    def __init__(self, name, payloads, line, col):
        self.name = name
        self.payloads = payloads
        self.line = line
        self.col = col
