//! Differential test: random stratified programs are evaluated both by the
//! engine and by a deliberately naive reference evaluator, and must agree.

use datalog::{Atom, Const, Literal, Model, Program, Rule, Term};
use std::collections::{BTreeSet, HashMap};

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

type Db = HashMap<(String, usize), BTreeSet<Vec<Const>>>;

fn constant(i: usize) -> Const {
    if i < 3 { Const::Int(i as i64 - 1) } else { Const::Sym(format!("c{i}")) }
}

fn atom(rng: &mut Rng, pred: &str, arity: usize, vars: usize, consts: usize) -> Atom {
    let args = (0..arity)
        .map(|_| match rng.below(6) {
            0 => Term::Const(constant(rng.below(consts))),
            1 => Term::Anon,
            _ => Term::Var(format!("V{}", rng.below(vars))),
        })
        .collect();
    Atom { pred: pred.to_string(), args }
}

/// Predicates p0..p4 with arities 1 or 2; rule for pK may use positively any
/// pJ (J <= K, giving recursion) and negatively only pJ with J < K.
fn random_program(rng: &mut Rng) -> Program {
    let consts = 5;
    let arity: Vec<usize> = (0..5).map(|_| 1 + rng.below(2)).collect();
    let mut rules = Vec::new();
    for k in 0..5 {
        for _ in 0..(2 + rng.below(8)) {
            let args = (0..arity[k]).map(|_| Term::Const(constant(rng.below(consts)))).collect();
            rules.push(Rule { head: Atom { pred: format!("p{k}"), args }, body: vec![] });
        }
    }
    for k in 1..5 {
        for _ in 0..rng.below(4) {
            let nvars = 3;
            let mut body = Vec::new();
            for _ in 0..(1 + rng.below(3)) {
                let j = rng.below(k + 1);
                let mut a = atom(rng, &format!("p{j}"), arity[j], nvars, consts);
                a.pred = format!("p{j}");
                body.push(Literal::Pos(a));
            }
            let pos_vars: Vec<String> = body
                .iter()
                .flat_map(|l| match l {
                    Literal::Pos(a) => a.args.iter().filter_map(|t| if let Term::Var(v) = t { Some(v.clone()) } else { None }).collect(),
                    _ => vec![],
                })
                .collect();
            if pos_vars.is_empty() {
                continue;
            }
            let pick = |rng: &mut Rng| Term::Var(pos_vars[rng.below(pos_vars.len())].clone());
            if k > 1 && rng.below(2) == 0 {
                let j = rng.below(k);
                let args = (0..arity[j]).map(|_| if rng.below(4) == 0 { Term::Const(constant(rng.below(consts))) } else { pick(rng) }).collect();
                body.push(Literal::Neg(Atom { pred: format!("p{j}"), args }));
            }
            if rng.below(2) == 0 {
                let ops = [datalog::CmpOp::Lt, datalog::CmpOp::Le, datalog::CmpOp::Gt, datalog::CmpOp::Ge, datalog::CmpOp::Eq, datalog::CmpOp::Ne];
                let rhs = if rng.below(2) == 0 { pick(rng) } else { Term::Const(constant(rng.below(consts))) };
                body.push(Literal::Cmp(pick(rng), ops[rng.below(6)], rhs));
            }
            let args = (0..arity[k]).map(|_| if rng.below(5) == 0 { Term::Const(constant(rng.below(consts))) } else { pick(rng) }).collect();
            rules.push(Rule { head: Atom { pred: format!("p{k}"), args }, body });
        }
    }
    Program { rules, queries: vec![] }
}

/// All bindings satisfying the positive atoms from `i` on, by brute force.
fn solutions(rule: &Rule, db: &Db) -> Vec<HashMap<String, Const>> {
    fn go(lits: &[&Atom], db: &Db, env: HashMap<String, Const>, out: &mut Vec<HashMap<String, Const>>) {
        let Some((a, rest)) = lits.split_first() else {
            out.push(env);
            return;
        };
        let empty = BTreeSet::new();
        for tuple in db.get(&(a.pred.clone(), a.arity())).unwrap_or(&empty) {
            let mut e = env.clone();
            let ok = a.args.iter().zip(tuple).all(|(t, c)| match t {
                Term::Const(k) => k == c,
                Term::Anon => true,
                Term::Var(v) => e.entry(v.clone()).or_insert_with(|| c.clone()) == c,
            });
            if ok {
                go(rest, db, e, out);
            }
        }
    }
    let pos: Vec<&Atom> = rule.body.iter().filter_map(|l| if let Literal::Pos(a) = l { Some(a) } else { None }).collect();
    let mut out = Vec::new();
    go(&pos, db, HashMap::new(), &mut out);
    out
}

fn val(t: &Term, env: &HashMap<String, Const>) -> Const {
    match t {
        Term::Const(c) => c.clone(),
        Term::Var(v) => env[v].clone(),
        Term::Anon => unreachable!(),
    }
}

fn naive(program: &Program) -> Db {
    let mut db = Db::new();
    // Strata are the predicate numbers: p_k only negates p_j with j < k.
    for k in 0..5 {
        let name = format!("p{k}");
        loop {
            let mut added = false;
            for rule in program.rules.iter().filter(|r| r.head.pred == name) {
                for env in solutions(rule, &db) {
                    let ok = rule.body.iter().all(|l| match l {
                        Literal::Pos(_) => true,
                        Literal::Neg(a) => {
                            let t: Vec<Const> = a.args.iter().map(|t| val(t, &env)).collect();
                            !db.get(&(a.pred.clone(), a.arity())).is_some_and(|s| s.contains(&t))
                        }
                        Literal::Cmp(a, op, b) => op.holds(&val(a, &env), &val(b, &env)),
                    });
                    if ok {
                        let t: Vec<Const> = rule.head.args.iter().map(|t| val(t, &env)).collect();
                        added |= db.entry((name.clone(), rule.head.arity())).or_default().insert(t);
                    }
                }
            }
            if !added {
                break;
            }
        }
    }
    db
}

#[test]
fn engine_agrees_with_naive_evaluation() {
    let mut rng = Rng(0x1234_5678_9abc_def1);
    let mut nonempty = 0;
    for case in 0..300 {
        let program = random_program(&mut rng);
        let model = Model::compute(&program).unwrap_or_else(|e| {
            let text: Vec<String> = program.rules.iter().map(|r| r.to_string()).collect();
            panic!("case {case}: {e}\n{}", text.join("\n"))
        });
        let expected = naive(&program);
        for ((name, arity), tuples) in &expected {
            let got = model.tuples(name, *arity);
            let want: Vec<Vec<Const>> = tuples.iter().cloned().collect();
            if !want.is_empty() {
                nonempty += 1;
            }
            let text: Vec<String> = program.rules.iter().map(|r| r.to_string()).collect();
            assert_eq!(got, want, "case {case}, predicate {name}/{arity}\n{}", text.join("\n"));
        }
    }
    assert!(nonempty > 300);
}
