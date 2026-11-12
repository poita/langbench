//! Thin singular value decomposition by one-sided Jacobi, and the condition
//! number derived from it.

use crate::error::{LinalgError, Result};
use crate::matrix::Matrix;
use crate::signs::normalize_column_sign;

/// Thin SVD `A = U diag(s) Vᵀ` with `k = min(m, n)`.
#[derive(Debug, Clone)]
pub struct Svd {
    /// `m x k`, orthonormal columns, sign-normalised.
    pub u: Matrix,
    /// `k` singular values in descending order.
    pub s: Vec<f64>,
    /// `n x k`, orthonormal columns.
    pub v: Matrix,
}

/// Maximum number of Jacobi sweeps.
const MAX_SWEEPS: usize = 60;

/// Borrow two distinct columns mutably.
fn two_cols(cols: &mut [Vec<f64>], p: usize, q: usize) -> (&mut Vec<f64>, &mut Vec<f64>) {
    debug_assert!(p < q);
    let (a, b) = cols.split_at_mut(q);
    (&mut a[p], &mut b[0])
}

fn rotate(cols: &mut [Vec<f64>], p: usize, q: usize, c: f64, s: f64) {
    let (x, y) = two_cols(cols, p, q);
    for (a, b) in x.iter_mut().zip(y.iter_mut()) {
        let (u, w) = (*a, *b);
        *a = c * u - s * w;
        *b = s * u + c * w;
    }
}

/// One-sided Jacobi on a matrix with `rows >= cols`. Returns
/// `(left vectors as columns, singular values, right vectors as columns)`,
/// sorted by descending singular value.
fn jacobi_tall(a: &Matrix) -> (Vec<Vec<f64>>, Vec<f64>, Vec<Vec<f64>>) {
    let (m, n) = (a.rows(), a.cols());
    let mut w: Vec<Vec<f64>> = (0..n).map(|j| a.col(j)).collect();
    let mut v: Vec<Vec<f64>> = (0..n)
        .map(|j| {
            let mut c = vec![0.0; n];
            c[j] = 1.0;
            c
        })
        .collect();
    for _ in 0..MAX_SWEEPS {
        let mut rotated = false;
        for p in 0..n {
            for q in p + 1..n {
                let (mut alpha, mut beta, mut gamma) = (0.0, 0.0, 0.0);
                for i in 0..m {
                    let (x, y) = (w[p][i], w[q][i]);
                    alpha += x * x;
                    beta += y * y;
                    gamma += x * y;
                }
                if gamma == 0.0
                    || alpha == 0.0
                    || beta == 0.0
                    || gamma.abs() <= 1e-14 * (alpha * beta).sqrt()
                {
                    continue;
                }
                let zeta = (beta - alpha) / (2.0 * gamma);
                let t = if zeta >= 0.0 {
                    1.0 / (zeta + (zeta * zeta + 1.0).sqrt())
                } else {
                    -1.0 / (-zeta + (zeta * zeta + 1.0).sqrt())
                };
                let c = 1.0 / (t * t + 1.0).sqrt();
                let s = t * c;
                rotate(&mut w, p, q, c, s);
                rotate(&mut v, p, q, c, s);
                rotated = true;
            }
        }
        if !rotated {
            break;
        }
    }

    let sigma: Vec<f64> = w
        .iter()
        .map(|col| {
            let mut s = 0.0;
            for x in col {
                s += x * x;
            }
            s.sqrt()
        })
        .collect();
    let mut order: Vec<usize> = (0..n).collect();
    // Stable sort: ties keep the smaller original index first.
    order.sort_by(|&i, &j| sigma[j].partial_cmp(&sigma[i]).unwrap());
    let mut us = Vec::with_capacity(n);
    let mut ss = Vec::with_capacity(n);
    let mut vs = Vec::with_capacity(n);
    for &j in &order {
        let sj = sigma[j];
        let u: Vec<f64> = if sj == 0.0 {
            vec![0.0; m]
        } else {
            w[j].iter().map(|x| x / sj).collect()
        };
        us.push(u);
        ss.push(sj);
        vs.push(std::mem::take(&mut v[j]));
    }
    (us, ss, vs)
}

fn from_columns(rows: usize, cols: &[Vec<f64>]) -> Matrix {
    let mut out = Matrix::zeros(rows, cols.len());
    for (j, col) in cols.iter().enumerate() {
        for (i, &x) in col.iter().enumerate() {
            out.set(i, j, x);
        }
    }
    out
}

/// Compute the thin SVD of any `m x n` matrix.
pub fn svd(a: &Matrix) -> Svd {
    let (m, n) = (a.rows(), a.cols());
    let transposed = m < n;
    let work = if transposed { a.transpose() } else { a.clone() };
    let (mut left, s, mut right) = jacobi_tall(&work);
    if transposed {
        std::mem::swap(&mut left, &mut right);
    }
    // Sign-normalise U, flipping the matching column of V.
    for (u, v) in left.iter_mut().zip(right.iter_mut()) {
        if normalize_column_sign(u) {
            for x in v.iter_mut() {
                *x = -*x;
            }
        }
    }
    Svd { u: from_columns(m, &left), s, v: from_columns(n, &right) }
}

/// The 2-norm condition number `σ_max / σ_min`.
///
/// Fails with `Singular` if the smallest singular value is exactly zero.
pub fn cond(a: &Matrix) -> Result<f64> {
    let s = svd(a).s;
    let max = s[0];
    let min = s[s.len() - 1];
    if min == 0.0 {
        return Err(LinalgError::Singular);
    }
    Ok(max / min)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reconstruct(f: &Svd) -> Matrix {
        let k = f.s.len();
        let mut us = f.u.clone();
        for i in 0..us.rows() {
            for j in 0..k {
                us.set(i, j, us.get(i, j) * f.s[j]);
            }
        }
        us.mul(&f.v.transpose()).unwrap()
    }

    fn check(a: &Matrix) {
        let f = svd(a);
        let r = reconstruct(&f);
        for (x, y) in r.as_slice().iter().zip(a.as_slice()) {
            assert!((x - y).abs() < 1e-12, "{x} vs {y}");
        }
        assert!(f.s.windows(2).all(|w| w[0] >= w[1]));
        assert_eq!(f.u.cols(), a.rows().min(a.cols()));
        assert_eq!(f.v.rows(), a.cols());
    }

    #[test]
    fn tall_wide_and_square() {
        check(&Matrix::from_rows(&[vec![3.0, 1.0], vec![1.0, 2.0], vec![0.0, 4.0]]));
        check(&Matrix::from_rows(&[vec![3.0, 1.0, 0.0], vec![1.0, 2.0, 4.0]]));
        check(&Matrix::from_rows(&[vec![1.0, 2.0], vec![3.0, 4.0]]));
    }

    #[test]
    fn diagonal_values() {
        let a = Matrix::from_rows(&[vec![2.0, 0.0], vec![0.0, -5.0]]);
        let f = svd(&a);
        assert_eq!(f.s, vec![5.0, 2.0]);
        // U's columns are sign-normalised, so the sign lives in V.
        assert_eq!(f.u.get(1, 0), 1.0);
        assert_eq!(f.v.get(1, 0), -1.0);
    }

    #[test]
    fn condition_number() {
        let a = Matrix::from_rows(&[vec![2.0, 0.0], vec![0.0, 0.5]]);
        assert!((cond(&a).unwrap() - 4.0).abs() < 1e-14);
        let z = Matrix::zeros(2, 2);
        assert_eq!(cond(&z).unwrap_err(), LinalgError::Singular);
    }
}
