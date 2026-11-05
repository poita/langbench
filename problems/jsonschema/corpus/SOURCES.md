# Vendored corpora

All material here is redistributed under the licence named with it. Files are
byte-identical to the upstream sources except where noted.

## `json-schema-test-suite/`

The official JSON Schema Test Suite, <https://github.com/json-schema-org/JSON-Schema-Test-Suite>,
fetched 2026-09-21. MIT licence (`LICENSE`).

- `tests/draft2020-12/*.json` — the draft 2020-12 test files, excluding the
  `optional/` subdirectory.
- `remotes/` — the documents the suite serves from `http://localhost:1234/`,
  excluding the `draft3`, `draft4`, `draft6`, `draft7`, `draft2019-09` and
  `v1` subtrees, which no draft 2020-12 test references.

## `metaschema/`

The draft 2020-12 meta-schema and its vocabulary meta-schemas, published by the
JSON Schema organisation at `https://json-schema.org/draft/2020-12/…` from
<https://github.com/json-schema-org/json-schema-spec>, which licenses them under
the BSD 3-clause licence or the Academic Free License 3.0 (`metaschema/LICENSE`,
upstream's licence file); they are redistributed here under BSD-3-Clause. The
copies were taken from the `jsonschema-specifications` Python package
(<https://github.com/python-jsonschema/jsonschema-specifications>), which
redistributes them verbatim.

| file | URI |
| --- | --- |
| `schema.json` | `https://json-schema.org/draft/2020-12/schema` |
| `core.json` | `https://json-schema.org/draft/2020-12/meta/core` |
| `applicator.json` | `https://json-schema.org/draft/2020-12/meta/applicator` |
| `unevaluated.json` | `https://json-schema.org/draft/2020-12/meta/unevaluated` |
| `validation.json` | `https://json-schema.org/draft/2020-12/meta/validation` |
| `meta-data.json` | `https://json-schema.org/draft/2020-12/meta/meta-data` |
| `format-annotation.json` | `https://json-schema.org/draft/2020-12/meta/format-annotation` |
| `format-assertion.json` | `https://json-schema.org/draft/2020-12/meta/format-assertion` |
| `content.json` | `https://json-schema.org/draft/2020-12/meta/content` |

## `openapi/`

- `oas31-schema.json` — the OpenAPI 3.1 document schema, fetched from
  <https://spec.openapis.org/oas/3.1/schema/2022-10-07>. It is itself a JSON
  Schema 2020-12 document (Apache-2.0, `LICENSE-Apache-2.0.txt`, from the
  OpenAPI Initiative).
- `examples/v3.*.json` — the OpenAPI example documents from
  <https://github.com/OAI/learn.openapis.org> (`examples/v3.0`, `examples/v3.1`),
  CC-BY-4.0 (`examples/LICENSE-CC-BY-4.0.txt`), © the OpenAPI Initiative.
  `gen_tests.py` uses the 3.1 documents as they are and derives 3.1 documents
  from the 3.0 ones by replacing the `openapi` version string.

## `npm/`

- `package-draft07.json` — the `package.json` schema from SchemaStore,
  <https://json.schemastore.org/package.json> (Apache-2.0,
  `LICENSE-SchemaStore-Apache-2.0.txt`). It is written for draft-07;
  `gen_tests.py` converts it to draft 2020-12 mechanically (see that script).
  The converted schema in tests 410 and 411 is therefore a modified version of
  the SchemaStore file.
- `instances/*.json` — the `package.json` manifests of five widely used npm
  packages, each taken from its project's repository:

  | file | repository | licence |
  | --- | --- | --- |
  | `axios.json` | <https://github.com/axios/axios> (branch `v1.x`) | MIT (`LICENSE-axios-MIT.txt`) |
  | `chalk.json` | <https://github.com/chalk/chalk> | MIT (`LICENSE-chalk-MIT.txt`) |
  | `eslint.json` | <https://github.com/eslint/eslint> | MIT (`LICENSE-eslint-MIT.txt`) |
  | `express.json` | <https://github.com/expressjs/express> | MIT (`LICENSE-express-MIT.txt`) |
  | `lodash.json` | <https://github.com/lodash/lodash> | MIT (`LICENSE-lodash-MIT.txt`) |

  The licence texts are those published with each package version on npm.
