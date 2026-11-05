/**
 * Arbitrary-precision signed integers stored in base 10^9.
 *
 * Importing `bigint` gives access to the whole public API:
 *
 * $(UL
 *   $(LI `bigint.integer` — the `BigInt` value type,)
 *   $(LI `bigint.magnitude` — add / subtract / compare / multiply on
 *        unsigned limb arrays,)
 *   $(LI `bigint.division` — short division and Knuth's Algorithm D,)
 *   $(LI `bigint.decimal` — linear-time decimal parsing and printing.)
 * )
 */
module bigint;

public import bigint.integer;
public import bigint.magnitude;
public import bigint.division;
public import bigint.decimal;
