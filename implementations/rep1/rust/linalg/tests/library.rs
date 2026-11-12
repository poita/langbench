//! Property-style tests of the public library API on a deterministic
//! pseudo-random matrix family.

use linalg::{chol, eig, lu, qr, svd, LinalgError, Matrix};

/// Tiny xorshift generator so the tests need no dependencies.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> f64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
    }
    fn matrix(&mut self, r: usize, c: usize) -> Matrix {
        Matrix::from_vec(r, c, (0..r * c).map(|_| self.next()).collect())
    }
}

fn max_diff(a: &Matrix, b: &Matrix) -> f64 {
    assert_eq!((a.rows(), a.cols()), (b.rows(), b.cols()));
    a.as_slice().iter().zip(b.as_slice()).map(|(x, y)| (x - y).abs()).fold(0.0, f64::max)
}

fn diag(v: &[f64]) -> Matrix {
    let n = v.len();
    let mut d = Matrix::zeros(n, n);
    for (i, x) in v.iter().enumerate() {
        d.set(i, i, *x);
    }
    d
}

#[test]
fn lu_reconstructs() {
    let mut rng = Rng(1);
    for n in [1, 2, 5, 17, 40] {
        let a = rng.matrix(n, n);
        let f = lu::Lu::factor(&a).unwrap();
        assert!(max_diff(&f.p().mul(&a).unwrap(), &f.l().mul(&f.u()).unwrap()) < 1e-12);
        assert!(f.l().as_slice().iter().all(|x| x.abs() <= 1.0));
    }
}

#[test]
fn solve_and_inverse() {
    let mut rng = Rng(2);
    let a = rng.matrix(12, 12);
    let b = rng.matrix(12, 3);
    let x = lu::solve(&a, &b).unwrap();
    assert!(max_diff(&a.mul(&x).unwrap(), &b) < 1e-9);
    let inv = lu::inverse(&a).unwrap();
    assert!(max_diff(&a.mul(&inv).unwrap(), &Matrix::identity(12)) < 1e-9);
}

#[test]
fn qr_and_lstsq() {
    let mut rng = Rng(3);
    let a = rng.matrix(20, 6);
    let f = qr::qr(&a).unwrap();
    assert!(max_diff(&f.q.mul(&f.r).unwrap(), &a) < 1e-12);
    assert!(max_diff(&f.q.transpose().mul(&f.q).unwrap(), &Matrix::identity(6)) < 1e-13);
    // Normal equations hold at the least-squares minimiser: Aᵀ(AX − B) = 0.
    let b = rng.matrix(20, 2);
    let x = qr::lstsq(&a, &b).unwrap();
    let resid = a.mul(&x).unwrap();
    let mut diff = Matrix::zeros(20, 2);
    for i in 0..20 {
        for j in 0..2 {
            diff.set(i, j, resid.get(i, j) - b.get(i, j));
        }
    }
    let grad = a.transpose().mul(&diff).unwrap();
    assert!(grad.as_slice().iter().all(|g| g.abs() < 1e-12));
}

#[test]
fn cholesky_of_gram_matrix() {
    let mut rng = Rng(4);
    let g = rng.matrix(15, 8);
    let a = g.transpose().mul(&g).unwrap();
    let l = chol::cholesky(&a).unwrap();
    assert!(max_diff(&l.mul(&l.transpose()).unwrap(), &a) < 1e-12);
}

#[test]
fn eigen_and_svd() {
    let mut rng = Rng(5);
    let g = rng.matrix(9, 9);
    let a = g.add(&g.transpose()).unwrap();
    let e = eig::eigh(&a).unwrap();
    let rebuilt = e.vectors.mul(&diag(&e.values)).unwrap().mul(&e.vectors.transpose()).unwrap();
    assert!(max_diff(&rebuilt, &a) < 1e-12);

    for (m, n) in [(8, 5), (5, 8), (6, 6)] {
        let a = rng.matrix(m, n);
        let f = svd::svd(&a);
        let rebuilt = f.u.mul(&diag(&f.s)).unwrap().mul(&f.v.transpose()).unwrap();
        assert!(max_diff(&rebuilt, &a) < 1e-12);
        assert!(svd::cond(&a).unwrap() >= 1.0);
    }
}

#[test]
fn error_precedence() {
    let wide = Matrix::zeros(2, 3);
    let col = Matrix::zeros(3, 1);
    assert_eq!(lu::solve(&wide, &col).unwrap_err(), LinalgError::NotSquare);
    assert_eq!(chol::cholesky(&wide).unwrap_err(), LinalgError::NotSquare);
    let ns = Matrix::from_rows(&[vec![0.0, 1.0], vec![0.0, 0.0]]);
    assert_eq!(eig::eigh(&ns).unwrap_err(), LinalgError::NotSymmetric);
    assert_eq!(LinalgError::Singular.code(), "singular");
}
