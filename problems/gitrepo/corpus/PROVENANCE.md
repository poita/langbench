# Corpus provenance

Every directory here is a git object database (a stripped `.git`). `gen_tests.py`
copies one of them into each test case as `input/repo`. Hooks, reflogs, the
index, `objects/info/`, pack `.rev` files and the clone's remote configuration
were removed; `config` was replaced with a minimal bare-repository config.

## Cloned from public projects

| directory | upstream | licence | shape |
|---|---|---|---|
| `inherits-packed` | https://github.com/isaacs/inherits | Blue Oak Model License 1.0.0 (`licenses/inherits-LICENSE.md`) | one pack, OFS_DELTA, `packed-refs` |
| `inherits-loose` | same | same | every object exploded to a loose file, loose refs |
| `split-refdelta` | https://github.com/dominictarr/split | MIT (`licenses/split-LICENCE.txt`) | one pack repacked with `repack.useDeltaBaseOffset=false`, so all deltas are REF_DELTA |
| `split-multipack` | same | same | two packs (one OFS_DELTA, one REF_DELTA) plus loose objects, loose refs |
| `itsdangerous` | https://github.com/pallets/itsdangerous | BSD-3-Clause (`licenses/itsdangerous-LICENSE.txt`) | 677 commits, 241 merges, 32 tags, gpg-signed commits |
| `jscookie` | https://github.com/js-cookie/js-cookie | MIT (`licenses/jscookie-LICENSE.txt`) | 1062 commits, 67 merges, 39 tags |

## Built with git plumbing

`make_corpus.py` builds these at fixed timestamps, so their object ids are
stable.

| directory | shape |
|---|---|
| `synth-basic-loose` | 33 commits including a merge, loose objects and loose refs. Carries `refs/remotes/origin/HEAD` (a symref, for the `refs/remotes/<name>/HEAD` lookup rule) and a `refs/heads/v0.1` that shares its name with `refs/tags/v0.1`, so the order of the ref lookup rules is observable. Carries a symlink, an executable file, a gitlink, an empty blob, a binary blob, and names needing C-style quoting (non-ASCII, a tab, a quote and a backslash). Commit messages cover folded subjects, leading blank lines, trailing whitespace and an empty message. |
| `synth-basic-packed` | the same objects repacked with OFS_DELTA, refs packed into `packed-refs` |
| `synth-basic-refdelta` | the same objects repacked with REF_DELTA |
| `synth-basic-mixed` | part of the history packed, the rest loose, refs loose |
| `synth-quirks` | the cases an ordinary history never reaches: a merge over three commits that share one committer date (so the log walk's tie-break is observable), one commit that touches every path needing C-style quoting at once (so `diff` line order by raw path bytes is observable), names holding 0x01 and 0x7f, and a branch of commit messages covering the subject's whitespace rules |
| `synth-detached` | two commits, `HEAD` holding a raw object id |
| `synth-empty` | `HEAD` pointing at a branch that does not exist, no objects |
| `synth-corrupt` | a two-file repository plus two damaged loose objects: one whose content does not hash to its file name, one whose compressed stream is broken |
