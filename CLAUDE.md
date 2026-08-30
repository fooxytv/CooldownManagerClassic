# CooldownManagerClassic

## Branching: always work from `develop`

`develop` is the integration branch. **Base every branch on `origin/develop`
and open every pull request against `develop`** — never `main`.

`main` is release-only: it receives `release/x.y.z` branches, and nothing else.
Basing work on `main` means basing it on the last release rather than on what
has landed since, so the branch misses everything merged to `develop` in
between.

```sh
git fetch origin develop
git checkout -b <branch> origin/develop
```

The clone a session starts from may be on `main`, and `origin/develop` is not
always fetched by default — fetch it explicitly before branching or comparing,
rather than assuming the local view is complete.

If a branch was started from `main` by mistake, rebase it across before opening
the pull request, so the PR carries only its own commits rather than the release
merges that separate `main` from `develop`:

```sh
git rebase --onto origin/develop <commit-before-your-first> <branch>
```

Rebasing across is not a formality — `develop` may have changed the very APIs
the work is built on, and conflicts that git merges cleanly can still be
behavioural.

## Never call a WoW API directly

`core/Compat.lua` owns every client call and picks between the modern `C_*`
namespaces and the legacy globals. Calling a WoW function straight from feature
code works on whichever flavour you happen to be thinking about and silently
does nothing on the others — the failure is a missing icon, not an error.

`.luacheckrc` is the allowlist, not decoration: `ci/scripts/check_globals.py`
parses its `globals` / `read_globals` tables and fails on anything not listed.
A new API goes in there, with the call itself wrapped in Compat. Do not silence
the diagnostic — it exists because `GetSepllInfo` once reached a release.

## One codebase, several flavours

`Compat.flavor` resolves to `era`, `tbc`, `wrath`, `cata`, `mop`, `retail` or
`unknown`; three of those ship, one `.toc` each for Era, TBC and MoP, with an
identical file list. `Compat.GetProfileFlavor()` returns `sod` instead of `era`
when Season of Discovery is detected, and SoD-only behaviour gates on
`Compat.isSoD` (Era plus `C_Engraving`, so it is false everywhere else).

Era and TBC run the legacy API paths; MoP runs the modern ones. Anything
touching a client API needs a thought for both halves — the smoke test runs the
whole suite under each.

## Appearance keys round-trip for free

`WriteAppearance` in `core/Serialization.lua` walks `pairs(appearance)` and
sorts the keys rather than writing a fixed list, so a new appearance key
survives export/import and a profile switch with no serialisation work, and the
exported string stays byte-stable. Worth knowing before hand-writing any.

## Line endings: the tracked files are CRLF

`.lua`, `.py`, `.md` and `.gitignore` are all stored with CRLF. Only `*.sh` is
pinned to LF, by `.gitattributes`.

Editing a file with a script that reads and rewrites the whole thing will
normalise it to LF and show up as every line changed — a one-line edit becomes a
2,000-line diff. Convert back before committing, and check `git diff --stat`
looks the size the change actually was:

```sh
python3 -c "
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_bytes(p.read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
" <file>
```

## CI gates

Three, all runnable locally and all run in CI on every push:

```sh
bash ci/scripts/lint.sh          # luacheck; needs `luarocks install luacheck`
python3 ci/scripts/check_globals.py
python3 ci/tests/smoke_test.py   # needs `pip install lupa luaparser`
```

`.luacheckrc` excludes `ci/**`, so test-harness Lua is not linted. The smoke
test runs in about 150ms and loads every file in the `.toc` in order, so a new
file is covered as soon as it is packaged.
