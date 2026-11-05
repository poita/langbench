/**
 * Arbitrary-precision signed integer arithmetic.
 *
 * Public entry points:
 *  - `bigint.integer.BigInt`: the signed integer type with operators.
 *  - `bigint.queries.evaluateQueries`: the line-oriented calculator used by the CLI.
 *  - `bigint.magnitude`: the unsigned limb-array kernels (add, sub, mul, divmod).
 *  - `bigint.decimal`: linear-time decimal parsing and printing.
 */
module bigint;

public import bigint.integer;
public import bigint.queries;
