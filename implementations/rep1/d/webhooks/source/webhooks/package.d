/**
 * webhooks: SHA-256, HMAC-SHA-256 and Base64 written from scratch, the
 * Standard Webhooks signature scheme on top of them, and a deterministic
 * webhook delivery simulator.
 *
 * Import `webhooks` to get the whole public API, or import the individual
 * modules:
 *
 * $(TABLE
 *   $(TR $(TD `webhooks.sha256`)    $(TD SHA-256 (FIPS 180-4)))
 *   $(TR $(TD `webhooks.hmac`)      $(TD HMAC-SHA-256 (RFC 2104)))
 *   $(TR $(TD `webhooks.base64`)    $(TD Base64 encode/decode, standard and URL-safe))
 *   $(TR $(TD `webhooks.hex`)       $(TD hex helpers and the `<hex>` field encoding))
 *   $(TR $(TD `webhooks.secret`)    $(TD `whsec_` secrets))
 *   $(TR $(TD `webhooks.signature`) $(TD signing and verification))
 *   $(TR $(TD `webhooks.heap`)      $(TD binary min-heap))
 *   $(TR $(TD `webhooks.simulator`) $(TD retry/delivery simulation))
 *   $(TR $(TD `webhooks.fields`)    $(TD protocol argument validation))
 *   $(TR $(TD `webhooks.blockparser`) $(TD the `simulate` block reader))
 *   $(TR $(TD `webhooks.protocol`)  $(TD the command interpreter)))
 */
module webhooks;

public import webhooks.base64;
public import webhooks.blockparser;
public import webhooks.fields;
public import webhooks.heap;
public import webhooks.hex;
public import webhooks.hmac;
public import webhooks.protocol;
public import webhooks.secret;
public import webhooks.sha256;
public import webhooks.signature;
public import webhooks.simulator;
