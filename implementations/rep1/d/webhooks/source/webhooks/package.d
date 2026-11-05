/**
 * webhooks: SHA-256, HMAC-SHA-256, Base64, the Standard Webhooks signature
 * scheme and a deterministic delivery simulator, all implemented from scratch.
 *
 * Import `webhooks` to get the whole public API:
 *
 * $(UL
 *   $(LI `webhooks.sha256`: incremental SHA-256)
 *   $(LI `webhooks.hmac`: HMAC-SHA-256 with precomputed keys)
 *   $(LI `webhooks.base64`: standard / URL-safe Base64 and the lenient decoder)
 *   $(LI `webhooks.hex`: lowercase hex helpers)
 *   $(LI `webhooks.signature`: secrets, signing, verification)
 *   $(LI `webhooks.simulator`, `webhooks.simparse`: the delivery simulator)
 *   $(LI `webhooks.commands`: the stdin command-stream interpreter)
 * )
 */
module webhooks;

public import webhooks.base64;
public import webhooks.buffer;
public import webhooks.commands;
public import webhooks.grammar;
public import webhooks.heap;
public import webhooks.hex;
public import webhooks.hmac;
public import webhooks.sha256;
public import webhooks.signature;
public import webhooks.simparse;
public import webhooks.simulator;
