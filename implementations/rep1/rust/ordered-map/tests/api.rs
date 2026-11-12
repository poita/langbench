//! Tests of the public library API.

use ordered_map::OrderedMap;

fn sample() -> OrderedMap<&'static str> {
    [(10, "a"), (20, "b"), (30, "c")].into_iter().collect()
}

#[test]
fn neighbours_and_order_statistics() {
    let m = sample();
    assert_eq!(m.floor(25), Some(20));
    assert_eq!(m.ceil(25), Some(30));
    assert_eq!(m.floor(10), Some(10));
    assert_eq!(m.ceil(10), Some(10));
    assert_eq!(m.successor(10), Some(20));
    assert_eq!(m.predecessor(10), None);
    assert_eq!(m.rank(20), 1);
    assert_eq!(m.rank(21), 2);
    assert_eq!(m.select(2), Some(30));
    assert_eq!(m.select(3), None);
}

#[test]
fn range_is_inclusive_and_handles_inverted_bounds() {
    let m = sample();
    let keys = |lo, hi| m.range(lo..=hi).map(|(k, _)| k).collect::<Vec<_>>();
    assert_eq!(keys(10, 30), [10, 20, 30]);
    assert_eq!(keys(11, 29), [20]);
    assert_eq!(keys(30, 10), Vec::<i64>::new());
    assert_eq!(keys(i64::MIN, i64::MAX), [10, 20, 30]);
}

#[test]
fn iteration_and_mutation() {
    let mut m = sample();
    *m.get_mut(20).unwrap() = "B";
    assert_eq!(m.iter().map(|(_, v)| *v).collect::<Vec<_>>(), ["a", "B", "c"]);
    assert_eq!(m.keys().collect::<Vec<_>>(), [10, 20, 30]);
    assert_eq!(m.first_key_value(), Some((10, &"a")));
    assert_eq!(m.last_key_value(), Some((30, &"c")));
    let c = m.clone();
    m.clear();
    assert!(m.is_empty());
    assert_eq!(c.len(), 3);
    assert_eq!(format!("{c:?}"), r#"{10: "a", 20: "B", 30: "c"}"#);
}
