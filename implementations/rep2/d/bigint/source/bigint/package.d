/**
 * Arbitrary-precision integer arithmetic.
 *
 * Import `bigint` to get everything:
 * ---
 * import bigint;
 *
 * auto x = BigInt("123456789012345678901234567890");
 * auto y = x * x - BigInt(1);
 * writeln(y / x, " rem ", y % x);
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `bigint.bigint`: the signed `BigInt` type and `divMod`/`pow`.)
 *   $(LI `bigint.natural`: unsigned limb-array algorithms (add, sub, mul, Knuth division, pow).)
 *   $(LI `bigint.decimal`: linear-time decimal parsing and printing.)
 *   $(LI `bigint.query`: the `<a> <op> <b>` query evaluator used by the CLI.)
 * )
 */
module bigint;

public import bigint.bigint;
public import bigint.decimal : ParseException;
public import bigint.query : evaluate, evaluateAll;
