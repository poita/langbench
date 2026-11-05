# Third-party material

langbench's own code, specifications and generated test data are MIT
(`LICENSE`). Some problems also use third-party data, listed below. Each item
is redistributed under its own licence, whose text sits next to the data in
`corpus/` and again in the problem's `tests/`, where `THIRD_PARTY.md` names
the tests that use it.

| Problem | Material | Licence |
|---|---|---|
| `problems/commonmark/` | CommonMark Spec 0.31.2 examples, by John MacFarlane (`spec_examples.json`, tests `029_spec_*` to `056_spec_*`) | CC BY-SA 4.0 |
| `problems/fulltext/` | Project Gutenberg books (Project Gutenberg's own text removed); Martin Porter's stemmer vocabulary | Public domain; free for any purpose |
| `problems/gitrepo/` | git object databases of inherits, split, itsdangerous and js-cookie | BlueOak-1.0.0; MIT; BSD-3-Clause; MIT |
| `problems/jsonschema/` | JSON Schema Test Suite; JSON Schema 2020-12 meta-schemas; OpenAPI 3.1 schema; OpenAPI example documents; SchemaStore `package.json` schema (converted to 2020-12); `package.json` manifests of axios, chalk, eslint, express and lodash | MIT; BSD-3-Clause (or AFL-3.0); Apache-2.0; CC BY 4.0; Apache-2.0; MIT |
| `problems/linalg/` | SuiteSparse Matrix Collection, group HB (some test inputs adapted) | CC BY 4.0 |
| `problems/mime/` | Apache James mime4j test messages; Ruby `mail` gem fixtures | Apache-2.0 and Artistic License (see its NOTICE); MIT |
| `problems/sitegen/` | Project Gutenberg excerpts (Aesop, Bacon, The Federalist) | Public domain |
| `problems/sqlitefile/` | Chinook sample database; OurAirports data | MIT; public domain |
| `problems/svgraster/` | Feather icons; Tabler icons; Simple Icons (brand logos, trademarks of their owners) | MIT; MIT; CC0 1.0 |
| `problems/toml/` | toml-test suite (TOML 1.0.0 cases); configuration files of serde, ripgrep, tokio, cargo, black, ruff, pydantic and uv | MIT; MIT |
| `problems/webhooks/` | octokit/webhooks payload examples; Standard Webhooks test vector; NIST CAVP SHA-256 vectors | MIT; Apache-2.0; public domain (U.S. government work) |

Some of this data names real people as its upstream publishes it: commit
authors, message senders, package maintainers and webhook actors.
