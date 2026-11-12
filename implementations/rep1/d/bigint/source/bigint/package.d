/**
 * Arbitrary-precision signed integer arithmetic.
 *
 * Numbers are stored as a sign and a magnitude made of base-10^9 limbs, so
 * conversion from and to decimal text is linear. All algorithms are the
 * classical ones: schoolbook multiplication, Knuth's Algorithm D for division
 * and binary exponentiation.
 *
 * Modules:
 * $(UL
 *   $(LI `bigint.bigint`     – the signed `BigInt` value type)
 *   $(LI `bigint.magnitude`  – unsigned limb-vector arithmetic)
 *   $(LI `bigint.decimal`    – decimal text <-> limb conversion)
 *   $(LI `bigint.exceptions` – exception types)
 *   $(LI `bigint.query`      – evaluator for the `<a> <op> <b>` line protocol)
 * )
 */
module bigint;

public import bigint.bigint;
public import bigint.exceptions;
public import bigint.query;
