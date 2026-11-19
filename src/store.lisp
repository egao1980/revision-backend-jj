(in-package #:revision-backend-jj)

;;; ------------------------------------------------------------------
;;; REVISION-PROTOCOL methods on JJ-STORE (V2: graph, refs, content — the
;;; surface of revision-backend-git V0). jj-specific behaviour, beyond the
;;; protocol docstrings:
;;;
;;; How commands run — reads of the repository use --ignore-working-copy
;;;   (they never snapshot the working copy or touch the disk). Ref writes run
;;;   with --at-op OP, OP being the operation their CAS check read (see Refs);
;;;   that also means no snapshot. Working-copy operations (src/working-copy.
;;;   lisp) snapshot first. COMMIT-REVISION writes content through a
;;;   temporary workspace; creating it (`jj workspace add`, which jj refuses
;;;   to run with --ignore-working-copy) snapshots the store's working copy
;;;   like any jj write, but nothing moves @ or touches a file of the store's
;;;   workspace. No operation passes --ignore-immutable.
;;;
;;; Revisions — visible jj commits other than the root commit. REVISION-ID is
;;;   the full change id, except for a divergent change (several visible
;;;   commits with one change id), where each commit's id is its full commit
;;;   id. REVISION-PARENT-IDS: the parents' revision ids in commit order,
;;;   without the root commit (a change on root() has no parents).
;;;   REVISION-RECORDED-AT = committer timestamp, REVISION-VALID-AT = author
;;;   timestamp (DATETIME-PROTOCOL instants, whole seconds; jj keeps the
;;;   author timestamp across rewrites and moves the committer one).
;;;   REVISION-MESSAGE = the description without one final newline ("" when
;;;   there is none). REVISION-CONTENT = the commit id. REVISION-PROVENANCE =
;;;   (:COMMIT-ID id :AUTHOR-NAME s :AUTHOR-EMAIL s :COMMITTER-NAME s
;;;   :COMMITTER-EMAIL s :CONFLICT bool :EMPTY bool) — facts of the commit
;;;   only (nothing that changes when other operations run).
;;;   The root commit (change zzzz…, commit 000…) is not a revision: every
;;;   designator naming it signals REVISION-NOT-FOUND.
;;;
;;; Rewrites and immutable revisions — a change id names the change's
;;;   CURRENT visible commit; jj rewrites mutable commits (describe, squash,
;;;   rebase, snapshots of @), so resolving a mutable change id later may give
;;;   a revision with the same id and a different :COMMIT-ID, message or
;;;   state. What never changes:
;;;     - a REVISION value (no writers; lists are fresh copies);
;;;     - a commit id designator and a REVISION object used as a designator:
;;;       they name that exact commit, visible or hidden (a rewritten commit
;;;       stays readable by commit id), with the same fields;
;;;     - the change id of a revision jj treats as immutable
;;;       (`::immutable_heads()`, by default trunk(), tags and untracked
;;;       remote bookmarks): jj refuses to rewrite it and this backend never
;;;       asks it to.
;;;   The backend itself rewrites nothing but the working-copy commit
;;;   (snapshots, TARGET-STAMP, CAPTURE-REVISION). TAG-REVISION makes its
;;;   target immutable (tags() is in jj's default immutable_heads()).
;;;
;;; RESOLVE-REVISION — a string designator is tried, in order, as
;;;   1. a full change id (32 letters k–z) of a visible change → its commit;
;;;      divergent → AMBIGUOUS-REVISION, CANDIDATES the commit ids;
;;;   2. a full commit id (lowercase hex) → that commit, visible or hidden;
;;;   3. a prefix of at least REV:+MINIMUM-ID-PREFIX+ characters of change ids
;;;      (k–z) or commit ids (hex) of visible commits: one → it; several →
;;;      AMBIGUOUS-REVISION with every matching full change id (a change prefix)
;;;      or full commit id (a commit prefix) as CANDIDATES (jj
;;;      itself only reports that a prefix is ambiguous, so the candidates
;;;      come from listing the visible ids);
;;;   4. a jj revset, evaluated at the current operation: exactly one visible
;;;      non-root commit → it; several → AMBIGUOUS-REVISION (CANDIDATES their
;;;      revision ids); none, only the root, or a revset jj rejects (syntax,
;;;      unknown symbol) → REVISION-NOT-FOUND. ("@", "@-", "main",
;;;      "main-", "description(exact:\"x\\n\")".)
;;;   REV-REF NAME: the tag NAME when one exists, else the local bookmark NAME
;;;   (jj's own symbol rule: tags first); a conflicted bookmark →
;;;   AMBIGUOUS-REVISION with its targets' revision ids. REV-TAG: tags only.
;;;   REV-PARENT / REV-ANCESTOR count parents as REVISION-PARENT-IDS does.
;;;   REV-AS-OF: see below.
;;;
;;; Refs — :MOVABLE = local bookmarks, :TAG = local tags; REF-TARGET is the
;;;   target's revision id (a bookmark follows its change through rewrites).
;;;   REF-ANNOTATION is always NIL (jj tags carry no message). When a
;;;   bookmark and a tag share a name, FIND-REF and REV-REF pick the tag;
;;;   LIST-REFS lists both, the bookmark first; MOVE-REF / DELETE-REF /
;;;   COMMIT-REVISION :REF on a name that is a tag → TAG-IMMUTABLE.
;;;   A conflicted bookmark (concurrent operations moved it apart) is not a
;;;   REVISION-REF: LIST-REFS leaves it out, CONFLICTED-BOOKMARKS lists it,
;;;   FIND-REF signals REF-CONFLICT (expected NIL, ACTUAL the list of its
;;;   targets' revision ids sorted STRING<) with restart USE-CURRENT →
;;;   FIND-REF returns NIL.
;;;
;;; CAS (:REF-CAS NIL, emulated) — MOVE-REF, DELETE-REF, COMMIT-REVISION
;;;   :REF and TAG-REVISION take the store's lock, read the current
;;;   operation OP and the ref at OP, check EXPECTED against it (revision
;;;   ids: a rewrite of the expected change still matches), then write with
;;;   `jj --at-op OP bookmark set NAME -r COMMIT --allow-backwards` (or
;;;   `bookmark delete`, `tag set`). Inside one image this is linearizable.
;;;   Another jj process that wrote in between makes jj reconcile the two
;;;   operations; the backend re-reads the ref afterwards and, unless it
;;;   now names exactly the new target, signals REF-CONFLICT with ACTUAL the
;;;   ref's target now (a revision id, NIL when absent, or the sorted list of
;;;   targets when jj left the bookmark conflicted) — the divergence. jj's
;;;   reconciled state is kept (the write is in the operation log; the
;;;   backend does not revert it). A concurrent forward move that jj
;;;   reconciles to exactly the new target is not detected.
;;;   Restarts on REF-CONFLICT: USE-CURRENT (the current ref, or NIL when it
;;;   is absent or conflicted; nothing written), RETRY (redo with EXPECTED =
;;;   the current target; offered only when ACTUAL is one id or NIL), FORCE
;;;   (gated by PERMIT-FORCE-P; redo unconditionally, which also resolves a
;;;   conflicted bookmark).
;;;
;;; Tags — `jj tag set NAME -r COMMIT` without --allow-move. Same target →
;;;   idempotent (the existing tag, nothing written); other target →
;;;   TAG-IMMUTABLE (restart CREATE-NEW-TAG); a bookmark NAME exists →
;;;   REF-CONFLICT (expected NIL, actual its target); :ANNOTATION non-NIL →
;;;   REVISION-ERROR, nothing created.
;;;
;;; Listener — (SETF REF-LISTENER); events (:REF-MOVED name old new) with
;;;   revision ids, for changes made through this store only.
;;;
;;; COMMIT-REVISION — CONTENT is one of:
;;;   a DIFF-PROTOCOL tree value            → that state;
;;;   a string                              → the state of the revision it
;;;                                           designates (RESOLVE-REVISION);
;;;   a DIFF-PROTOCOL:DIFF                  → applied to the first parent's
;;;                                           state (empty tree for a root);
;;;   a REVISION-PROTOCOL:REVISION-PAYLOAD  → its state (or its delta).
;;;   Anything else → REVISION-ERROR. The new change gets PARENTS (root()
;;;   when there are none), its tree is exactly the state (bytes, executable
;;;   bits #o100755 via `jj file chmod`, symlinks #o120000 — a symlink on a
;;;   platform without them, i.e. Windows, → REVISION-ERROR before anything is
;;;   written; :GITLINK files → REVISION-ERROR), its description is MESSAGE
;;;   (default "") with one final newline added when missing (jj's rule;
;;;   "" stays empty). Committer timestamp (DT:NOW) and author timestamp
;;;   VALID-AT or (DT:NOW), whole seconds UTC, so DT:WITH-FIXED-CLOCK fixes
;;;   both. PROVENANCE :AUTHOR-NAME :AUTHOR-EMAIL override the author;
;;;   :COMMITTER-NAME :COMMITTER-EMAIL the committer; otherwise jj's
;;;   user.name / user.email. :ID → REVISION-ERROR (jj chooses ids).
;;;   Mechanism (informative): `jj workspace add --name <unique> -r P… DIR`
;;;   in a temp directory (no -r means @'s parents to jj, so a root commit
;;;   passes -r 'root()'), write the state there, `jj file chmod x` the
;;;   executables, `jj commit -m`, `jj metaedit -r @- --author …
;;;   --author-timestamp …`, `jj workspace forget`, delete DIR — every exit
;;;   forgets the workspace.
;;;   The new change is visible (jj keeps every commit that is not
;;;   abandoned), so it is a head until something builds on it — unlike git,
;;;   where an unreferenced commit is not in HEADS.
;;;   Atomic: the CAS of :REF is checked (under the lock) before anything is
;;;   written; when the ref write then fails the new change is abandoned
;;;   before REF-CONFLICT is signalled. After any condition the visible
;;;   commits and refs are what they were.
;;;
;;; Graph — the graph set is every visible commit but the root (the
;;;   working-copy commit @ of each workspace included; it is usually a
;;;   head). Revsets (informative): children `children(X)`, walks
;;;   `::FROM ~ ::UNTIL`, :FIRST-PARENT `first_ancestors(FROM) ~ ::UNTIL`,
;;;   MERGE-BASE `heads(::A & ::B)`, ANCESTOR-P `A & ::B`, REVISION-RANGE
;;;   `::INCLUDE ~ ::EXCLUDE`, HEADS `heads(all())`, always `~ root()`.
;;;   :TOPO is the order `jj log --reversed --no-graph` prints that revset
;;;   (parents first); :TIME ascending committer timestamp, parents still
;;;   first; REVERSE T reverses either. MERGE-BASE ALL NIL → the first of
;;;   the bases in `jj log` order, NIL when only the root is common.
;;;   :FOOTPRINT uses each revision's REVISION-DELTA (first parent).
;;;
;;; REV-AS-OF — :VALID walks first parents of ON (at the current operation)
;;;   and takes the newest with author timestamp <= TIME (the protocol
;;;   rule). :RECORDED uses the operation log: the operation O with the
;;;   largest end time <= TIME (milliseconds) among the current operation
;;;   and its ancestors (ties: the first `jj op log` lists); ON is resolved
;;;   AT O (`--at-op O`: what the ref named then — with the commit id it had
;;;   then, even if it is hidden now), then first parents are walked (at O)
;;;   to the newest with committer timestamp <= TIME. No such operation, or
;;;   ON absent at O → REVISION-NOT-FOUND.
;;;
;;; Content — CONTENT-PRIMARY :STATE; CONTENT-ENGINE a DIFF-PROTOCOL
;;;   TREE-DIFF-ENGINE. REVISION-STATE: a file whose first 8000 bytes hold a
;;;   NUL, or that is not valid UTF-8, is :BINARY octets; any other file :TEXT
;;;   (exact string, CRLF kept). Modes #o100644 / #o100755 (executable); a
;;;   symlink is a :TEXT file holding its target, mode #o120000; a git
;;;   submodule is a :GITLINK file holding the commit id, mode #o160000; a
;;;   CONFLICTED file is a file (:TEXT, or :BINARY by the same rule) whose
;;;   content is the conflict exactly as `jj file show` materializes it with
;;;   ui.conflict-marker-style=diff (the fixed option), mode #o100644 —
;;;   the same bytes `jj diff --git` shows, so diffs and states agree;
;;;   REVISION-CONFLICTS lists which paths are conflicted. REVISION-DELTA of
;;;   a root change is the diff from the empty tree; of a merge, against its
;;;   first parent (not jj's auto-merged parents).
;;;
;;; STATE-DIFF — A and B: revision designators or a JJ-WORKING-COPY (its
;;;   TARGET-STATE, after a snapshot). LEVEL:
;;;     :SUMMARY  file-level changes from `jj diff --from A --to B -T
;;;               *DIFF-TEMPLATE*` (:ADD :REMOVE :MODIFY, :MOVE for jj's
;;;               "renamed"; "copied" is an :ADD; paths are lists of names;
;;;               footprint "tree:/a/b"); BEFORE / AFTER file nodes are read
;;;               lazily (thunks, not forced by STATE-DIFF); no children.
;;;     :CHANGES  (default) the leaves: `jj diff --git --from A --to B` →
;;;               DIFF-PROTOCOL:PARSE-DIFF :UNIFIED (hunks under file paths,
;;;               mode changes, whole-file adds / removes).
;;;     :CONTENT  file-level changes with their hunks as CHILDREN.
;;;   A file whose before or after side is :BINARY or :GITLINK, or whose type
;;;   changes (file <-> symlink <-> submodule), is a whole-file change with
;;;   both nodes — never hunks, never an OPAQUE-CHANGE — so every state-diff
;;;   applies and inverts. At every level:
;;;     (state-equal engine (apply-diff (state a) (state-diff s a b)) (state b)).
;;; ------------------------------------------------------------------

(defmethod rev:resolve-revision ((store jj-store) designator)
  (declare (ignore designator))
  (%not-implemented 'rev:resolve-revision))

(defmethod rev:commit-revision ((store jj-store) content
                                &key parents ref expected message provenance
                                  valid-at id)
  (declare (ignore content parents ref expected message provenance valid-at id))
  (%not-implemented 'rev:commit-revision))

(defmethod rev:move-ref ((store jj-store) name designator &key expected)
  (declare (ignore name designator expected))
  (%not-implemented 'rev:move-ref))

(defmethod rev:tag-revision ((store jj-store) name designator &key annotation)
  (declare (ignore name designator annotation))
  (%not-implemented 'rev:tag-revision))

(defmethod rev:delete-ref ((store jj-store) name &key expected)
  (declare (ignore name expected))
  (%not-implemented 'rev:delete-ref))

(defmethod rev:find-ref ((store jj-store) name)
  (declare (ignore name))
  (%not-implemented 'rev:find-ref))

(defmethod rev:list-refs ((store jj-store) &key kind prefix)
  (declare (ignore kind prefix))
  (%not-implemented 'rev:list-refs))

(defmethod rev:revision-parents ((store jj-store) designator)
  (declare (ignore designator))
  (%not-implemented 'rev:revision-parents))

(defmethod rev:revision-children ((store jj-store) designator)
  (declare (ignore designator))
  (%not-implemented 'rev:revision-children))

(defmethod rev:walk-revisions ((store jj-store) from
                               &key (order :topo) until reverse footprint)
  (declare (ignore from order until reverse footprint))
  (%not-implemented 'rev:walk-revisions))

(defmethod rev:merge-base ((store jj-store) a b &key all)
  (declare (ignore a b all))
  (%not-implemented 'rev:merge-base))

(defmethod rev:ancestor-p ((store jj-store) a b)
  (declare (ignore a b))
  (%not-implemented 'rev:ancestor-p))

(defmethod rev:revision-range ((store jj-store) include exclude)
  (declare (ignore include exclude))
  (%not-implemented 'rev:revision-range))

(defmethod rev:heads ((store jj-store))
  (%not-implemented 'rev:heads))

(defmethod rev:ref-listener ((store jj-store))
  (%not-implemented 'rev:ref-listener))

(defmethod (setf rev:ref-listener) (function (store jj-store))
  (declare (ignore function))
  (%not-implemented '(setf rev:ref-listener)))

(defmethod rev:permit-force-p ((store jj-store) name)
  (declare (ignore name))
  (%not-implemented 'rev:permit-force-p))

(defmethod rev:content-primary ((store jj-store))
  (%not-implemented 'rev:content-primary))

(defmethod rev:content-engine ((store jj-store))
  (%not-implemented 'rev:content-engine))

(defmethod rev:revision-state ((store jj-store) designator)
  (declare (ignore designator))
  (%not-implemented 'rev:revision-state))

(defmethod rev:revision-delta ((store jj-store) designator)
  (declare (ignore designator))
  (%not-implemented 'rev:revision-delta))

(defmethod rev:state-diff ((store jj-store) a b &key footprint (level :changes))
  (declare (ignore a b footprint level))
  (%not-implemented 'rev:state-diff))

;;; ------------------------------------------------------------------
;;; jj-only views
;;; ------------------------------------------------------------------

(defun conflicted-bookmarks (store)
  "→ fresh alist (NAME . TARGET-IDS) of STORE's conflicted local bookmarks,
sorted by NAME (STRING<); TARGET-IDS the sorted (STRING<) revision ids of the
bookmark's added targets. NIL when none. These are the bookmarks LIST-REFS
leaves out."
  (declare (ignore store))
  (%not-implemented 'conflicted-bookmarks))

(defun revision-conflicts (store designator)
  "→ fresh list of (PATH . SIDES), sorted by PATH (STRING<), one per
conflicted file of the revision DESIGNATOR names: PATH slash-separated from
the repository root, SIDES the number of conflict sides (2 for a two-way
merge). NIL when the revision has no conflicts (its provenance :CONFLICT is
NIL). Signals what RESOLVE-REVISION signals."
  (declare (ignore store designator))
  (%not-implemented 'revision-conflicts))
