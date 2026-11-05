# Vendored corpora

| directory | project | version | licence |
|---|---|---|---|
| `feather/` | [Feather icons](https://github.com/feathericons/feather) | v4.29.2 | MIT (`LICENSE`) |
| `tabler-outline/`, `tabler-filled/` | [Tabler icons](https://github.com/tabler/tabler-icons) | npm `@tabler/icons` 3.31.0 | MIT (`LICENSE`) |
| `simple-icons/` | [Simple Icons](https://github.com/simple-icons/simple-icons) | npm `simple-icons` 13.21.0 | CC0 1.0 (`LICENSE.md`) |

Each directory holds a deterministic subset of the upstream icons, copied
verbatim. The Simple Icons subset contains only icons that upstream releases
under CC0; it leaves out the few that carry their own licences. `gen_tests.py` slices these pools into test inputs; it never edits
the files.

Feather and Tabler icons are stroke drawings (`fill="none"`,
`stroke="currentColor"`, round caps and joins), so they exercise the stroke
outliner. Simple Icons are single filled paths with long, dense curve data,
so they exercise the path parser and the scan converter. The eight largest
Simple Icons files are used at 256x256 as the heaviest cases.

## Trademarks

Simple Icons are brand logos. Each logo is a trademark of its owner, and its
inclusion here implies no endorsement or affiliation. They are used only as
rendering test data. See the Simple Icons
[disclaimer](https://github.com/simple-icons/simple-icons/blob/develop/DISCLAIMER.md).
