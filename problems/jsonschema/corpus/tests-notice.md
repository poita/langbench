# Third-party data in these tests

| tests | source | licence |
|---|---|---|
| `026_*` to `406_*` | the official JSON Schema Test Suite, draft 2020-12 (<https://github.com/json-schema-org/JSON-Schema-Test-Suite>), one test per schema group, with the suite's remote documents | MIT (`LICENSE-json-schema-test-suite.txt`) |
| `412_*`, `413_*`, and every test that loads the 2020-12 meta-schemas | the meta-schemas of <https://github.com/json-schema-org/json-schema-spec> | BSD-3-Clause, or AFL-3.0 (`LICENSE-json-schema-spec.txt`) |
| `407_*` to `409_*` | the OpenAPI 3.1 schema (<https://spec.openapis.org/oas/3.1/schema/2022-10-07>) | Apache-2.0 (`LICENSE-openapi-schema-Apache-2.0.txt`) |
| `407_*`, `408_*` | OpenAPI example documents from <https://github.com/OAI/learn.openapis.org>, © the OpenAPI Initiative; those in `408_*` are adapted from the 3.0 examples by changing their `openapi` version to 3.1 | CC BY 4.0 (`LICENSE-openapi-examples-CC-BY-4.0.txt`) |
| `410_*`, `411_*` | the SchemaStore `package.json` schema (<https://json.schemastore.org/package.json>), modified: converted from draft-07 to draft 2020-12 by `gen_tests.py` | Apache-2.0 (`LICENSE-SchemaStore-Apache-2.0.txt`) |
| `410_*` | the `package.json` manifests of axios, chalk, eslint, express and lodash | MIT (`LICENSE-npm-axios-MIT.txt`, `LICENSE-npm-chalk-MIT.txt`, `LICENSE-npm-eslint-MIT.txt`, `LICENSE-npm-express-MIT.txt`, `LICENSE-npm-lodash-MIT.txt`) |

Tests `001_*` to `025_*` and the negative cases built around these documents
are written by this project.
