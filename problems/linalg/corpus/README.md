# Corpus

Twelve small matrices from the HB (Harwell-Boeing) group of the SuiteSparse
Matrix Collection, kept in their original Matrix Market form. See LICENSE for
provenance and terms.

| file | size | storage | properties |
|---|---|---|---|
| `can_24.mtx` | 24x24 | coordinate pattern symmetric | mesh connectivity, indefinite, cond 7.8e1 |
| `ibm32.mtx` | 32x32 | coordinate pattern general | circuit graph, cond 4.0e2 |
| `bcsstk01.mtx` | 48x48 | coordinate real symmetric | stiffness matrix, SPD, cond 8.8e5 |
| `impcol_b.mtx` | 59x59 | coordinate real general | chemical process, cond 1.6e5 |
| `bcsstk02.mtx` | 66x66 | coordinate real symmetric | stiffness matrix, SPD, cond 4.3e3 |
| `nos4.mtx` | 100x100 | coordinate real symmetric | structural, SPD, cond 1.6e3 |
| `gre_115.mtx` | 115x115 | coordinate real general | simulated computer system, cond 5.0e1 |
| `west0132.mtx` | 132x132 | coordinate real general | chemical plant, cond 4.2e11 |
| `lund_a.mtx` | 147x147 | coordinate real symmetric | structural, SPD, cond 2.8e6 |
| `fs_183_1.mtx` | 183x183 | coordinate real general | facsimile convergence, cond 2.2e13 |
| `steam1.mtx` | 240x240 | coordinate real general | oil reservoir, cond 2.8e7 |
| `494_bus.mtx` | 494x494 | coordinate real symmetric | power network, SPD, cond 2.4e6 |

`gen_tests.py` copies these files verbatim into test inputs. It also derives a
few matrices from them, always by a documented, deterministic transformation
recorded in a comment line of the generated file:

- the symmetric part `(A + A^T)/2` of an unsymmetric matrix, used for
  eigendecomposition tests;
- a matrix plus an increasing diagonal ramp `A[i][i] += (i+1) * 1e-3 *
  max|A|`, which removes the exact component ties that a mesh matrix's
  eigenvectors otherwise have (those ties leave the sign normalisation in
  SPEC.md undetermined);
- the leading 150x150 principal submatrix of `494_bus`, so that the factors
  of a large sparse matrix stay a reasonable size on disk.
