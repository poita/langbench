# Vendored corpora

## `nist-sha256/`

NIST CAVP SHA test vectors, byte-oriented, extracted from
<https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabytetestvectors.zip>.
Only the SHA-256 files are kept (`SHA256ShortMsg.rsp`, `SHA256LongMsg.rsp`)
together with the archive's `Readme.txt`. Work of the U.S. federal government,
not subject to copyright in the United States (public domain).

Each `.rsp` file is a list of records:

```
Len = <message length in bits>
Msg = <message bytes in hex; the single byte 00 when Len = 0>
MD = <expected SHA-256 digest in hex>
```

## `github-webhooks/`

Webhook payload examples from <https://github.com/octokit/webhooks>, directory
`payload-examples/api.github.com`. 255 real GitHub webhook request bodies.
MIT licence, see `github-webhooks/LICENSE`.

## `LICENSE.standard-webhooks`

Apache Licence 2.0 of <https://github.com/standard-webhooks/standard-webhooks>,
whose specification this problem implements and whose published test vector
(`whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw` / `msg_p5jXN8AQM9LWM0D4loKWxJek`)
appears in `tests/003_spec_vector.in`.
