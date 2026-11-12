//! Static checks: rule safety and stratification.

use crate::ast::*;
use crate::error::Error;
use std::collections::HashSet;

/// Check that every rule is safe.
///
/// A rule is safe when each variable of its head, of a negated atom or of a
/// comparison also occurs in a positive body atom. `_` never counts as
/// bound, so it makes a rule unsafe anywhere except in a positive atom.
///
/// # Errors
/// [`Error::Unsafe`] for the first unsafe rule.
pub fn check_safety(program: &Program) -> Result<(), Error> {
    for rule in &program.rules {
        let mut bound: HashSet<&str> = HashSet::new();
        for lit in &rule.body {
            if let Literal::Pos(a) = lit {
                for t in &a.terms {
                    if let Term::Var(v) = t {
                        bound.insert(v);
                    }
                }
            }
        }
        let ok = |t: &Term| match t {
            Term::Const(_) => true,
            Term::Var(v) => bound.contains(v.as_str()),
            Term::Anon => false,
        };
        let safe = rule.head.terms.iter().all(ok)
            && rule.body.iter().all(|lit| match lit {
                Literal::Pos(_) => true,
                Literal::Neg(a) => a.terms.iter().all(ok),
                Literal::Cmp(l, _, r) => ok(l) && ok(r),
            });
        if !safe {
            return Err(Error::Unsafe { line: rule.line });
        }
    }
    Ok(())
}

/// Compute the strata of the program: the strongly connected components of
/// the predicate dependency graph, in an order where every component comes
/// after the components it depends on.
///
/// # Errors
/// [`Error::Unstratifiable`] if a negative edge lies inside a component.
pub fn stratify(program: &Program) -> Result<Vec<Vec<PredId>>, Error> {
    let n = program.predicates.len();
    // Edge head -> body predicate ("depends on"), flagged negative.
    let mut deps: Vec<Vec<(PredId, bool)>> = vec![Vec::new(); n];
    for rule in &program.rules {
        for lit in &rule.body {
            match lit {
                Literal::Pos(a) => deps[rule.head.pred].push((a.pred, false)),
                Literal::Neg(a) => deps[rule.head.pred].push((a.pred, true)),
                Literal::Cmp(..) => {}
            }
        }
    }
    let comps = tarjan(&deps);
    let mut comp_of = vec![0; n];
    for (c, members) in comps.iter().enumerate() {
        for &p in members {
            comp_of[p] = c;
        }
    }
    for (p, edges) in deps.iter().enumerate() {
        for &(q, negative) in edges {
            if negative && comp_of[p] == comp_of[q] {
                return Err(Error::Unstratifiable { predicate: program.name(p).to_string() });
            }
        }
    }
    Ok(comps)
}

/// Tarjan's SCC algorithm. Components are emitted successors-first, i.e. in
/// dependency order for a "depends on" graph.
fn tarjan(adj: &[Vec<(PredId, bool)>]) -> Vec<Vec<usize>> {
    struct State<'a> {
        adj: &'a [Vec<(PredId, bool)>],
        index: Vec<usize>,
        low: Vec<usize>,
        on_stack: Vec<bool>,
        stack: Vec<usize>,
        counter: usize,
        out: Vec<Vec<usize>>,
    }
    const UNSEEN: usize = usize::MAX;
    fn visit(s: &mut State, v: usize) {
        s.index[v] = s.counter;
        s.low[v] = s.counter;
        s.counter += 1;
        s.stack.push(v);
        s.on_stack[v] = true;
        for i in 0..s.adj[v].len() {
            let w = s.adj[v][i].0;
            if s.index[w] == UNSEEN {
                visit(s, w);
                s.low[v] = s.low[v].min(s.low[w]);
            } else if s.on_stack[w] {
                s.low[v] = s.low[v].min(s.index[w]);
            }
        }
        if s.low[v] == s.index[v] {
            let mut comp = Vec::new();
            loop {
                let w = s.stack.pop().unwrap();
                s.on_stack[w] = false;
                comp.push(w);
                if w == v {
                    break;
                }
            }
            comp.sort_unstable();
            s.out.push(comp);
        }
    }
    let n = adj.len();
    let mut s = State {
        adj,
        index: vec![UNSEEN; n],
        low: vec![0; n],
        on_stack: vec![false; n],
        stack: Vec::new(),
        counter: 0,
        out: Vec::new(),
    };
    for v in 0..n {
        if s.index[v] == UNSEEN {
            visit(&mut s, v);
        }
    }
    s.out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    #[test]
    fn safety_examples() {
        for bad in [
            "p(X) :- q(Y).",
            "p(X).",
            "p(Y) :- q(X), X = Y.",
            "p(X) :- q(X), Y = 5.",
            "p(X) :- q(X), not r(X, _).",
            "p(_) :- q(X).",
            "p(X) :- q(X), X < _.",
        ] {
            assert!(check_safety(&parse(bad).unwrap()).is_err(), "{bad}");
        }
        for good in ["p(1).", "p(X) :- q(X, _), not r(X), X != 3.", "p(1) :- 1 < 2."] {
            assert!(check_safety(&parse(good).unwrap()).is_ok(), "{good}");
        }
    }

    #[test]
    fn negative_cycle_is_rejected() {
        let p = parse("win(X) :- e(X, Y), not win(Y).").unwrap();
        assert!(matches!(stratify(&p), Err(Error::Unstratifiable { .. })));
        let p = parse("a(X) :- b(X). b(X) :- c(X), not a(X).").unwrap();
        assert!(stratify(&p).is_err());
    }

    #[test]
    fn components_in_dependency_order() {
        let p = parse("a(X) :- b(X). b(X) :- c(X), not d(X). c(X) :- c(X). d(1).").unwrap();
        let comps = stratify(&p).unwrap();
        let pos = |name: &str| {
            let id = p.predicates.iter().position(|q| q.name == name).unwrap();
            comps.iter().position(|c| c.contains(&id)).unwrap()
        };
        assert!(pos("b") < pos("a"));
        assert!(pos("c") < pos("b"));
        assert!(pos("d") < pos("b"));
    }

    #[test]
    fn mutual_recursion_shares_a_component() {
        let p = parse("even(X) :- odd(Y), s(Y, X). odd(X) :- even(Y), s(Y, X).").unwrap();
        let comps = stratify(&p).unwrap();
        assert!(comps.iter().any(|c| c.len() == 2));
    }
}
