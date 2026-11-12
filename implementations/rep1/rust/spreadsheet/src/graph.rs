//! Strongly connected components of a directed graph (iterative Tarjan).

/// Runs Tarjan's algorithm on the graph with nodes `0..adj.len()` and edges
/// `v -> w` for every `w` in `adj[v]`, calling `emit` once per strongly
/// connected component.
///
/// Components are emitted in reverse topological order of the condensation:
/// a component is emitted only after every component reachable from it. With
/// edges pointing from a cell to the cells it reads, that means
/// dependencies come first. The implementation is iterative, so very deep
/// graphs do not overflow the call stack.
pub fn strongly_connected_components<F: FnMut(&[usize])>(adj: &[Vec<u32>], mut emit: F) {
    const UNVISITED: u32 = u32::MAX;
    let n = adj.len();
    let mut index = vec![UNVISITED; n];
    let mut low = vec![0u32; n];
    let mut on_stack = vec![false; n];
    let mut stack: Vec<usize> = Vec::new();
    let mut calls: Vec<(usize, usize)> = Vec::new();
    let mut counter = 0u32;
    let mut component: Vec<usize> = Vec::new();

    for root in 0..n {
        if index[root] != UNVISITED {
            continue;
        }
        index[root] = counter;
        low[root] = counter;
        counter += 1;
        stack.push(root);
        on_stack[root] = true;
        calls.push((root, 0));
        while let Some(&mut (v, ref mut next)) = calls.last_mut() {
            if let Some(&w) = adj[v].get(*next) {
                *next += 1;
                let w = w as usize;
                if index[w] == UNVISITED {
                    index[w] = counter;
                    low[w] = counter;
                    counter += 1;
                    stack.push(w);
                    on_stack[w] = true;
                    calls.push((w, 0));
                } else if on_stack[w] {
                    low[v] = low[v].min(index[w]);
                }
            } else {
                calls.pop();
                if low[v] == index[v] {
                    component.clear();
                    loop {
                        let w = stack.pop().expect("component member on stack");
                        on_stack[w] = false;
                        component.push(w);
                        if w == v {
                            break;
                        }
                    }
                    emit(&component);
                }
                if let Some(&(parent, _)) = calls.last() {
                    low[parent] = low[parent].min(low[v]);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn components(adj: &[Vec<u32>]) -> Vec<Vec<usize>> {
        let mut out = Vec::new();
        strongly_connected_components(adj, |c| {
            let mut c = c.to_vec();
            c.sort();
            out.push(c);
        });
        out
    }

    #[test]
    fn chain_emits_sinks_first() {
        assert_eq!(components(&[vec![1], vec![2], vec![]]), [vec![2], vec![1], vec![0]]);
    }

    #[test]
    fn finds_cycles_and_self_loops() {
        let comps = components(&[vec![1], vec![0, 2], vec![2]]);
        assert_eq!(comps, [vec![2], vec![0, 1]]);
    }

    #[test]
    fn deep_chain_does_not_overflow() {
        let n = 200_000;
        let adj: Vec<Vec<u32>> = (0..n).map(|i| if i + 1 < n { vec![i as u32 + 1] } else { vec![] }).collect();
        let mut count = 0;
        strongly_connected_components(&adj, |_| count += 1);
        assert_eq!(count, n);
    }
}
