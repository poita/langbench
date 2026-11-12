//! Static checks: rule safety and stratification.

use crate::ast::{Literal, Program, Rule, Term};
use crate::error::Error;
use crate::symbols::{PredId, PredTable};
use std::collections::HashSet;

/// Check that every rule is safe.
///
/// A rule is safe when every variable of its head, of its negated atoms and
/// of its comparisons also occurs in a positive body atom. Anonymous
/// variables are fresh at each occurrence, so one outside a positive body atom
/// is always unsafe; a fact is safe only if its head is ground.
pub fn check_safety(program: &Program) -> Result<(), Error> {
    program.rules.iter().try_for_each(check_rule_safety)
}

fn check_rule_safety(rule: &Rule) -> Result<(), Error> {
    let mut bound: HashSet<&str> = HashSet::new();
    for lit in &rule.body {
        if let Literal::Pos(a) = lit {
            for t in &a.args {
                if let Term::Var(v) = t {
                    bound.insert(v);
                }
            }
        }
    }
    let fail = |t: &Term| Error::UnsafeRule { rule: rule.to_string(), variable: t.to_string() };
    let unbound = |t: &Term| match t {
        Term::Var(v) => !bound.contains(v.as_str()),
        Term::Anon => true,
        Term::Const(_) => false,
    };
    if let Some(t) = rule.head.args.iter().find(|t| unbound(t)) {
        return Err(fail(t));
    }
    for lit in &rule.body {
        let bad = match lit {
            Literal::Pos(_) => None,
            Literal::Neg(a) => a.args.iter().find(|t| unbound(t)),
            Literal::Cmp(a, _, b) => [a, b].into_iter().find(|t| unbound(t)),
        };
        if let Some(t) = bad {
            return Err(fail(t));
        }
    }
    Ok(())
}

/// A strongly connected component of the predicate dependency graph.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Component {
    /// The predicates of the component.
    pub preds: Vec<PredId>,
    /// `true` if the component contains a cycle (several predicates, or one
    /// predicate that depends on itself).
    pub recursive: bool,
    /// Stratum number: 0 for components that depend on nothing, and one more
    /// than the maximum over the components depended upon (counting negative
    /// dependencies as +1).
    pub stratum: usize,
}

/// The result of stratifying a program.
#[derive(Debug, Clone)]
pub struct Stratification {
    /// All predicates of the program.
    pub preds: PredTable,
    /// Components in evaluation order: each one depends only on earlier ones
    /// (and on itself).
    pub components: Vec<Component>,
    /// For each predicate, the index of its component in `components`.
    pub component_of: Vec<usize>,
}

/// Build the dependency graph, find its strongly connected components with
/// Tarjan's algorithm and reject negative edges inside a component.
pub fn stratify(program: &Program) -> Result<Stratification, Error> {
    let preds = PredTable::from_program(program);
    let n = preds.len();
    // edges[head] = (body predicate, negative?)
    let mut edges: Vec<Vec<(PredId, bool)>> = vec![Vec::new(); n];
    for rule in &program.rules {
        let h = preds.get(&rule.head.pred, rule.head.arity()).expect("interned");
        for lit in &rule.body {
            match lit {
                Literal::Pos(a) => edges[h].push((preds.get(&a.pred, a.arity()).unwrap(), false)),
                Literal::Neg(a) => edges[h].push((preds.get(&a.pred, a.arity()).unwrap(), true)),
                Literal::Cmp(..) => {}
            }
        }
    }
    let sccs = tarjan(&edges);
    let mut component_of = vec![0; n];
    for (c, members) in sccs.iter().enumerate() {
        for &p in members {
            component_of[p] = c;
        }
    }
    let mut components: Vec<Component> = Vec::with_capacity(sccs.len());
    for (c, members) in sccs.into_iter().enumerate() {
        let mut recursive = members.len() > 1;
        let mut stratum = 0;
        for &p in &members {
            for &(q, neg) in &edges[p] {
                if component_of[q] == c {
                    if neg {
                        return Err(Error::NotStratifiable { predicate: preds.display(p) });
                    }
                    recursive = true;
                } else {
                    // Tarjan emits dependencies first, so `q`'s component is done.
                    stratum = stratum.max(components[component_of[q]].stratum + usize::from(neg));
                }
            }
        }
        components.push(Component { preds: members, recursive, stratum });
    }
    Ok(Stratification { preds, components, component_of })
}

/// Tarjan's SCC algorithm. Components are returned in reverse topological
/// order of the graph, i.e. every component appears after the components its
/// members have edges to.
fn tarjan(edges: &[Vec<(PredId, bool)>]) -> Vec<Vec<PredId>> {
    struct State<'a> {
        edges: &'a [Vec<(PredId, bool)>],
        index: Vec<Option<usize>>,
        low: Vec<usize>,
        on_stack: Vec<bool>,
        stack: Vec<usize>,
        counter: usize,
        out: Vec<Vec<PredId>>,
    }
    fn visit(s: &mut State, v: usize) {
        s.index[v] = Some(s.counter);
        s.low[v] = s.counter;
        s.counter += 1;
        s.stack.push(v);
        s.on_stack[v] = true;
        for i in 0..s.edges[v].len() {
            let w = s.edges[v][i].0;
            match s.index[w] {
                None => {
                    visit(s, w);
                    s.low[v] = s.low[v].min(s.low[w]);
                }
                Some(iw) if s.on_stack[w] => s.low[v] = s.low[v].min(iw),
                Some(_) => {}
            }
        }
        if Some(s.low[v]) == s.index[v] {
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
    let n = edges.len();
    let mut s = State {
        edges,
        index: vec![None; n],
        low: vec![0; n],
        on_stack: vec![false; n],
        stack: Vec::new(),
        counter: 0,
        out: Vec::new(),
    };
    for v in 0..n {
        if s.index[v].is_none() {
            visit(&mut s, v);
        }
    }
    s.out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse;

    fn safe(src: &str) -> bool {
        check_safety(&parse(src).unwrap()).is_ok()
    }

    #[test]
    fn safety() {
        assert!(safe("p(X) :- q(X), not r(X), X < 3."));
        assert!(safe("p(a) :- not q(b)."));
        assert!(safe("p(X) :- q(X, _)."));
        assert!(!safe("p(X)."));
        assert!(!safe("p(X) :- q(Y)."));
        assert!(!safe("p(Y) :- q(X), X = Y."));
        assert!(!safe("p(X) :- q(X), Y = 5."));
        assert!(!safe("p(X) :- q(X), not r(X, _)."));
        assert!(!safe("p(_) :- q(X)."));
        assert!(!safe("p(X) :- not q(X)."));
    }

    #[test]
    fn stratification() {
        let ok = stratify(&parse("a(X) :- b(X). b(X) :- c(X), not d(X). d(1).").unwrap()).unwrap();
        let st = |name: &str| {
            let id = ok.preds.get(name, 1).unwrap();
            ok.components[ok.component_of[id]].stratum
        };
        assert_eq!(st("d"), 0);
        assert_eq!(st("c"), 0);
        assert_eq!(st("b"), 1);
        assert_eq!(st("a"), 1);
        assert!(stratify(&parse("w(X) :- e(X, Y), not w(Y).").unwrap()).is_err());
        assert!(stratify(&parse("p(X) :- q(X). q(X) :- r(X), not p(X).").unwrap()).is_err());
        let rec = stratify(&parse("p(X) :- q(X). q(X) :- p(X). p(1).").unwrap()).unwrap();
        assert!(rec.components.iter().any(|c| c.recursive && c.preds.len() == 2));
    }

    #[test]
    fn components_in_dependency_order() {
        let s = stratify(&parse("c(X) :- b(X). b(X) :- a(X). a(1).").unwrap()).unwrap();
        let pos = |n: &str| s.component_of[s.preds.get(n, 1).unwrap()];
        assert!(pos("a") < pos("b") && pos("b") < pos("c"));
    }
}
