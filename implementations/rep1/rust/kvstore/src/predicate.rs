//! Predicates for `find`: the syntax tree, evaluation and plan selection.

use crate::index::vkey;
use crate::path::Path;
use crate::value::Value;

/// A comparison operator.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CmpOp {
    /// `==`
    Eq,
    /// `!=`
    Ne,
    /// `<`
    Lt,
    /// `<=`
    Le,
    /// `>`
    Gt,
    /// `>=`
    Ge,
}

/// A predicate over documents.
#[derive(Clone, Debug, PartialEq)]
pub enum Pred {
    /// Both sides hold.
    And(Box<Pred>, Box<Pred>),
    /// At least one side holds.
    Or(Box<Pred>, Box<Pred>),
    /// The inner predicate does not hold.
    Not(Box<Pred>),
    /// The path resolves to a value.
    Exists(Path),
    /// The path does not resolve.
    Missing(Path),
    /// `path op value`.
    Cmp(Path, CmpOp, Value),
}

impl Pred {
    /// Evaluates the predicate against a document (spec §17.2).
    pub fn eval(&self, doc: &Value) -> bool {
        match self {
            Pred::And(a, b) => a.eval(doc) && b.eval(doc),
            Pred::Or(a, b) => a.eval(doc) || b.eval(doc),
            Pred::Not(p) => !p.eval(doc),
            Pred::Exists(p) => doc.get_path(p.segments()).is_some(),
            Pred::Missing(p) => doc.get_path(p.segments()).is_none(),
            Pred::Cmp(p, op, v) => match doc.get_path(p.segments()) {
                None => false,
                Some(x) => compare(x, *op, v),
            },
        }
    }

    /// The leaves of the `and`-flattened predicate, left to right.
    fn leaves<'a>(&'a self, out: &mut Vec<&'a Pred>) {
        match self {
            Pred::And(a, b) => {
                a.leaves(out);
                b.leaves(out);
            }
            other => out.push(other),
        }
    }
}

fn compare(x: &Value, op: CmpOp, v: &Value) -> bool {
    match op {
        CmpOp::Eq => x == v,
        CmpOp::Ne => x != v,
        _ => {
            if x.rank() != v.rank() {
                return false;
            }
            let ord = match (x, v) {
                (Value::Null, Value::Null) => std::cmp::Ordering::Equal,
                (Value::Bool(a), Value::Bool(b)) => a.cmp(b),
                (Value::Int(a), Value::Int(b)) => a.cmp(b),
                (Value::Str(a), Value::Str(b)) => a.as_bytes().cmp(b.as_bytes()),
                _ => return false,
            };
            match op {
                CmpOp::Lt => ord.is_lt(),
                CmpOp::Le => ord.is_le(),
                CmpOp::Gt => ord.is_gt(),
                _ => ord.is_ge(),
            }
        }
    }
}

/// How a `find` is evaluated.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Plan {
    /// Walk the whole primary tree.
    Scan,
    /// Walk a range of a secondary index.
    Index {
        /// Path text of the index.
        path: String,
        /// The operator of the chosen leaf.
        op: CmpOp,
        /// `vkey` of the leaf's value.
        vkey: Vec<u8>,
    },
}

impl Plan {
    /// The text printed after `plan` in a result block.
    pub fn describe(&self) -> String {
        match self {
            Plan::Scan => "scan".to_string(),
            Plan::Index { path, .. } => format!("index {path}"),
        }
    }
}

/// Chooses the plan for `pred` given the path texts of the live indexes
/// (spec §17.3).
pub fn choose_plan(pred: &Pred, live_paths: &[&str]) -> Plan {
    let mut leaves = Vec::new();
    pred.leaves(&mut leaves);
    let mut best: Option<(u8, &str, CmpOp, Vec<u8>)> = None;
    for leaf in leaves {
        let Pred::Cmp(path, op, value) = leaf else { continue };
        if *op == CmpOp::Ne || !live_paths.contains(&path.text()) {
            continue;
        }
        let Some(vk) = vkey(value) else { continue };
        let class = if *op == CmpOp::Eq { 0 } else { 1 };
        let better = match &best {
            None => true,
            Some((bc, bp, _, _)) => (class, path.text().as_bytes()) < (*bc, bp.as_bytes()),
        };
        if better {
            best = Some((class, path.text(), *op, vk));
        }
    }
    match best {
        None => Plan::Scan,
        Some((_, p, op, vk)) => Plan::Index { path: p.to_string(), op, vkey: vk },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmp(path: &str, op: CmpOp, v: Value) -> Pred {
        Pred::Cmp(Path::parse(path).unwrap(), op, v)
    }

    #[test]
    fn missing_paths_fail_every_comparison() {
        let doc = Value::Object(Default::default());
        for op in [CmpOp::Eq, CmpOp::Ne, CmpOp::Lt, CmpOp::Le, CmpOp::Gt, CmpOp::Ge] {
            assert!(!cmp("a", op, Value::Int(1)).eval(&doc));
        }
        assert!(Pred::Not(Box::new(cmp("a", CmpOp::Eq, Value::Int(1)))).eval(&doc));
    }

    #[test]
    fn ordering_rules() {
        assert!(compare(&Value::Null, CmpOp::Le, &Value::Null));
        assert!(!compare(&Value::Null, CmpOp::Lt, &Value::Null));
        assert!(!compare(&Value::Int(1), CmpOp::Lt, &Value::Str("a".into())));
        assert!(compare(&Value::Int(1), CmpOp::Ne, &Value::Str("a".into())));
        assert!(compare(&Value::Bool(false), CmpOp::Lt, &Value::Bool(true)));
        assert!(!compare(&Value::List(vec![]), CmpOp::Le, &Value::List(vec![])));
    }

    #[test]
    fn plan_prefers_equality_then_path_then_position() {
        let p = Pred::And(
            Box::new(cmp("b", CmpOp::Gt, Value::Int(1))),
            Box::new(Pred::And(
                Box::new(cmp("c", CmpOp::Eq, Value::Int(1))),
                Box::new(cmp("a", CmpOp::Eq, Value::Int(2))),
            )),
        );
        match choose_plan(&p, &["a", "b", "c"]) {
            Plan::Index { path, .. } => assert_eq!(path, "a"),
            _ => panic!(),
        }
        assert_eq!(choose_plan(&p, &[]), Plan::Scan);
        assert_eq!(choose_plan(&cmp("a", CmpOp::Ne, Value::Int(1)), &["a"]), Plan::Scan);
    }
}
