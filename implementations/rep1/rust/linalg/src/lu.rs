//! LU factorisation with partial pivoting, and the determinant, solve and
//! inverse built on it.

use crate::error::{LinalgError, Result};
use crate::matrix::Matrix;

/// The result of `P A = L U`, kept in packed form.
#[derive(Debug, Clone)]
pub struct Lu {
    /// Packed factors: multipliers of `L` strictly below the diagonal,
    /// `U` on and above it.
    packed: Matrix,
    /// `perm[i]` is the original row now sitting in row `i`.
    perm: Vec<usize>,
    /// Number of row swaps performed.
    swaps: usize,
}

/// Run the elimination on a square matrix. Returns the packed factors, the
/// permutation, the swap count, and `false` if an exactly zero pivot was met
/// (in which case the other values are partial).
fn eliminate(a: &Matrix) -> (Matrix, Vec<usize>, usize, bool) {
    let n = a.rows();
    let mut m = a.clone();
    let mut perm: Vec<usize> = (0..n).collect();
    let mut swaps = 0;
    for k in 0..n {
        let mut p = k;
        let mut best = m.get(k, k).abs();
        for i in k + 1..n {
            let v = m.get(i, k).abs();
            if v > best {
                best = v;
                p = i;
            }
        }
        if best == 0.0 {
            return (m, perm, swaps, false);
        }
        if p != k {
            for j in 0..n {
                let t = m.get(k, j);
                m.set(k, j, m.get(p, j));
                m.set(p, j, t);
            }
            perm.swap(k, p);
            swaps += 1;
        }
        let (top, bottom) = m.as_mut_slice_split(k + 1, n);
        let pivot_row = &top[k * n..(k + 1) * n];
        let pivot = pivot_row[k];
        for i in 0..n - k - 1 {
            let row = &mut bottom[i * n..(i + 1) * n];
            let f = row[k] / pivot;
            row[k] = f;
            for j in k + 1..n {
                row[j] -= f * pivot_row[j];
            }
        }
    }
    (m, perm, swaps, true)
}

impl Lu {
    /// Factor a square matrix. Fails with `NotSquare` or `Singular`.
    pub fn factor(a: &Matrix) -> Result<Lu> {
        a.require_square()?;
        let (packed, perm, swaps, ok) = eliminate(a);
        if !ok {
            return Err(LinalgError::Singular);
        }
        Ok(Lu { packed, perm, swaps })
    }

    /// Order of the factored matrix.
    pub fn n(&self) -> usize {
        self.perm.len()
    }

    /// Row permutation: `perm()[i]` is the index in `A` of row `i` of `P A`.
    pub fn perm(&self) -> &[usize] {
        &self.perm
    }

    /// Number of row interchanges.
    pub fn swaps(&self) -> usize {
        self.swaps
    }

    /// The permutation matrix `P` with `P[i][perm[i]] = 1`.
    pub fn p(&self) -> Matrix {
        let n = self.n();
        let mut p = Matrix::zeros(n, n);
        for (i, &j) in self.perm.iter().enumerate() {
            p.set(i, j, 1.0);
        }
        p
    }

    /// Unit lower triangular factor.
    pub fn l(&self) -> Matrix {
        let n = self.n();
        let mut l = Matrix::zeros(n, n);
        for i in 0..n {
            for j in 0..i {
                l.set(i, j, self.packed.get(i, j));
            }
            l.set(i, i, 1.0);
        }
        l
    }

    /// Upper triangular factor.
    pub fn u(&self) -> Matrix {
        let n = self.n();
        let mut u = Matrix::zeros(n, n);
        for i in 0..n {
            for j in i..n {
                u.set(i, j, self.packed.get(i, j));
            }
        }
        u
    }

    /// Determinant: product of `U`'s diagonal times the swap parity.
    pub fn det(&self) -> f64 {
        let mut d = 1.0;
        for i in 0..self.n() {
            d *= self.packed.get(i, i);
        }
        if self.swaps % 2 == 1 {
            -d
        } else {
            d
        }
    }

    /// Solve `A X = B` column by column.
    pub fn solve(&self, b: &Matrix) -> Result<Matrix> {
        let n = self.n();
        if b.rows() != n {
            return Err(LinalgError::DimensionMismatch);
        }
        let k = b.cols();
        let mut x = Matrix::zeros(n, k);
        let mut y = vec![0.0; n];
        for c in 0..k {
            for i in 0..n {
                let mut s = b.get(self.perm[i], c);
                for j in 0..i {
                    s -= self.packed.get(i, j) * y[j];
                }
                y[i] = s;
            }
            for i in (0..n).rev() {
                let mut s = y[i];
                for j in i + 1..n {
                    s -= self.packed.get(i, j) * y[j];
                }
                y[i] = s / self.packed.get(i, i);
            }
            for i in 0..n {
                x.set(i, c, y[i]);
            }
        }
        Ok(x)
    }
}

/// Determinant of a square matrix; `0.0` if a pivot is exactly zero.
pub fn det(a: &Matrix) -> Result<f64> {
    a.require_square()?;
    let (packed, perm, swaps, ok) = eliminate(a);
    if !ok {
        return Ok(0.0);
    }
    Ok(Lu { packed, perm, swaps }.det())
}

/// Solve `A X = B` for square `A`.
pub fn solve(a: &Matrix, b: &Matrix) -> Result<Matrix> {
    a.require_square()?;
    if b.rows() != a.rows() {
        return Err(LinalgError::DimensionMismatch);
    }
    Lu::factor(a)?.solve(b)
}

/// Inverse of a square matrix, computed as `solve(A, I)`.
pub fn inverse(a: &Matrix) -> Result<Matrix> {
    a.require_square()?;
    Lu::factor(a)?.solve(&Matrix::identity(a.rows()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(rows: &[&[f64]]) -> Matrix {
        Matrix::from_rows(&rows.iter().map(|r| r.to_vec()).collect::<Vec<_>>())
    }

    #[test]
    fn factor_two_by_two() {
        let a = m(&[&[1.0, 2.0], &[3.0, 4.0]]);
        let lu = Lu::factor(&a).unwrap();
        assert_eq!(lu.perm(), &[1, 0]);
        assert_eq!(lu.swaps(), 1);
        assert_eq!(lu.u().get(0, 0), 3.0);
        assert!((lu.l().get(1, 0) - 1.0 / 3.0).abs() < 1e-16);
        let pa = lu.p().mul(&a).unwrap();
        let lu_prod = lu.l().mul(&lu.u()).unwrap();
        for (x, y) in pa.as_slice().iter().zip(lu_prod.as_slice()) {
            assert!((x - y).abs() < 1e-15);
        }
    }

    #[test]
    fn determinant() {
        let a = m(&[&[1.0, 2.0], &[3.0, 4.0]]);
        assert!((det(&a).unwrap() + 2.0).abs() < 1e-14);
        let s = m(&[&[1.0, 2.0], &[2.0, 4.0]]);
        assert_eq!(det(&s).unwrap(), 0.0);
        assert_eq!(det(&Matrix::zeros(2, 3)), Err(LinalgError::NotSquare));
    }

    #[test]
    fn singular_and_shapes() {
        let s = m(&[&[1.0, 2.0], &[2.0, 4.0]]);
        assert_eq!(inverse(&s).unwrap_err(), LinalgError::Singular);
        let a = Matrix::zeros(2, 3);
        let b = Matrix::zeros(3, 1);
        assert_eq!(solve(&a, &b).unwrap_err(), LinalgError::NotSquare);
        let good = Matrix::identity(2);
        assert_eq!(solve(&good, &b).unwrap_err(), LinalgError::DimensionMismatch);
    }

    #[test]
    fn inverse_times_a_is_identity() {
        let a = m(&[&[4.0, 3.0, 0.0], &[3.0, 5.0, 1.0], &[0.0, 1.0, 2.0]]);
        let inv = inverse(&a).unwrap();
        let prod = a.mul(&inv).unwrap();
        for i in 0..3 {
            for j in 0..3 {
                let e = if i == j { 1.0 } else { 0.0 };
                assert!((prod.get(i, j) - e).abs() < 1e-14);
            }
        }
    }

    #[test]
    fn tie_picks_smallest_index() {
        let a = m(&[&[1.0, 0.0], &[-1.0, 1.0]]);
        let lu = Lu::factor(&a).unwrap();
        assert_eq!(lu.perm(), &[0, 1]);
    }
}
