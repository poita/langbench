"""The usefulness function of section 12.4, used for both exhaustiveness and
reachability."""

from vtypes import TPrim, TList, TTuple, TNamed, prune, subst
from vast import (PWild, PInt, PStr, PChar, PBool, PBind, PVariant, PStruct,
                  PTuple, PList)
from items import StructDecl

WILD = PWild(0, 0)


def is_wild(p):
    k = type(p)
    if k is PWild:
        return True
    if k is PBind:
        return True
    if k is PVariant and p.bind is not None:
        return True
    return False


def ctor_of(p):
    """The constructor a pattern names, or None for a wildcard."""
    k = type(p)
    if is_wild(p):
        return None
    if k is PInt:
        return ('lit', p.val)
    if k is PStr:
        return ('lit', ('s', p.val))
    if k is PChar:
        return ('lit', ('c', p.val))
    if k is PBool:
        return ('bool', p.val)
    if k is PTuple:
        return ('tuple', len(p.parts))
    if k is PStruct:
        return ('struct', p.decl)
    if k is PVariant:
        return ('variant', p.vd)
    raise AssertionError('no constructor for %r' % (p,))


def ctor_arity(c, t1):
    tag = c[0]
    if tag == 'lit' or tag == 'bool':
        return 0
    if tag == 'tuple':
        return c[1]
    if tag == 'struct':
        return len(c[1].ftypes)
    if tag == 'variant':
        return len(c[1].payloads)
    return 0


def sub_types(c, t1):
    """The column types a specialisation introduces."""
    tag = c[0]
    t1 = prune(t1)
    if tag == 'tuple':
        return list(t1.parts)
    if tag == 'struct':
        decl = c[1]
        mapping = dict(zip(decl.params, t1.args))
        return [subst(ft, mapping) for ft in decl.ftypes]
    if tag == 'variant':
        vd = c[1]
        mapping = dict(zip(vd.enum.params, t1.args))
        return [subst(pt, mapping) for pt in vd.payloads]
    return []


def finite_ctors(t1):
    """The full constructor set of a type, or None when it is infinite."""
    t1 = prune(t1)
    k = type(t1)
    if k is TPrim:
        if t1.name == 'Bool':
            return [('bool', False), ('bool', True)]
        if t1.name == 'Unit':
            return [('unit',)]
        return None
    if k is TTuple:
        return [('tuple', len(t1.parts))]
    if k is TNamed:
        if isinstance(t1.decl, StructDecl):
            return [('struct', t1.decl)]
        return [('variant', v) for v in t1.decl.variants]
    return None


def sub_patterns(p, c, k):
    """The k sub-patterns a row contributes, or None when the row is dropped."""
    if is_wild(p):
        return [WILD] * k
    if ctor_of(p) != c:
        return None
    t = type(p)
    if t is PTuple:
        return list(p.parts)
    if t is PStruct:
        decl = p.decl
        out = [WILD] * len(decl.ftypes)
        for idx, sub in p.order:
            out[idx] = sub if sub is not None else WILD
        return out
    if t is PVariant:
        return list(p.subs or ())
    return []


def specialize(matrix, c, k):
    out = []
    for row in matrix:
        subs = sub_patterns(row[0], c, k)
        if subs is None:
            continue
        out.append(subs + row[1:])
    return out


def default_matrix(matrix):
    return [row[1:] for row in matrix if is_wild(row[0])]


def admits(p, k):
    if is_wild(p):
        return True
    n = len(p.elems)
    if p.rest:
        return k >= n
    return k == n


def spec_list(row, k):
    p = row[0]
    if is_wild(p):
        return [WILD] * k + row[1:]
    n = len(p.elems)
    if p.rest:
        if n > k:
            return None
        return list(p.elems) + [WILD] * (k - n) + row[1:]
    if n != k:
        return None
    return list(p.elems) + row[1:]


def useful(matrix, q, coltypes):
    if not q:
        return len(matrix) == 0
    t1 = prune(coltypes[0])
    if type(t1) is TList:
        lmax = 0
        for row in matrix:
            p = row[0]
            if type(p) is PList and len(p.elems) > lmax:
                lmax = len(p.elems)
        if type(q[0]) is PList and len(q[0].elems) > lmax:
            lmax = len(q[0].elems)
        rest = coltypes[1:]
        for k in range(0, lmax + 2):
            if not admits(q[0], k):
                continue
            m2 = []
            for row in matrix:
                r = spec_list(row, k)
                if r is not None:
                    m2.append(r)
            q2 = spec_list(q, k)
            if useful(m2, q2, [t1.elem] * k + rest):
                return True
        return False
    c = ctor_of(q[0])
    if c is not None:
        k = ctor_arity(c, t1)
        ct = sub_types(c, t1) + coltypes[1:]
        return useful(specialize(matrix, c, k), sub_patterns(q[0], c, k)
                      + q[1:], ct)
    used = []
    for row in matrix:
        rc = ctor_of(row[0])
        if rc is not None and rc not in used:
            used.append(rc)
    full = finite_ctors(t1)
    if full is not None and all(fc in used for fc in full):
        for c in used:
            k = ctor_arity(c, t1)
            ct = sub_types(c, t1) + coltypes[1:]
            if useful(specialize(matrix, c, k), [WILD] * k + q[1:], ct):
                return True
        return False
    return useful(default_matrix(matrix), q[1:], coltypes[1:])
