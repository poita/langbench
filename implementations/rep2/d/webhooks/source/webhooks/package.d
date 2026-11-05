/**
 * Standard Webhooks signing and verification, plus a deterministic delivery
 * simulator, with SHA-256, HMAC-SHA-256 and Base64 written from scratch.
 *
 * Modules:
 * $(UL
 *   $(LI `webhooks.sha256`    – incremental SHA-256)
 *   $(LI `webhooks.hmac`      – HMAC-SHA-256 with precomputed keys)
 *   $(LI `webhooks.base64`    – standard / URL-safe Base64)
 *   $(LI `webhooks.hex`       – protocol hex arguments)
 *   $(LI `webhooks.secret`    – `whsec_` secrets)
 *   $(LI `webhooks.signature` – signing and verification)
 *   $(LI `webhooks.simulator` – retry/delivery simulator)
 *   $(LI `webhooks.commands`  – the stdin command protocol)
 * )
 */
module webhooks;

public import webhooks.base64;
public import webhooks.commands;
public import webhooks.hex;
public import webhooks.hmac;
public import webhooks.outbuf;
public import webhooks.secret;
public import webhooks.sha256;
public import webhooks.signature;
public import webhooks.simparse;
public import webhooks.simulator;
