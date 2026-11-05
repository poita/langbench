# Third-party data in these tests

The repositories in these tests are object databases cloned from public
projects, redistributed under each project's licence:

| tests | project | licence |
|---|---|---|
| `023_inherits_*` to `025_inherits_*` | <https://github.com/isaacs/inherits> | Blue Oak Model License 1.0.0 (`LICENSE-inherits.md`); earlier revisions in its history carry their own permissive licences |
| `026_split_*` to `028_split_*` | <https://github.com/dominictarr/split> | MIT (`LICENSE-split.txt`) |
| `029_itsdangerous_*`, `030_itsdangerous_*` | <https://github.com/pallets/itsdangerous> | BSD-3-Clause (`LICENSE-itsdangerous.txt`) |
| `031_jscookie_*`, `032_jscookie_*` | <https://github.com/js-cookie/js-cookie> | MIT (`LICENSE-jscookie.txt`) |

Commit metadata names the projects' contributors as published upstream.
Every other repository is built by this project's `make_corpus.py`.
