//! Integration tests for the library: cross-checks against brute force,
//! structured UNSAT families, and model validity.

use cdcl_sat::{format_result, Cnf, Lit, SolveResult, Solver};

/// Small deterministic xorshift generator (no external crates).
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

fn random_ksat(rng: &mut Rng, vars: usize, clauses: usize, k: usize) -> Cnf {
    let clauses = (0..clauses)
        .map(|_| {
            (0..k)
                .map(|_| {
                    let v = rng.below(vars) as i32 + 1;
                    if rng.next() & 1 == 0 {
                        v
                    } else {
                        -v
                    }
                })
                .collect()
        })
        .collect();
    Cnf { num_vars: vars, clauses }
}

fn satisfies(cnf: &Cnf, model: &[bool]) -> bool {
    model.len() == cnf.num_vars
        && cnf.clauses.iter().all(|c| {
            c.iter().any(|&l| model[l.unsigned_abs() as usize - 1] == (l > 0))
        })
}

fn brute_force_sat(cnf: &Cnf) -> bool {
    (0u32..1 << cnf.num_vars).any(|bits| {
        cnf.clauses
            .iter()
            .all(|c| c.iter().any(|&l| ((bits >> (l.unsigned_abs() - 1)) & 1 == 1) == (l > 0)))
    })
}

fn check(cnf: &Cnf) -> bool {
    match cnf.solve() {
        SolveResult::Sat(m) => {
            assert!(satisfies(cnf, &m), "model does not satisfy {cnf:?}");
            true
        }
        SolveResult::Unsat => false,
    }
}

#[test]
fn agrees_with_brute_force_on_small_random_formulas() {
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    for _ in 0..600 {
        let vars = 1 + rng.below(10);
        let clauses = rng.below(vars * 6);
        let k = 1 + rng.below(3);
        let cnf = random_ksat(&mut rng, vars, clauses, k);
        assert_eq!(check(&cnf), brute_force_sat(&cnf), "mismatch on {cnf:?}");
    }
}

#[test]
fn random_3sat_at_threshold_is_consistent() {
    let mut rng = Rng(12345);
    let (mut sat, mut unsat) = (0, 0);
    for _ in 0..20 {
        let cnf = random_ksat(&mut rng, 14, 60, 3);
        let r = check(&cnf);
        assert_eq!(r, brute_force_sat(&cnf));
        if r {
            sat += 1
        } else {
            unsat += 1
        }
    }
    assert!(sat > 0 && unsat > 0, "expected both outcomes, got {sat}/{unsat}");
}

/// Pigeonhole principle: `n + 1` pigeons into `n` holes.
fn pigeonhole(n: usize) -> Cnf {
    let var = |p: usize, h: usize| (p * n + h + 1) as i32;
    let mut clauses = Vec::new();
    for p in 0..=n {
        clauses.push((0..n).map(|h| var(p, h)).collect());
    }
    for h in 0..n {
        for p in 0..=n {
            for q in p + 1..=n {
                clauses.push(vec![-var(p, h), -var(q, h)]);
            }
        }
    }
    Cnf { num_vars: (n + 1) * n, clauses }
}

#[test]
fn pigeonhole_is_unsat() {
    for n in 1..=7 {
        assert!(!check(&pigeonhole(n)), "PHP({n}) must be UNSAT");
    }
}

#[test]
fn hard_instances_exercise_restarts_and_reductions() {
    let mut rng = Rng(777);
    let mut reduced = false;
    for _ in 0..6 {
        let cnf = random_ksat(&mut rng, 200, 852, 3);
        let mut s = cnf.into_solver();
        if let SolveResult::Sat(m) = s.solve() {
            assert!(satisfies(&cnf, &m));
        }
        let st = s.stats();
        reduced |= st.reductions > 0;
        assert!(st.restarts > 0 || st.conflicts < 100);
    }
    assert!(reduced, "no instance reached a learnt-clause reduction");
}

#[test]
fn single_huge_clause() {
    let n = 1000;
    let cnf = Cnf { num_vars: n, clauses: vec![(1..=n as i32).collect()] };
    assert!(check(&cnf));
}

#[test]
fn unused_variables_still_get_a_value() {
    let cnf = Cnf::parse("p cnf 5 1\n2 0\n").unwrap();
    match cnf.solve() {
        SolveResult::Sat(m) => {
            assert_eq!(m.len(), 5);
            assert!(m[1]);
        }
        SolveResult::Unsat => panic!("expected SAT"),
    }
}

#[test]
fn clause_added_after_units_is_simplified() {
    let mut s = Solver::new(3);
    let l = Lit::from_dimacs;
    assert!(s.add_clause(&[l(-1)]));
    assert!(s.add_clause(&[l(1), l(2)])); // becomes unit 2 at the root
    assert!(!s.add_clause(&[l(-2), l(1)]));
    assert_eq!(s.solve(), SolveResult::Unsat);
}

#[test]
fn output_format_matches_spec() {
    let cnf = Cnf::parse("p cnf 3 2\n1 -2 0\n2 3 0\n").unwrap();
    let out = format_result(&cnf.solve());
    let mut lines = out.lines();
    assert_eq!(lines.next(), Some("SAT"));
    let toks: Vec<&str> = lines.next().unwrap().split(' ').collect();
    assert_eq!(toks.len(), 4);
    assert_eq!(*toks.last().unwrap(), "0");
    assert!(lines.next().is_none());
}
