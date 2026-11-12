//! Symmetric eigendecomposition by cyclic Jacobi rotations.

use crate::error::Result;
use crate::matrix::Matrix;
use crate::signs::normalize_column_sign;

/// Eigenvalues (ascending) and the matching orthonormal eigenvectors.
#[derive(Debug, Clone)]
pub struct Eigen {
    /// Eigenvalues in ascending order.
    pub values: Vec<f64>,
    /// Orthogonal matrix whose column `j` is the unit eigenvector for
    /// `values[j]`, sign-normalised.
    pub vectors: Matrix,
}

/// Maximum number of Jacobi sweeps.
const MAX_SWEEPS: usize = 60;

/// Compute the eigendecomposition of a symmetric matrix.
///
/// Fails with `NotSquare` or `NotSymmetric`.
pub fn eigh(a: &Matrix) -> Result<Eigen> {
    a.require_symmetric()?;
    let n = a.rows();
    let mut m = a.clone();
    let mut v = Matrix::identity(n);
    let phi = a.norm_fro();
    let mut prev = f64::INFINITY;
    for _ in 0..MAX_SWEEPS {
        let off = off_norm(&m);
        if off <= 1e-14 * phi || off >= prev {
            break;
        }
        prev = off;
        sweep(&mut m, &mut v);
    }

    let mut order: Vec<usize> = (0..n).collect();
    // Stable sort keeps the smaller original index first among ties.
    order.sort_by(|&i, &j| m.get(i, i).partial_cmp(&m.get(j, j)).unwrap());
    let values: Vec<f64> = order.iter().map(|&i| m.get(i, i)).collect();
    let mut vectors = Matrix::zeros(n, n);
    for (new_j, &old_j) in order.iter().enumerate() {
        let mut col = v.col(old_j);
        normalize_column_sign(&mut col);
        for (i, x) in col.into_iter().enumerate() {
            vectors.set(i, new_j, x);
        }
    }
    Ok(Eigen { values, vectors })
}

/// `sqrt(2 Σ_{i<j} M[i][j]²)`, strict upper triangle in row-major order.
fn off_norm(m: &Matrix) -> f64 {
    let n = m.rows();
    let mut s = 0.0;
    for i in 0..n {
        for j in i + 1..n {
            let x = m.get(i, j);
            s += x * x;
        }
    }
    (2.0 * s).sqrt()
}

/// One sweep over all pairs `(p, q)`, `p < q`, in row-major order.
fn sweep(m: &mut Matrix, v: &mut Matrix) {
    let n = m.rows();
    for p in 0..n {
        for q in p + 1..n {
            let mpq = m.get(p, q);
            if mpq == 0.0 {
                continue;
            }
            let theta = (m.get(q, q) - m.get(p, p)) / (2.0 * mpq);
            let t = if theta >= 0.0 {
                1.0 / (theta + (theta * theta + 1.0).sqrt())
            } else {
                -1.0 / (-theta + (theta * theta + 1.0).sqrt())
            };
            let c = 1.0 / (t * t + 1.0).sqrt();
            let s = t * c;
            // Columns first, then rows: M <- Jᵀ M J.
            rotate_columns(m, p, q, c, s);
            rotate_rows(m, p, q, c, s);
            m.set(p, q, 0.0);
            m.set(q, p, 0.0);
            rotate_columns(v, p, q, c, s);
        }
    }
}

fn rotate_columns(m: &mut Matrix, p: usize, q: usize, c: f64, s: f64) {
    for i in 0..m.rows() {
        let row = m.row_mut(i);
        let (x, y) = (row[p], row[q]);
        row[p] = c * x - s * y;
        row[q] = s * x + c * y;
    }
}

fn rotate_rows(m: &mut Matrix, p: usize, q: usize, c: f64, s: f64) {
    let n = m.cols();
    let (top, bottom) = m.as_mut_slice_split(q, q + 1);
    let row_p = &mut top[p * n..(p + 1) * n];
    let row_q = &mut bottom[..n];
    for (x, y) in row_p.iter_mut().zip(row_q.iter_mut()) {
        let (a, b) = (*x, *y);
        *x = c * a - s * b;
        *y = s * a + c * b;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_by_two_example() {
        let a = Matrix::from_rows(&[vec![2.0, 1.0], vec![1.0, 3.0]]);
        let e = eigh(&a).unwrap();
        let r5 = 5f64.sqrt();
        assert!((e.values[0] - (5.0 - r5) / 2.0).abs() < 1e-14);
        assert!((e.values[1] - (5.0 + r5) / 2.0).abs() < 1e-14);
        assert!((e.vectors.get(0, 0) - 0.8506508083520399).abs() < 1e-13);
        assert!((e.vectors.get(1, 0) + 0.5257311121191336).abs() < 1e-13);
    }

    #[test]
    fn diagonal_is_sorted() {
        let a = Matrix::from_rows(&[
            vec![3.0, 0.0, 0.0],
            vec![0.0, 1.0, 0.0],
            vec![0.0, 0.0, 2.0],
        ]);
        let e = eigh(&a).unwrap();
        assert_eq!(e.values, vec![1.0, 2.0, 3.0]);
        assert_eq!(e.vectors.get(1, 0), 1.0);
    }

    #[test]
    fn residual_is_small() {
        let a = Matrix::from_rows(&[
            vec![4.0, 1.0, -2.0, 0.5],
            vec![1.0, 3.0, 0.0, 1.0],
            vec![-2.0, 0.0, 5.0, 2.0],
            vec![0.5, 1.0, 2.0, -1.0],
        ]);
        let e = eigh(&a).unwrap();
        let av = a.mul(&e.vectors).unwrap();
        for j in 0..4 {
            for i in 0..4 {
                let want = e.vectors.get(i, j) * e.values[j];
                assert!((av.get(i, j) - want).abs() < 1e-12);
            }
        }
        assert!(e.values.windows(2).all(|w| w[0] <= w[1]));
    }

    #[test]
    fn rejects_bad_input() {
        assert!(eigh(&Matrix::zeros(2, 3)).is_err());
        let ns = Matrix::from_rows(&[vec![1.0, 2.0], vec![3.0, 1.0]]);
        assert!(eigh(&ns).is_err());
    }
}
