//! Integration tests: the solver is checked against brute force on random
//! small formulas, and on structured families (pigeonhole, random 3-SAT).

use cdcl_sat::{solve_cnf, solve_dimacs, Cnf};

/// Small deterministic PRNG (xorshift64*), to avoid external crates.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545F4914F6CDD1D)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

fn random_ksat(rng: &mut Rng, vars: usize, clauses: usize, k: usize) -> Cnf {
    let mut cnf = Cnf { num_vars: vars, clauses: vec![] };
    for _ in 0..clauses {
        let mut c: Vec<i32> = vec![];
        while c.len() < k {
            let v = rng.below(vars) as i32 + 1;
            if !c.iter().any(|l| l.abs() == v) {
                c.push(if rng.below(2) == 0 { v } else { -v });
            }
        }
        cnf.clauses.push(c);
    }
    cnf
}

fn satisfies(cnf: &Cnf, model: &[bool]) -> bool {
    model.len() == cnf.num_vars
        && cnf
            .clauses
            .iter()
            .all(|c| c.iter().any(|&l| model[l.unsigned_abs() as usize - 1] == (l > 0)))
}

fn brute_force_sat(cnf: &Cnf) -> bool {
    (0u32..1 << cnf.num_vars).any(|bits| {
        let m: Vec<bool> = (0..cnf.num_vars).map(|i| bits >> i & 1 == 1).collect();
        satisfies(cnf, &m)
    })
}

fn pigeonhole(holes: usize) -> Cnf {
    let pigeons = holes + 1;
    let var = |p: usize, h: usize| (p * holes + h + 1) as i32;
    let mut cnf = Cnf { num_vars: pigeons * holes, clauses: vec![] };
    for p in 0..pigeons {
        cnf.clauses.push((0..holes).map(|h| var(p, h)).collect());
    }
    for h in 0..holes {
        for p in 0..pigeons {
            for q in p + 1..pigeons {
                cnf.clauses.push(vec![-var(p, h), -var(q, h)]);
            }
        }
    }
    cnf
}

#[test]
fn agrees_with_brute_force_on_random_formulas() {
    let mut rng = Rng(0x1234_5678_9abc_def1);
    let (mut sat, mut unsat) = (0, 0);
    for round in 0..600 {
        let vars = 3 + round % 10;
        let ratio = 3 + round % 3;
        let k = 2 + round % 2;
        let cnf = random_ksat(&mut rng, vars, vars * ratio, k);
        match solve_cnf(&cnf) {
            Some(m) => {
                assert!(satisfies(&cnf, &m), "bad model for {cnf:?}");
                sat += 1;
            }
            None => {
                assert!(!brute_force_sat(&cnf), "wrong UNSAT for {cnf:?}");
                unsat += 1;
            }
        }
    }
    assert!(sat > 50 && unsat > 50, "test mix too lopsided: {sat}/{unsat}");
}

#[test]
fn messy_clauses_match_brute_force() {
    // Repeated literals, tautologies, empty clauses and long clauses.
    let mut rng = Rng(42);
    for round in 0..300 {
        let vars = 1 + round % 8;
        let mut cnf = Cnf { num_vars: vars, clauses: vec![] };
        for _ in 0..rng.below(3 * vars + 1) {
            let len = rng.below(5);
            let c = (0..len)
                .map(|_| {
                    let v = rng.below(vars) as i32 + 1;
                    if rng.below(2) == 0 { v } else { -v }
                })
                .collect();
            cnf.clauses.push(c);
        }
        let got = solve_cnf(&cnf);
        assert_eq!(got.is_some(), brute_force_sat(&cnf), "{cnf:?}");
        if let Some(m) = got {
            assert!(satisfies(&cnf, &m));
        }
    }
}

#[test]
fn pigeonhole_is_unsat() {
    for holes in 2..=7 {
        assert!(solve_cnf(&pigeonhole(holes)).is_none(), "PHP({holes})");
    }
}

#[test]
fn pigeonhole_minus_one_pigeon_is_sat() {
    let mut cnf = pigeonhole(5);
    cnf.clauses.remove(0);
    let m = solve_cnf(&cnf).expect("satisfiable");
    assert!(satisfies(&cnf, &m));
}

#[test]
fn random_3sat_at_threshold() {
    let mut rng = Rng(7);
    for _ in 0..6 {
        let cnf = random_ksat(&mut rng, 120, 511, 3);
        if let Some(m) = solve_cnf(&cnf) {
            assert!(satisfies(&cnf, &m));
        }
    }
}

#[test]
fn large_easy_instance_and_single_long_clause() {
    let mut rng = Rng(99);
    let cnf = random_ksat(&mut rng, 2000, 6000, 3);
    let m = solve_cnf(&cnf).expect("easy instance is satisfiable");
    assert!(satisfies(&cnf, &m));

    let big = Cnf { num_vars: 1000, clauses: vec![(1..=1000).collect()] };
    let m = solve_cnf(&big).unwrap();
    assert!(satisfies(&big, &m));
}

#[test]
fn spec_examples() {
    let out = solve_dimacs("c three variables, two clauses\np cnf 3 2\n1 -2 0\n2 3 0\n").unwrap();
    let mut lines = out.lines();
    assert_eq!(lines.next(), Some("SAT"));
    let model: Vec<i32> = lines.next().unwrap().split(' ').map(|t| t.parse().unwrap()).collect();
    assert_eq!(model.len(), 4);
    assert_eq!(model[3], 0);
    assert!((model[0] > 0 || model[1] < 0) && (model[1] > 0 || model[2] > 0));

    assert_eq!(
        solve_dimacs("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0\n").unwrap(),
        "UNSAT\n"
    );
    assert_eq!(solve_dimacs("p cnf 0 0\n").unwrap(), "SAT\n0\n");
    assert_eq!(solve_dimacs("p cnf 2 2\n1 -1 0\n0\n").unwrap(), "UNSAT\n");
}

#[test]
fn learnt_clause_reduction_preserves_correctness() {
    // PHP(8) needs enough conflicts to trigger restarts and reductions.
    let mut s = cdcl_sat::solver_from_cnf(&pigeonhole(8));
    assert!(!s.solve());
    let st = s.stats();
    assert!(st.conflicts > 2000, "{st:?}");
    assert!(st.restarts > 0 && st.reductions > 0, "{st:?}");
}
