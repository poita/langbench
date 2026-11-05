# jsonschema performance inputs

Regenerate with `python3 problems/jsonschema/bench/gen_bench.py` (fixed seeds,
independent of PYTHONHASHSEED). Expected outputs come from `reference/main.py`
(3 s, 8 s and 3 s). SPEC.md caps inputs at 2 MB, so each input is about 1.95 MB of
compact JSON. At that size the fast compiled implementations take only 0.06-0.5 s,
so time each input over several runs.

- `001_npm_manifests_throughput`: the SchemaStore package.json schema (the one used by
  tests 410/411) over 927 synthetic npm manifests, about 11% of them with one realistic
  mistake. This measures throughput: many medium-sized ordinary documents, `$ref` into
  `$defs`, `oneOf`-heavy `exports`, `patternProperties` and string checks on dependency maps.
- `002_openapi31_documents_full_schema_dialect`: 25 OpenAPI 3.1 documents (the 9 corpus
  examples upgraded to 3.1, plus 16 large synthetic APIs, about 20% broken). The schema
  is equivalent to the official OAS "schema-base" document. It redefines the `meta`
  dynamic anchor as the 2020-12 meta-schema, so every Schema Object is meta-validated
  through `$dynamicRef`, `allOf` over the vocabularies, and `unevaluatedProperties`. This
  is the algorithmically hardest path: dynamic scope, deep references and annotation
  collection.
- `003_order_records_mixed_keywords`: 1204 e-commerce order records (about 15% broken)
  against a hand-written schema that uses most keywords. It covers many anchored regexes
  (timestamps, SKUs, IBANs, postcodes), exact-decimal `multipleOf` (0.01, 0.0001, 0.001),
  `uniqueItems`, `oneOf`, `if`/`then`/`else`, `dependentRequired`/`dependentSchemas`,
  `contains`/`maxContains`, a remote `$ref` and `unevaluatedProperties`. This is a mixed
  realistic API-validation workload.

## Long tier

`python3 gen_bench.py --long` writes `../bench-long/` (same names; expected outputs from
`reference/main.py`, about 3 minutes). SPEC.md's input limit is raised from 2 MB to 32 MB
for this tier. Each input is the same schema with 16x the instances: 15,251 npm
manifests, 293 OpenAPI 3.1 documents, and 19,685 order records (the same generators and
breakage rates).

Validation is linear in the instance bytes, so this problem is bound by its input size:
5 s would need roughly 300-700 MB of JSON per input. The long tier does **not** reach
the 5 s target: the fastest build (Rust) takes 0.21 s, 0.47 s and 0.31 s (C++ 0.29,
0.54, 0.36; CPU seconds normalised to a lightly loaded machine). Peak RSS of the
compiled builds is up to 488 MB (C++), since each input is one 32 MB JSON document.
Size on disk 91 MB.
