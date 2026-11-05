/**
 * Arbitrary-precision signed integers using base-10^9 limbs.
 *
 * Import this module to get everything:
 * ---
 * import bigint;
 * auto x = BigInt("123456789012345678901234567890");
 * writeln(x * x + 1);
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `bigint.limbs`   – low-level magnitude (unsigned) algorithms)
 *   $(LI `bigint.integer` – the signed `BigInt` type)
 *   $(LI `bigint.queries` – the line-oriented query evaluator used by the CLI)
 * )
 */
module bigint;

public import bigint.limbs;
public import bigint.integer;
public import bigint.queries;
