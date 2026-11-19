# revision-backend-jj

[revision-protocol](https://github.com/egao1980/revision-protocol) backend over the **jj (Jujutsu) CLI** (no jj-lib), for [cl-stack](https://github.com/egao1980/cl-stack) (`stack-rev-jj`).

Capability brief: [`cl-stack/docs/capabilities/revision-backend-jj.md`](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/revision-backend-jj.md) · plan: [HARNESS-PLAN.md](https://github.com/egao1980/cl-workspace/blob/main/docs/HARNESS-PLAN.md) Track V · sibling: [revision-backend-git](https://github.com/egao1980/revision-backend-git).

Version **0.1.0** — milestone V2: a [revision-protocol](https://github.com/egao1980/revision-protocol) store, working copy and read-only revision filesystem over the **jj (Jujutsu) CLI** (minimum jj 0.47.1; no jj-lib). Revision ids are change ids (commit ids for divergent changes); refs are bookmarks and tags with CAS emulated through operation ids; conflicted revisions are first-class. Requires process-protocol 0.3.0 / process-backend-uiop 0.2.0.

## V2 surface (= revision-backend-git V0)

- **`jj-store`** (a `revision-store`): `make-jj-store path &key jj env permit-force`. Revisions are jj changes: `revision-id` = change id (commit id for a divergent change), commit id in `revision-content` and provenance; recorded-at = committer timestamp, valid-at = author timestamp. A change id follows rewrites of a mutable change; commit ids and `revision` objects pin one snapshot. Refs: local bookmarks `:movable`, tags `:tag`; `:ref-cas` is NIL — CAS is serialized in the image and checked against the operation log across processes (divergence → `ref-conflict`). `rev-as-of :recorded` reads the operation log (`--at-op`). Graph walks through revsets; `state-diff` through `jj diff --git` → `parse-diff :unified`.
- **Conflicts** (`:conflicted-revisions` T): a conflicted file is a file holding jj's materialized conflict (`ui.conflict-marker-style=diff`); `revision-conflicts`, `conflicted-bookmarks`.
- **`jj-working-copy`** (a `revision-target`): @ is a commit; stamp = @'s parents; drift = @'s own changes after a snapshot; `capture-revision` = `jj commit` (files never touched).
- **`revision-filesystem`**: read-only [cl-stack-pathlib](https://github.com/egao1980/cl-stack-pathlib) filesystem over one commit.
- **`run-jj`**, `current-operation`, `list-operations`, `jj-capabilities`; the `-T` templates the backend runs (`*commit-template*` …) and their parsers.
- **Conditions:** the protocol's own plus `vc-tool-version-error` (tool / found / required; moves to revision-protocol, [#4](https://github.com/egao1980/revision-protocol/issues/4)) and `jj-command-error` (command / exit-code / stderr).

Reads run with `--ignore-working-copy`; every command gets `--no-pager --color=never --quiet` and fixed `--config` layers (conflict markers, diff format, no EOL conversion).

**jj ≥ 0.47.1** (`*minimum-jj-version*`), the release CI installs from the official binaries on every runner. Older jj signals `vc-tool-version-error` from `make-jj-store`.

```lisp
(let ((s (stack-rev-jj:make-jj-store #p"/path/to/repo/")))
  (stack-rev:walk-revisions s (stack-rev:rev-ref "main") :order :first-parent)
  (stack-rev:state-diff s "main-" "main" :level :summary))
```

## Tests

```sh
cl-repo test --system revision-backend-jj   # needs jj 0.47.1+ on PATH
```

## License

MIT
