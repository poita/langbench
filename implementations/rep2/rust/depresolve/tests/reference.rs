//! Differential test: the optimised iterative resolver against a direct,
//! naive transcription of the recursive pseudo-code in the specification,
//! on many small pseudo-random registries.

use std::collections::BTreeMap;

#[derive(Clone)]
struct Req {
    name: String,
    // (lo inclusive, hi exclusive) as (maj, min, pat) tuples
    lo: (u32, u32, u32),
    hi: Option<(u32, u32, u32)>,
    text: String,
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn make_req(name: &str, rng: &mut Rng) -> Req {
    let (a, b, c) = (rng.below(3) as u32, rng.below(3) as u32, rng.below(3) as u32);
    let v = format!("{a}.{b}.{c}");
    let (lo, hi, rtext) = match rng.below(6) {
        0 => ((0, 0, 0), None, "*".to_string()),
        1 => ((a, b, c), Some((a, b, c + 1)), v.clone()),
        2 => {
            let hi = if a > 0 { (a + 1, 0, 0) } else if b > 0 { (0, b + 1, 0) } else { (0, 0, c + 1) };
            ((a, b, c), Some(hi), format!("^{v}"))
        }
        3 => ((a, b, c), Some((a, b + 1, 0)), format!("~{v}")),
        4 => ((a, b, c), None, format!(">={v}")),
        _ => ((0, 0, 0), Some((a, b, c)), format!("<{v}")),
    };
    Req { name: name.to_string(), lo, hi, text: format!("{name} {rtext}") }
}

fn gen_reqs(rng: &mut Rng, npk: u64) -> Vec<Req> {
    let k = rng.below(4);
    let mut used = vec![];
    let mut out = vec![];
    for _ in 0..k {
        let n = format!("p{}", rng.below(npk + 1)); // may name a missing package
        if used.contains(&n) {
            continue;
        }
        out.push(make_req(&n, rng));
        used.push(n);
    }
    out
}

type Registry = BTreeMap<String, BTreeMap<(u32, u32, u32), Vec<Req>>>;

fn satisfies(r: &Req, v: (u32, u32, u32)) -> bool {
    v >= r.lo && r.hi.map_or(true, |h| v < h)
}

fn naive(
    reg: &Registry,
    pending: Vec<Req>,
    chosen: BTreeMap<String, (u32, u32, u32)>,
) -> Option<BTreeMap<String, (u32, u32, u32)>> {
    let Some(first) = pending.first() else { return Some(chosen) };
    let rest = &pending[1..];
    if let Some(&v) = chosen.get(&first.name) {
        return if satisfies(first, v) { naive(reg, rest.to_vec(), chosen) } else { None };
    }
    let cands: Vec<_> = reg
        .get(&first.name)
        .map(|m| m.keys().rev().copied().filter(|&v| satisfies(first, v)).collect())
        .unwrap_or_default();
    for v in cands {
        let mut p = reg[&first.name][&v].clone();
        p.extend_from_slice(rest);
        let mut c = chosen.clone();
        c.insert(first.name.clone(), v);
        if let Some(r) = naive(reg, p, c) {
            return Some(r);
        }
    }
    None
}

#[test]
fn matches_naive_reference() {
    let mut rng = Rng(0xdecafbad);
    let mut sat = 0;
    let mut unsat = 0;
    for _ in 0..3000 {
        let npk = 1 + rng.below(6);
        let mut reg: Registry = BTreeMap::new();
        let mut text = String::new();
        for p in 0..npk {
            let nv = 1 + rng.below(5);
            for _ in 0..nv {
                let v = (rng.below(3) as u32, rng.below(3) as u32, rng.below(3) as u32);
                let name = format!("p{p}");
                if reg.get(&name).map_or(false, |m| m.contains_key(&v)) {
                    continue;
                }
                let reqs = gen_reqs(&mut rng, npk);
                text.push_str(&format!("{name} {}.{}.{}:", v.0, v.1, v.2));
                for (i, r) in reqs.iter().enumerate() {
                    text.push_str(if i == 0 { " " } else { ", " });
                    text.push_str(&r.text);
                }
                text.push('\n');
                reg.entry(name).or_default().insert(v, reqs);
            }
        }
        let root = gen_reqs(&mut rng, npk);
        text.push_str("root:");
        for (i, r) in root.iter().enumerate() {
            text.push_str(if i == 0 { " " } else { ", " });
            text.push_str(&r.text);
        }
        text.push('\n');

        let expected = match naive(&reg, root, BTreeMap::new()) {
            None => {
                unsat += 1;
                "unsatisfiable\n".to_string()
            }
            Some(m) => {
                sat += 1;
                let mut keys: Vec<_> = m.iter().collect();
                keys.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
                keys.iter().map(|(n, v)| format!("{n} {}.{}.{}\n", v.0, v.1, v.2)).collect()
            }
        };
        assert_eq!(depresolve::resolve_str(&text).unwrap(), expected, "input:\n{text}");
    }
    assert!(sat > 100 && unsat > 100, "weak generator: sat={sat} unsat={unsat}");
}
