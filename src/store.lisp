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
;;;   REVISION-ERROR, nothing created. TAG-REWRITE-P is NIL: with no
;;;   annotations there is nothing to rewrite, so REPLACE-ANNOTATION is never
;;;   offered (revision-protocol 0.4.0).
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

;;; ------------------------------------------------------------------
;;; Reading the repository
;;; ------------------------------------------------------------------

(defparameter +root-commit-id+ (make-string 40 :initial-element #\0)
  "jj's root commit (change zzzz…): never a revision.")

(defvar *at-op* nil
  "When non-NIL, an operation id every repository read runs at (--at-op):
REV-AS-OF :RECORDED resolves ON as of that operation, and a CAS attempt
reads the ref at the operation it then writes on.")

(defun %read (store args &key (output :string) (ok-exit-codes '(0)))
  "A repository read (--ignore-working-copy, at *AT-OP*)."
  (run-jj store args :output output :ok-exit-codes ok-exit-codes
                     :at-operation *at-op*))

(defun %cid-arg (cid)
  "CID as a revset; the root commit as root()."
  (if (string= cid +root-commit-id+) "root()" cid))

(defun %fileset (path)
  "Fileset naming exactly PATH (slash-separated, from the root)."
  (with-output-to-string (s)
    (write-string "root-file:\"" s)
    (loop for c across path
          do (when (member c '(#\" #\\)) (write-char #\\ s))
             (write-char c s))
    (write-char #\" s)))

(defun %log-all (store revset &key reversed limit)
  "Commit records of REVSET in jj log order, the root commit included."
  (parse-commit-records
   (%read store (append (list "log" "--no-graph" "-r" revset "-T" *commit-template*)
                        (when reversed (list "--reversed"))
                        (when limit (list "-n" (princ-to-string limit)))))))

(defun %log (store revset &key reversed limit)
  "Commit records of REVSET in jj log order, without the root commit."
  (remove-if (lambda (r) (getf r :root))
             (%log-all store revset :reversed reversed :limit limit)))

(defun %try-log (store revset)
  "→ (values records T), or (values NIL NIL) when jj rejects REVSET."
  (handler-case (values (%log store revset) t)
    (jj-command-error () (values nil nil))))

(defun %revset-union (cids)
  (format nil "~{~a~^ | ~}" (mapcar #'%cid-arg cids)))

(defun %records-of (store cids)
  "Records of the commits CIDS (visible or hidden), in the order of CIDS."
  (when cids
    (let ((table (make-hash-table :test 'equal)))
      (dolist (r (%log store (%revset-union (remove-duplicates cids :test #'string=))))
        (setf (gethash (getf r :commit-id) table) r))
      (loop for c in cids
            for r = (gethash c table)
            when r collect r))))

;;; ------------------------------------------------------------------
;;; Records → revisions
;;; ------------------------------------------------------------------

(defun %rid (record)
  "Revision id of a commit record: its change id, or its commit id when the
change is divergent."
  (if (getf record :divergent) (getf record :commit-id) (getf record :change-id)))

(defun %record-parent-ids (record)
  (loop for c in (getf record :parents)
        for ch in (getf record :parent-change-ids)
        for dv in (getf record :parent-divergent)
        unless (string= c +root-commit-id+) collect (if dv c ch)))

(defun %strip-one-newline (s)
  (if (and (plusp (length s)) (char= #\Newline (char s (1- (length s)))))
      (subseq s 0 (1- (length s)))
      s))

(defun %revision (record)
  (make-instance 'rev:revision
                 :id (%rid record)
                 :parent-ids (%record-parent-ids record)
                 :recorded-at (dt:make-instant (getf record :committer-time))
                 :valid-at (dt:make-instant (getf record :author-time))
                 :message (%strip-one-newline (getf record :description))
                 :content (getf record :commit-id)
                 :provenance (list :commit-id (getf record :commit-id)
                                   :author-name (getf record :author-name)
                                   :author-email (getf record :author-email)
                                   :committer-name (getf record :committer-name)
                                   :committer-email (getf record :committer-email)
                                   :conflict (getf record :conflict)
                                   :empty (getf record :empty))))

;;; ------------------------------------------------------------------
;;; Designators
;;; ------------------------------------------------------------------

(defun %not-found (designator &optional message)
  (error 'rev:revision-not-found :designator designator :message message))

(defun %chars-in-p (s lo hi)
  (and (plusp (length s)) (every (lambda (c) (char<= lo c hi)) s)))

(defun %change-id-like-p (s) (%chars-in-p s #\k #\z))

(defun %hex-p (s)
  (and (plusp (length s))
       (every (lambda (c) (or (char<= #\0 c #\9) (char<= #\a c #\f))) s)))

(defun %commit-record (store cid designator)
  "Record of the commit CID (visible or hidden); REVISION-NOT-FOUND naming
DESIGNATOR when there is none (or it is the root commit)."
  (or (and (not (string= cid +root-commit-id+))
           (first (%try-log store cid)))
      (%not-found designator "no such commit")))

(defgeneric %resolve-record (store designator)
  (:documentation "→ the commit record DESIGNATOR names; protocol conditions."))

(defmethod %resolve-record ((store jj-store) (d rev:revision))
  (%commit-record store (rev:revision-content d) d))

(defun %prefix-matches (store revset designator key)
  "Records of REVSET (a prefix function); several distinct KEY values →
AMBIGUOUS-REVISION with them."
  (let* ((records (multiple-value-bind (records ok) (%try-log store revset)
                    (if ok
                        records
                        ;; jj rejects an ambiguous prefix without naming the
                        ;; candidates: list the visible commits instead.
                        (remove-if-not (lambda (r) (uiop:string-prefix-p designator (getf r key)))
                                       (%log store "all()")))))
         (keys (remove-duplicates (mapcar (lambda (r) (getf r key)) records)
                                  :test #'string=)))
    (cond ((null records) nil)
          ((rest keys)
           (error 'rev:ambiguous-revision :designator designator
                                          :candidates (sort keys #'string<)))
          ((rest records)
           ;; one change, several commits: a divergent change
           (error 'rev:ambiguous-revision
                  :designator designator
                  :candidates (sort (mapcar (lambda (r) (getf r :commit-id)) records)
                                    #'string<)))
          (t (first records)))))

(defmethod %resolve-record ((store jj-store) (d string))
  (let ((n (length d)))
    (or
     ;; 1. a full change id
     (and (= n 32) (%change-id-like-p d)
          (let ((records (%try-log store (format nil "change_id(~a)" d))))
            (cond ((null records) nil)
                  ((rest records)
                   (error 'rev:ambiguous-revision
                          :designator d
                          :candidates (sort (mapcar (lambda (r) (getf r :commit-id)) records)
                                            #'string<)))
                  (t (first records)))))
     ;; 2. a full commit id, hidden ones included
     (and (= n 40) (%hex-p d) (not (string= d +root-commit-id+))
          (first (%try-log store d)))
     ;; 3. a prefix of visible change ids or commit ids
     (and (>= n rev:+minimum-id-prefix+)
          (cond ((%change-id-like-p d)
                 (%prefix-matches store (format nil "change_id(~a)" d) d :change-id))
                ((%hex-p d)
                 (%prefix-matches store (format nil "commit_id(~a)" d) d :commit-id))))
     ;; 4. a revset at the current operation
     (multiple-value-bind (records ok) (%try-log store d)
       (cond ((not ok) (%not-found d "not a revision, id prefix or revset"))
             ((null records) (%not-found d "the revset names no revision"))
             ((rest records)
              (error 'rev:ambiguous-revision :designator d
                                             :candidates (mapcar #'%rid records)))
             (t (first records)))))))

(defmethod %resolve-record ((store jj-store) (d rev:ref-designator))
  (let ((name (rev:designator-name d)))
    (multiple-value-bind (tag bookmark) (%named-ref store name)
      (cond (tag (%commit-record store (getf tag :cid) d))
            ((null bookmark) (%not-found d "no ref of that name"))
            ((eq (first bookmark) :conflict)
             (error 'rev:ambiguous-revision :designator d :candidates (second bookmark)
                                            :message "the bookmark is conflicted"))
            (t (%commit-record store (getf (rest bookmark) :cid) d))))))

(defmethod %resolve-record ((store jj-store) (d rev:tag-designator))
  (let ((tag (%named-ref store (rev:designator-name d))))
    (if tag
        (%commit-record store (getf tag :cid) d)
        (%not-found d "no tag of that name"))))

(defmethod %resolve-record ((store jj-store) (d rev:parent-designator))
  (let* ((base (%resolve-record store (rev:designator-base d)))
         (parents (remove +root-commit-id+ (getf base :parents) :test #'string=))
         (cid (nth (1- (rev:designator-n d)) parents)))
    (if cid
        (%commit-record store cid d)
        (%not-found d "no such parent"))))

(defmethod %resolve-record ((store jj-store) (d rev:ancestor-designator))
  (let* ((base (%resolve-record store (rev:designator-base d)))
         (n (rev:designator-n d)))
    (if (zerop n)
        base
        (or (nth n (%log store (format nil "first_ancestors(~a)" (getf base :commit-id))
                         :limit (1+ n)))
            (%not-found d "the first-parent line is shorter")))))

(defun %unix-ms (instant)
  (+ (* 1000 (dt:instant-seconds instant)) (floor (dt:instant-nanos instant) 1000000)))

(defun %first-at-or-before (store record seconds key)
  "Newest record on RECORD's first-parent line whose KEY time <= SECONDS."
  (find-if (lambda (r) (<= (getf r key) seconds))
           (%log store (format nil "first_ancestors(~a)" (getf record :commit-id)))))

(defmethod %resolve-record ((store jj-store) (d rev:as-of-designator))
  (let ((time (rev:designator-time d)))
    (ecase (rev:designator-axis d)
      (:valid
       (or (%first-at-or-before store (%resolve-record store (rev:designator-on d))
                                (dt:instant-seconds time) :author-time)
           (%not-found d "nothing on the first-parent line is that old")))
      (:recorded
       (let* ((ms (%unix-ms time))
              (best nil))
         (dolist (op (let ((*at-op* nil)) (list-operations store)))
           (when (and (<= (getf op :end-ms) ms)
                      (or (null best) (> (getf op :end-ms) (getf best :end-ms))))
             (setf best op)))
         (unless best (%not-found d "no operation that old"))
         (let ((*at-op* (getf best :id)))
           (let ((on (handler-case (%resolve-record store (rev:designator-on d))
                       (rev:revision-not-found () (%not-found d "ON is absent at that operation"))
                       (jj-command-error () (%not-found d "ON is absent at that operation")))))
             (or (%first-at-or-before store on (dt:instant-seconds time) :committer-time)
                 (%not-found d "nothing on the first-parent line is that old")))))))))

(defmethod rev:resolve-revision ((store jj-store) designator)
  (%revision (%resolve-record store designator)))

(defun %resolve-cid (store designator)
  (getf (%resolve-record store designator) :commit-id))

;;; ------------------------------------------------------------------
;;; Refs
;;; ------------------------------------------------------------------

(defun %ref-list (store kind)
  "Parsed records of `jj KIND list` (KIND \"bookmark\" or \"tag\")."
  (parse-ref-records (%read store (list kind "list" "-T" *ref-template*))))

(defun %rid-table (store records)
  "commit id → revision id for every target of the ref RECORDS."
  (let ((table (make-hash-table :test 'equal))
        (cids (remove-duplicates (loop for r in records append (getf r :targets))
                                 :test #'string=)))
    (dolist (rec (%records-of store cids))
      (setf (gethash (getf rec :commit-id) table) (%rid rec)))
    ;; a target jj did not list (should not happen): its change id
    (dolist (r records)
      (loop for c in (getf r :targets)
            for ch in (getf r :target-change-ids)
            do (unless (gethash c table) (setf (gethash c table) ch))))
    table))

(defun %ref-entry (record table)
  "A ref record → (:one :rid R :cid C) or (:conflict sorted-rids)."
  (let ((targets (getf record :targets)))
    (if (or (getf record :conflict) (/= 1 (length targets)))
        (list :conflict (sort (remove-duplicates
                               (mapcar (lambda (c) (gethash c table)) targets)
                               :test #'string=)
                              #'string<))
        (list* :one (list :rid (gethash (first targets) table) :cid (first targets))))))

(defun %all-refs (store)
  "→ (values tags bookmarks): alists name → entry, in jj's order."
  (let* ((tags (%ref-list store "tag"))
         (bookmarks (%ref-list store "bookmark"))
         (table (%rid-table store (append tags bookmarks))))
    (values (mapcar (lambda (r) (cons (getf r :name) (%ref-entry r table))) tags)
            (mapcar (lambda (r) (cons (getf r :name) (%ref-entry r table))) bookmarks))))

(defun %named-ref (store name)
  "→ (values tag bookmark) for NAME: TAG a plist (:rid :cid) or NIL (a
conflicted tag reads as its first target); BOOKMARK an entry or NIL."
  (multiple-value-bind (tags bookmarks) (%all-refs store)
    (let ((tag (cdr (assoc name tags :test #'string=)))
          (bookmark (cdr (assoc name bookmarks :test #'string=))))
      (values (and tag (if (eq (first tag) :one)
                           (rest tag)
                           (list :rid (first (second tag)) :cid nil)))
              bookmark))))

(defun %bookmark-actual (bookmark)
  "ACTUAL of a bookmark entry: its revision id, NIL, or the sorted list."
  (cond ((null bookmark) nil)
        ((eq (first bookmark) :conflict) (copy-list (second bookmark)))
        (t (getf (rest bookmark) :rid))))

(defun %ref (name kind rid)
  (make-instance 'rev:revision-ref :name (copy-seq name) :kind kind :target rid
                                   :annotation nil))

(defmethod rev:find-ref ((store jj-store) name)
  (check-type name string)
  (multiple-value-bind (tag bookmark) (%named-ref store name)
    (cond (tag (%ref name :tag (getf tag :rid)))
          ((null bookmark) nil)
          ((eq (first bookmark) :conflict)
           (restart-case (error 'rev:ref-conflict :name name :expected nil
                                                  :actual (copy-list (second bookmark))
                                                  :message "the bookmark is conflicted")
             (rev:use-current ()
               :report "Return NIL: the bookmark has no single target."
               nil)))
          (t (%ref name :movable (getf (rest bookmark) :rid))))))

(defun %find-ref-quietly (store name)
  "FIND-REF, NIL for a conflicted bookmark."
  (handler-case (rev:find-ref store name)
    (rev:ref-conflict () nil)))

(defmethod rev:list-refs ((store jj-store) &key kind prefix)
  (check-type kind (member nil :movable :tag))
  (check-type prefix (or null string))
  (multiple-value-bind (tags bookmarks) (%all-refs store)
    (flet ((keep-p (name)
             (or (null prefix)
                 (and (>= (length name) (length prefix))
                      (string= prefix name :end2 (length prefix))))))
      (stable-sort
       (append
        (unless (eq kind :tag)
          (loop for (name . entry) in bookmarks
                when (and (eq (first entry) :one) (keep-p name))
                  collect (%ref name :movable (getf (rest entry) :rid))))
        (unless (eq kind :movable)
          (loop for (name . entry) in tags
                when (keep-p name)
                  collect (%ref name :tag (if (eq (first entry) :one)
                                              (getf (rest entry) :rid)
                                              (first (second entry)))))))
       #'string< :key #'rev:ref-name))))

(defun conflicted-bookmarks (store)
  "→ fresh alist (NAME . TARGET-IDS) of STORE's conflicted local bookmarks,
sorted by NAME (STRING<); TARGET-IDS the sorted (STRING<) revision ids of the
bookmark's added targets. NIL when none. These are the bookmarks LIST-REFS
leaves out."
  (let ((bookmarks (nth-value 1 (%all-refs store))))
    (sort (loop for (name . entry) in bookmarks
                when (eq (first entry) :conflict)
                  collect (cons (copy-seq name) (copy-list (second entry))))
          #'string< :key #'car)))

(defmethod rev:ref-listener ((store jj-store))
  (bt2:with-recursive-lock-held ((%jj-store-lock store))
    (%jj-store-listener store)))

(defmethod (setf rev:ref-listener) (function (store jj-store))
  (check-type function (or null function))
  (bt2:with-recursive-lock-held ((%jj-store-lock store))
    (setf (%jj-store-listener store) function)))

(defun %notify (store event)
  (let ((listener (and event (rev:ref-listener store))))
    (when (and event listener)
      (funcall listener event))))

(defmethod rev:permit-force-p ((store jj-store) name)
  (let ((gate (%jj-store-permit-force store)))
    (and (if (functionp gate) (funcall gate name) gate) t)))

;;; CAS. An attempt runs under the store lock and either returns values or
;;; throws a condition object out of the locked region (%FAIL); the caller
;;; signals it outside the lock, inside RESTART-CASE.

(defun %fail (type &rest initargs)
  (throw '%jj-failure (apply #'make-condition type initargs)))

(defun %attempt (store thunk)
  "→ (values T values-list) or (values NIL condition)."
  (let ((vals nil))
    (let ((failure (bt2:with-recursive-lock-held ((%jj-store-lock store))
                     (catch '%jj-failure
                       (setf vals (multiple-value-list (funcall thunk)))
                       nil))))
      (if failure (values nil failure) (values t vals)))))

(defun %want (store expected)
  "Revision id EXPECTED designates, or NIL."
  (and expected (%rid (%resolve-record store expected))))

(defun %move-locked (store name designator expected expected-p)
  "→ (values ref event)."
  (let ((op (current-operation store)))
    (multiple-value-bind (tag bookmark target want)
        (let ((*at-op* op))
          (multiple-value-bind (tag bookmark) (%named-ref store name)
            (values tag bookmark
                    (unless tag (%resolve-record store designator))
                    (when (and expected-p (not tag)) (%want store expected)))))
      (when tag
        (%fail 'rev:tag-immutable :name name :target (getf tag :rid)))
      (let ((actual (%bookmark-actual bookmark))
            (cid (getf target :commit-id))
            (rid (%rid target)))
        (when (and expected-p (not (equal want actual)))
          (%fail 'rev:ref-conflict :name name :expected want :actual actual))
        (if (and bookmark (eq (first bookmark) :one)
                 (string= cid (getf (rest bookmark) :cid)))
            (values (%ref name :movable rid) nil)
            (progn
              (run-jj store (list "bookmark" "set" name "-r" cid "--allow-backwards")
                      :at-operation op)
              (let ((now (nth-value 1 (%named-ref store name))))
                (unless (and now (eq (first now) :one)
                             (string= cid (getf (rest now) :cid)))
                  (%fail 'rev:ref-conflict :name name
                                           :expected (if expected-p want actual)
                                           :actual (%bookmark-actual now)
                                           :message "another jj operation moved the bookmark")))
              (values (%ref name :movable rid)
                      (list :ref-moved (copy-seq name) (and (stringp actual) actual) rid))))))))

(defmacro %with-cas-restarts ((store name result expected expected-p &key use-current))
  "Signal the REF-CONFLICT RESULT with USE-CURRENT (returning USE-CURRENT
from the enclosing loop), RETRY (EXPECTED := actual) and gated FORCE."
  (let ((actual (gensym "ACTUAL")) (forcible (gensym "FORCIBLE")))
    `(let ((,actual (rev:ref-conflict-actual ,result))
           (,forcible (rev:permit-force-p ,store ,name)))
       (restart-case (error ,result)
         (rev:use-current ()
           :report (lambda (s) (format s "Leave ~s as it is now." ,name))
           (return ,use-current))
         (rev:retry ()
           :report (lambda (s) (format s "Redo with ~s's current target as expected." ,name))
           :test (lambda (c) (declare (ignore c)) (not (consp ,actual)))
           (setf ,expected ,actual ,expected-p t))
         (rev:force ()
           :report (lambda (s) (format s "Redo on ~s unconditionally." ,name))
           :test (lambda (c) (declare (ignore c)) ,forcible)
           (setf ,expected nil ,expected-p nil))))))

(defmethod rev:move-ref ((store jj-store) name designator &key (expected nil expected-p))
  (check-type name string)
  (loop
    (multiple-value-bind (ok result)
        (%attempt store (lambda () (%move-locked store name designator expected expected-p)))
      (cond
        (ok (destructuring-bind (ref event) result
              (%notify store event)
              (return ref)))
        ((typep result 'rev:ref-conflict)
         (%with-cas-restarts (store name result expected expected-p
                              :use-current (%find-ref-quietly store name))))
        ((typep result 'rev:tag-immutable)
         (restart-case (error result)
           (rev:create-new-tag (new-name)
             :report "Create a new tag at the designator instead."
             (return (rev:tag-revision store new-name designator)))))
        (t (error result))))))

(defun %delete-locked (store name expected expected-p)
  (let ((op (current-operation store)))
    (multiple-value-bind (tag bookmark want)
        (let ((*at-op* op))
          (multiple-value-bind (tag bookmark) (%named-ref store name)
            (values tag bookmark (when (and expected-p bookmark (not tag))
                                   (%want store expected)))))
      (when tag (%fail 'rev:tag-immutable :name name :target (getf tag :rid)))
      (unless bookmark (%not-found name "no bookmark of that name"))
      (let ((actual (%bookmark-actual bookmark)))
        (when (and expected-p (not (equal want actual)))
          (%fail 'rev:ref-conflict :name name :expected want :actual actual))
        (run-jj store (list "bookmark" "delete" (concatenate 'string "exact:" name))
                :at-operation op)
        (let ((now (nth-value 1 (%named-ref store name))))
          (when now
            (%fail 'rev:ref-conflict :name name :expected (if expected-p want actual)
                                     :actual (%bookmark-actual now)
                                     :message "another jj operation moved the bookmark")))
        (values t (list :ref-moved (copy-seq name) (and (stringp actual) actual) nil))))))

(defmethod rev:delete-ref ((store jj-store) name &key (expected nil expected-p))
  (check-type name string)
  (loop
    (multiple-value-bind (ok result)
        (%attempt store (lambda () (%delete-locked store name expected expected-p)))
      (cond
        (ok (destructuring-bind (done event) result
              (%notify store event)
              (return done)))
        ((typep result 'rev:ref-conflict)
         (%with-cas-restarts (store name result expected expected-p :use-current nil)))
        (t (error result))))))

(defun %tag-locked (store name designator)
  (let ((op (current-operation store)))
    (multiple-value-bind (tag bookmark target)
        (let ((*at-op* op))
          (multiple-value-bind (tag bookmark) (%named-ref store name)
            (values tag bookmark (%resolve-record store designator))))
      (let ((rid (%rid target))
            (cid (getf target :commit-id)))
        (cond
          (tag
           (if (equal (getf tag :cid) cid)
               (values (%ref name :tag rid) nil)
               (%fail 'rev:tag-immutable :name name :target (getf tag :rid))))
          (bookmark
           (%fail 'rev:ref-conflict :name name :expected nil
                                    :actual (%bookmark-actual bookmark)
                                    :message "a bookmark has that name"))
          (t
           (run-jj store (list "tag" "set" name "-r" cid) :at-operation op)
           (let ((now (%named-ref store name)))
             (unless (and now (equal (getf now :cid) cid))
               (%fail 'rev:ref-conflict :name name :expected nil
                                        :actual (and now (getf now :rid))
                                        :message "another jj operation set the tag")))
           (values (%ref name :tag rid) (list :ref-moved (copy-seq name) nil rid))))))))

(defmethod rev:tag-revision ((store jj-store) name designator &key annotation)
  (check-type name string)
  (when annotation
    (error 'rev:revision-error :message "jj tags carry no annotation"))
  (multiple-value-bind (ok result)
      (%attempt store (lambda () (%tag-locked store name designator)))
    (cond
      (ok (destructuring-bind (ref event) result
            (%notify store event)
            ref))
      ((typep result 'rev:tag-immutable)
       (restart-case (error result)
         (rev:create-new-tag (new-name)
           :report "Create a new tag with another name instead."
           (rev:tag-revision store new-name designator))))
      (t (error result)))))

;;; ------------------------------------------------------------------
;;; Graph
;;; ------------------------------------------------------------------

(defun %cids-of (store designators)
  (mapcar (lambda (d) (%resolve-cid store d)) (uiop:ensure-list designators)))

(defun %ancestors-revset (cids)
  (format nil "(~{::~a~^ | ~})" cids))

(defmethod rev:revision-parents ((store jj-store) designator)
  (let ((record (%resolve-record store designator)))
    (mapcar #'%revision
            (%records-of store (remove +root-commit-id+ (getf record :parents)
                                       :test #'string=)))))

(defmethod rev:revision-children ((store jj-store) designator)
  (let ((cid (%resolve-cid store designator)))
    (mapcar #'%revision (%log store (format nil "children(~a) ~~ root()" cid)))))

(defmethod rev:heads ((store jj-store))
  (mapcar #'%revision (%log store "heads(all()) ~ root()")))

(defun %time-order (records)
  "RECORDS (topo order, parents first) by ascending committer time, parents
still first (ties: topo order)."
  (let* ((in (make-hash-table :test 'equal))
         (done (make-hash-table :test 'equal))
         (remaining (loop for r in records for i from 0 collect (cons i r)))
         (out '()))
    (dolist (r records) (setf (gethash (getf r :commit-id) in) t))
    (loop while remaining
          do (let ((best nil))
               (dolist (entry remaining)
                 (let ((r (cdr entry)))
                   (when (every (lambda (p) (or (not (gethash p in)) (gethash p done)))
                                (getf r :parents))
                     (when (or (null best)
                               (< (getf r :committer-time) (getf (cdr best) :committer-time)))
                       (setf best entry)))))
               (setf remaining (remove best remaining))
               (setf (gethash (getf (cdr best) :commit-id) done) t)
               (push (cdr best) out)))
    (nreverse out)))

(defmethod rev:walk-revisions ((store jj-store) from
                               &key (order :topo) until reverse footprint)
  (check-type order (member :topo :time :first-parent))
  (let* ((from (%cids-of store from))
         (until (and until (%cids-of store until)))
         (exclude (if until (format nil " ~~ ~a" (%ancestors-revset until)) ""))
         (records
           (if (null from)
               '()
               (ecase order
                 (:topo (%log store (format nil "~a~a ~~ root()" (%ancestors-revset from) exclude)
                              :reversed t))
                 (:time (%time-order
                         (%log store (format nil "~a~a ~~ root()" (%ancestors-revset from) exclude)
                               :reversed t)))
                 (:first-parent
                  (%log store (format nil "first_ancestors(~a)~a ~~ root()" (first from) exclude)
                        :reversed t)))))
         (revisions (mapcar #'%revision records)))
    (when footprint
      (setf revisions
            (remove-if-not
             (lambda (rv)
               (let ((fp (rev:delta-footprint (rev:revision-delta store rv))))
                 (some (lambda (f) (some (lambda (g) (diff:footprint-overlap-p f g)) footprint))
                       fp)))
             revisions)))
    (if reverse (reverse revisions) revisions)))

(defmethod rev:merge-base ((store jj-store) a b &key all)
  (let* ((ca (%resolve-cid store a))
         (cb (%resolve-cid store b))
         (records (%log store (format nil "heads(::~a & ::~a) ~~ root()" ca cb))))
    (if all
        (mapcar #'%revision records)
        (and records (%revision (first records))))))

(defmethod rev:ancestor-p ((store jj-store) a b)
  (let ((ca (%resolve-cid store a))
        (cb (%resolve-cid store b)))
    (and (%log store (format nil "~a & ::~a" ca cb)) t)))

(defmethod rev:revision-range ((store jj-store) include exclude)
  (let ((include (and include (%cids-of store include)))
        (exclude (and exclude (%cids-of store exclude))))
    (when include
      (mapcar #'%revision
              (%log store (format nil "~a~@[ ~~ ~a~] ~~ root()"
                                  (%ancestors-revset include)
                                  (and exclude (%ancestors-revset exclude)))
                    :reversed t)))))

;;; ------------------------------------------------------------------
;;; Content: states
;;; ------------------------------------------------------------------

(defmethod rev:content-primary ((store jj-store))
  :state)

(defmethod rev:content-engine ((store jj-store))
  (diff:find-diff-engine :tree))

(defun %utf8-decode-strict (bytes)
  "String from the octets BYTES, or NIL when they are not well-formed UTF-8."
  (let* ((n (length bytes))
         (out (make-string n))
         (i 0)
         (j 0))
    (loop
      (when (>= i n) (return (subseq out 0 j)))
      (let ((b0 (aref bytes i)) len cp min)
        (cond ((< b0 #x80) (setf len 1 cp b0 min 0))
              ((<= #xC2 b0 #xDF) (setf len 2 cp (logand b0 #x1F) min #x80))
              ((<= #xE0 b0 #xEF) (setf len 3 cp (logand b0 #x0F) min #x800))
              ((<= #xF0 b0 #xF4) (setf len 4 cp (logand b0 #x07) min #x10000))
              (t (return nil)))
        (when (> (+ i len) n) (return nil))
        (loop for k from 1 below len
              for b = (aref bytes (+ i k))
              do (if (= (logand b #xC0) #x80)
                     (setf cp (logior (ash cp 6) (logand b #x3F)))
                     (return-from %utf8-decode-strict nil)))
        (when (or (< cp min) (<= #xD800 cp #xDFFF) (> cp #x10FFFF))
          (return nil))
        (let ((ch (code-char cp)))
          (unless ch (return nil))
          (setf (char out j) ch))
        (incf i len)
        (incf j)))))

(defun %content-node (octets mode)
  "File node for OCTETS: :BINARY when a NUL is in the first 8000 bytes or
they are not UTF-8, else :TEXT."
  (let ((text (and (not (find 0 octets :end (min 8000 (length octets))))
                   (%utf8-decode-strict octets))))
    (if text
        (diff:make-tree-file text :type :text :mode mode)
        (diff:make-tree-file (coerce octets '(simple-array (unsigned-byte 8) (*)))
                             :type :binary :mode mode))))

(defun %octets (string)
  (encoding-protocol:encode string :encoding :utf-8))

(defun %symlink-targets (store cid paths)
  "path → target string of the symlinks PATHS at CID (git diff from root())."
  (let ((table (make-hash-table :test 'equal)))
    (when paths
      (let ((d (diff:parse-diff :unified
                                (%read store (append (list "diff" "--git" "--from" "root()"
                                                           "--to" cid "--")
                                                     (mapcar #'%fileset paths))))))
        (dolist (c (diff:diff-changes d))
          (when (and (eq :add (diff:change-kind c)) (every #'stringp (diff:change-path c)))
            (let ((node (diff:change-after c)))
              (when (and node (diff:tree-file-p node))
                (setf (gethash (format nil "~{~a~^/~}" (diff:change-path c)) table)
                      (diff:tree-file-content node))))))))
    table))

(defun %gitlink-ids (store cid paths)
  "path → submodule commit id of the git submodules PATHS at CID."
  (let ((table (make-hash-table :test 'equal)))
    (when paths
      (let ((out (%read store (append (list "diff" "--git" "--from" "root()" "--to" cid "--")
                                      (mapcar #'%fileset paths))))
            (current nil))
        (dolist (line (uiop:split-string out :separator '(#\Newline)))
          (cond ((uiop:string-prefix-p "diff --git a/" line)
                 (let ((pos (search " b/" line :from-end t)))
                   (setf current (and pos (subseq line (+ pos 3))))))
                ((and current (uiop:string-prefix-p "+Subproject commit " line))
                 (setf (gethash current table)
                       (string-trim " " (subseq line (length "+Subproject commit ")))))))))
    table))

(defun %compute-entries (store cid)
  "→ list of (path . node) of the commit CID, sorted by path."
  (if (string= cid +root-commit-id+)
      '()
      (let* ((records (parse-file-records
                       (run-jj store (list "file" "list" "-r" cid "-T" *file-template*))))
             (symlinks (%symlink-targets
                        store cid (loop for r in records
                                        when (eq :symlink (getf r :type))
                                          collect (getf r :path))))
             (gitlinks (%gitlink-ids
                        store cid (loop for r in records
                                        when (eq :git-submodule (getf r :type))
                                          collect (getf r :path)))))
        (sort
         (loop for r in records
               for path = (getf r :path)
               for node = (ecase (getf r :type)
                            ((:file :conflict)
                             (%content-node
                              (run-jj store (list "file" "show" "-r" cid "--" (%fileset path))
                                      :output :octets)
                              (if (and (eq :file (getf r :type)) (getf r :executable))
                                  #o100755
                                  #o100644)))
                            (:symlink
                             (diff:make-tree-file (or (gethash path symlinks)
                                                      (error 'rev:revision-error
                                                             :message (format nil "cannot read the symlink ~a" path)))
                                                  :type :text :mode #o120000))
                            (:git-submodule
                             (diff:make-tree-file (or (gethash path gitlinks)
                                                      (error 'rev:revision-error
                                                             :message (format nil "cannot read the submodule ~a" path)))
                                                  :type :gitlink :mode #o160000))
                            (:tree nil))
               when node collect (cons path node))
         #'string< :key #'car))))

(defun %entries (store cid)
  "Cached (path . node) list of commit CID (a commit never changes)."
  (let ((cache (%jj-store-content-cache store))
        (lock (%jj-store-cache-lock store)))
    (multiple-value-bind (v found) (bt2:with-lock-held (lock) (gethash cid cache))
      (if found
          v
          (let ((v (%compute-entries store cid)))
            (bt2:with-lock-held (lock) (setf (gethash cid cache) v)))))))

(defun %split-path (path)
  (uiop:split-string path :separator '(#\/)))

(defun %build-tree (entries)
  "ENTRIES: list of (names . node) → a tree value."
  (let ((groups '()))
    (dolist (e entries)
      (let* ((names (car e))
             (cell (assoc (first names) groups :test #'string=)))
        (unless cell
          (setf cell (list (first names)))
          (push cell groups))
        (push (cons (rest names) (cdr e)) (cdr cell))))
    (apply #'diff:make-tree
           (loop for (name . members) in (nreverse groups)
                 append (list name
                              (if (and (null (rest members)) (null (car (first members))))
                                  (cdr (first members))
                                  (%build-tree (reverse members))))))))

(defun %state (store cid)
  (%build-tree (mapcar (lambda (e) (cons (%split-path (car e)) (cdr e)))
                       (%entries store cid))))

(defun %node (store cid path)
  (cdr (assoc path (%entries store cid) :test #'string=)))

(defun %operand-cid (store x)
  "Commit id of a STATE-DIFF / REVISION-STATE operand."
  (if (jj-working-copy-p x)
      (progn (%snapshot store)
             (getf (first (%log store "@")) :commit-id))
      (%resolve-cid store x)))

(defmethod rev:revision-state ((store jj-store) designator)
  (%state store (%operand-cid store designator)))

(defun revision-conflicts (store designator)
  "→ fresh list of (PATH . SIDES), sorted by PATH (STRING<), one per
conflicted file of the revision DESIGNATOR names: PATH slash-separated from
the repository root, SIDES the number of conflict sides (2 for a two-way
merge). NIL when the revision has no conflicts (its provenance :CONFLICT is
NIL). Signals what RESOLVE-REVISION signals."
  (let ((record (%resolve-record store designator)))
    (when (getf record :conflict)
      (sort (loop for r in (parse-file-records
                            (run-jj store (list "file" "list" "-r" (getf record :commit-id)
                                                "-T" *file-template*)))
                  when (getf r :conflict)
                    collect (cons (getf r :path) (getf r :sides)))
            #'string< :key #'car))))

;;; ------------------------------------------------------------------
;;; Content: diffs
;;; ------------------------------------------------------------------

(defun %tree-fp (path) (concatenate 'string "tree:/" path))

(defun %node-kind (node)
  "File kind of NODE for the whole-file rule: :TEXT, :BINARY, :SYMLINK, :GITLINK."
  (cond ((null node) nil)
        ((eq :gitlink (diff:tree-file-type node)) :gitlink)
        ((eql #o120000 (diff:tree-file-mode node)) :symlink)
        ((eq :binary (diff:tree-file-type node)) :binary)
        (t :text)))

(defun %whole-file-p (record before after)
  (let ((kb (%node-kind before))
        (ka (%node-kind after)))
    (or (member (getf record :status) '(:copied))
        (member kb '(:binary :gitlink))
        (member ka '(:binary :gitlink))
        (and kb ka (not (eq kb ka))))))

(defun %whole-file-changes (record before after)
  (let* ((path (getf record :path))
         (source (getf record :source))
         (names (%split-path path)))
    (ecase (getf record :status)
      (:added (list (diff:make-change :add :path names :footprint (list (%tree-fp path))
                                           :after after)))
      ((:copied) (list (diff:make-change :add :path names :footprint (list (%tree-fp path))
                                              :after after)))
      (:removed (list (diff:make-change :remove :path names :footprint (list (%tree-fp path))
                                                :before before)))
      (:modified (list (diff:make-change :modify :path names :footprint (list (%tree-fp path))
                                                 :before before :after after)))
      (:renamed (list (diff:make-change :remove :path (%split-path source)
                                                :footprint (list (%tree-fp source))
                                                :before before)
                      (diff:make-change :add :path names :footprint (list (%tree-fp path))
                                             :after after))))))

(defun %file-names (change)
  (loop for step in (diff:change-path change) while (stringp step) collect step))

(defun %leaf-p (change)
  (notevery #'stringp (diff:change-path change)))

(defun %rank (change)
  (if (%leaf-p change)
      2
      (ecase (diff:change-kind change) (:remove 0) (:move 1) (:modify 2) (:add 3))))

(defun %canonical-sort (changes)
  (stable-sort (copy-list changes)
               (lambda (x y)
                 (let ((rx (%rank x)) (ry (%rank y)))
                   (if (/= rx ry)
                       (< rx ry)
                       (string< (format nil "~{~a~^/~}" (%file-names x))
                                (format nil "~{~a~^/~}" (%file-names y))))))))

(defun %diff-records (store ca cb)
  (parse-diff-records
   (%read store (list "diff" "--from" (%cid-arg ca) "--to" (%cid-arg cb) "-T" *diff-template*))))

(defun %summary-changes (store ca cb records)
  (loop for r in records
        for path = (getf r :path)
        for source = (getf r :source)
        for names = (%split-path path)
        collect (let ((before (let ((p source)) (lambda () (%node store ca p))))
                      (after (let ((p path)) (lambda () (%node store cb p)))))
                  (ecase (getf r :status)
                    ((:added :copied)
                     (diff:make-change :add :path names :footprint (list (%tree-fp path))
                                            :after-fn after))
                    (:removed
                     (diff:make-change :remove :path names :footprint (list (%tree-fp path))
                                               :before-fn before))
                    (:modified
                     (diff:make-change :modify :path names :footprint (list (%tree-fp path))
                                               :before-fn before :after-fn after))
                    (:renamed
                     (diff:make-change :move :path names :from (%split-path source)
                                             :footprint (list (%tree-fp source) (%tree-fp path))
                                             :before-fn before :after-fn after))))))

(defun %leaf-changes (store ca cb records)
  "The :CHANGES leaves from CA to CB."
  (let ((text '())
        (whole '()))
    (dolist (r records)
      (let ((before (and (getf r :source-type) (%node store ca (getf r :source))))
            (after (and (getf r :target-type) (%node store cb (getf r :path)))))
        (if (%whole-file-p r before after)
            (setf whole (append whole (%whole-file-changes r before after)))
            (push r text))))
    (let ((parsed
            (when text
              (let ((paths (remove-duplicates
                            (loop for r in text
                                  collect (getf r :source) collect (getf r :path))
                            :test #'string=)))
                (diff:diff-changes
                 (diff:parse-diff
                  :unified
                  (%read store (append (list "diff" "--git" "--from" (%cid-arg ca)
                                             "--to" (%cid-arg cb) "--")
                                       (mapcar #'%fileset paths)))))))))
      ;; Defensive: any opaque section (jj thought a file binary) becomes a
      ;; whole-file change from the states.
      (let ((opaque (remove-if-not (lambda (c) (typep c 'diff:opaque-change)) parsed)))
        (when opaque
          (let ((paths (mapcar (lambda (c) (format nil "~{~a~^/~}" (%file-names c))) opaque)))
            (setf parsed (remove-if (lambda (c)
                                      (member (format nil "~{~a~^/~}" (%file-names c)) paths
                                              :test #'string=))
                                    parsed))
            (dolist (r text)
              (when (or (member (getf r :path) paths :test #'string=)
                        (member (getf r :source) paths :test #'string=))
                (setf whole (append whole
                                    (%whole-file-changes
                                     r
                                     (and (getf r :source-type) (%node store ca (getf r :source)))
                                     (and (getf r :target-type) (%node store cb (getf r :path))))))))))
        (%canonical-sort (append parsed whole))))))

(defun %content-changes (store ca cb leaves)
  "File-level changes with their hunks as children."
  (let ((moves (remove-if-not (lambda (c) (and (not (%leaf-p c)) (eq :move (diff:change-kind c))))
                              leaves))
        (groups '())
        (out '()))
    (dolist (c leaves)
      (cond ((member c moves)
             (let ((from (format nil "~{~a~^/~}" (diff:change-from c)))
                   (to (format nil "~{~a~^/~}" (diff:change-path c))))
               (push (diff:make-change :move :path (diff:change-path c) :from (diff:change-from c)
                                             :footprint (list (%tree-fp from) (%tree-fp to))
                                             :before (%node store ca from)
                                             :after (%node store cb to))
                     out)))
            ((%leaf-p c)
             (let* ((names (%file-names c))
                    (cell (assoc names groups :test #'equal)))
               (unless (find names moves :key #'diff:change-path :test #'equal)
                 (if cell
                     (setf (cdr cell) (append (cdr cell) (list c)))
                     (push (list names c) groups)))))
            (t (push c out))))
    (dolist (g groups)
      (let ((path (format nil "~{~a~^/~}" (car g))))
        (push (diff:make-change :modify :path (car g) :footprint (list (%tree-fp path))
                                        :before (%node store ca path)
                                        :after (%node store cb path)
                                        :children (cdr g))
              out)))
    (%canonical-sort (nreverse out))))

(defun %state-diff (store ca cb level footprint)
  (let* ((records (%diff-records store ca cb))
         (changes (ecase level
                    (:summary (%canonical-sort (%summary-changes store ca cb records)))
                    (:changes (%leaf-changes store ca cb records))
                    (:content (%content-changes store ca cb
                                                (%leaf-changes store ca cb records)))))
         (changes (if footprint
                      (remove-if-not
                       (lambda (c)
                         (some (lambda (f)
                                 (some (lambda (g) (diff:footprint-overlap-p f g)) footprint))
                               (diff:change-footprint c)))
                       changes)
                      changes)))
    (diff:make-diff changes :engine (diff:find-diff-engine :tree) :level level)))

(defmethod rev:state-diff ((store jj-store) a b &key footprint (level :changes))
  (check-type level (member :summary :changes :content))
  (check-type footprint list)
  (let ((ca (%operand-cid store a))
        (cb (%operand-cid store b)))
    (%state-diff store ca cb level footprint)))

(defmethod rev:revision-delta ((store jj-store) designator)
  (let ((record (%resolve-record store designator)))
    (%state-diff store (or (first (getf record :parents)) +root-commit-id+)
                 (getf record :commit-id) :changes nil)))

;;; ------------------------------------------------------------------
;;; commit-revision
;;; ------------------------------------------------------------------

(defun %rfc3339 (instant)
  (multiple-value-bind (s mi h d mo y)
      (decode-universal-time (+ (dt:instant-seconds instant)
                                (encode-universal-time 0 0 0 1 1 1970 0))
                             0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d+00:00" y mo d h mi s)))

(defun %state-files (tree &optional prefix)
  "→ list of (path . node) of every file in the tree value TREE."
  (loop for (name node) in (diff:tree-entries tree)
        for path = (if prefix (format nil "~a/~a" prefix name) name)
        nconc (if (diff:tree-file-p node)
                  (list (cons path node))
                  (%state-files node path))))

(defun %check-state (state)
  "Refuse what jj cannot record from a workspace, before anything is written."
  (unless (diff:tree-dir-p state)
    (error 'rev:revision-error :message "commit content is not a tree value"))
  (dolist (f (%state-files state))
    (let ((node (cdr f)))
      (cond ((or (eq :gitlink (diff:tree-file-type node))
                 (eql #o160000 (diff:tree-file-mode node)))
             (error 'rev:revision-error
                    :message (format nil "~a: git submodules cannot be committed" (car f))))
            ((and (eql #o120000 (diff:tree-file-mode node)) (uiop:os-windows-p))
             (error 'rev:revision-error
                    :message (format nil "~a: symlinks need a POSIX filesystem" (car f))))
            ((not (or (stringp (diff:tree-file-content node))
                      (typep (diff:tree-file-content node) '(vector (unsigned-byte 8)))))
             (error 'rev:revision-error
                    :message (format nil "~a: content is neither text nor octets" (car f))))))))

(defun %content-state (store content parent-cid)
  "The state CONTENT stands for (a diff applies to PARENT-CID's state)."
  (flet ((base () (if parent-cid (%state store parent-cid) (diff:make-tree))))
    (cond ((diff:tree-dir-p content) content)
          ((stringp content) (rev:revision-state store content))
          ((typep content 'diff:diff) (values (diff:apply-diff (base) content)))
          ((typep content 'rev:revision-payload)
           (cond ((rev:payload-state-p content)
                  (or (rev:payload-state content) (diff:make-tree)))
                 ((rev:payload-delta content)
                  (values (diff:apply-diff (base) (rev:payload-delta content))))
                 (t (error 'rev:revision-error :message "empty payload"))))
          (t (error 'rev:revision-error
                    :message (format nil "cannot commit ~s as jj content" (type-of content)))))))

(defun %write-state (dir state)
  "Replace DIR's files (but .jj / .git) with STATE. → executable paths."
  (dolist (f (uiop:directory-files dir))
    (unless (member (file-namestring f) '(".git" ".jj") :test #'string=)
      (delete-file f)))
  (dolist (d (uiop:subdirectories dir))
    (unless (member (car (last (pathname-directory d))) '(".git" ".jj") :test #'string=)
      (uiop:delete-directory-tree d :validate t)))
  (let ((executables '()))
    (dolist (f (%state-files state) (nreverse executables))
      (let* ((path (car f))
             (node (cdr f))
             (target (uiop:merge-pathnames* (uiop:parse-unix-namestring path) dir))
             (content (diff:tree-file-content node)))
        (ensure-directories-exist target)
        (if (eql #o120000 (diff:tree-file-mode node))
            (let ((fs (pathlib:path-filesystem (pathlib:ensure-path target))))
              (pathlib:fs-create-symlink fs target (pathlib:fs-parse fs content)))
            (with-open-file (out target :direction :output :element-type '(unsigned-byte 8)
                                        :if-exists :supersede :if-does-not-exist :create)
              (write-sequence (if (stringp content) (%octets content) content) out)))
        (when (eql #o100755 (diff:tree-file-mode node))
          (push path executables))))))

(defun %temp-workspace-dir ()
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil "rbjj-ws-~(~36r~)" (random (expt 36 12) (make-random-state t)))
                    (uiop:ensure-directory-pathname (uiop:temporary-directory)))))

(defun %commit-in-workspace (store parent-cids state message provenance valid-at)
  "Write STATE as a new change on PARENT-CIDS through a temporary workspace.
→ the new commit id. The workspace is forgotten and its directory deleted on
every exit."
  (let* ((name (format nil "rbjj-~(~36r~)" (random (expt 36 12) (make-random-state t))))
         (dir (%temp-workspace-dir))
         (now (dt:now))
         (env (append (%jj-store-env store)
                      (list (cons "JJ_TIMESTAMP" (%rfc3339 now)))))
         (program (%jj-store-program store))
         (identity (append
                    (let ((n (getf provenance :committer-name)))
                      (when n (list "--config" (format nil "user.name=~a" n))))
                    (let ((e (getf provenance :committer-email)))
                      (when e (list "--config" (format nil "user.email=~a" e))))))
         (snapshot-config (list "--config" "snapshot.auto-track=\"all()\""
                                "--config" "snapshot.max-new-file-size=\"1GiB\""))
         (added nil))
    (flet ((in-ws (args)
             (%invoke-jj program env dir (append snapshot-config identity args)
                         :ignore-working-copy nil)))
      (unwind-protect
           (progn
             (%invoke-jj program env (jj-store-path store)
                         (append (list "workspace" "add" "--name" name)
                                 (loop for p in (or parent-cids (list +root-commit-id+))
                                       append (list "-r" (%cid-arg p)))
                                 (list (uiop:native-namestring dir)))
                         :ignore-working-copy nil)
             (setf added t)
             (let ((executables (%write-state dir state)))
               (when executables
                 (in-ws (append (list "file" "chmod" "x" "--")
                                (mapcar #'%fileset executables))))
               (in-ws (list "commit" "-m" (or message "")))
               (in-ws (append (list "metaedit" "-r" "@-"
                                    "--author-timestamp" (%rfc3339 (or valid-at now)))
                              (when (or (getf provenance :author-name)
                                        (getf provenance :author-email))
                                (let ((record (first (parse-commit-records
                                                      (%invoke-jj program env dir
                                                                  (list "log" "--no-graph" "-r" "@-"
                                                                        "-T" *commit-template*))))))
                                  (list "--author"
                                        (format nil "~a <~a>"
                                                (or (getf provenance :author-name)
                                                    (getf record :author-name))
                                                (or (getf provenance :author-email)
                                                    (getf record :author-email))))))))
               (string-trim '(#\Newline #\Return #\Space)
                            (%invoke-jj program env dir
                                        (list "log" "--no-graph" "-r" "@-" "-T" "commit_id")))))
        (when added
          (handler-case
              (%invoke-jj program env (jj-store-path store) (list "workspace" "forget" name))
            (jj-command-error () nil)))
        (when (uiop:directory-exists-p dir)
          (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))))

(defun %abandon (store cid)
  (run-jj store (list "abandon" cid)))

(defun %commit-locked (store content parents parents-p ref expected expected-p
                       message provenance valid-at)
  "→ (values revision event)."
  (let* ((op (current-operation store))
         (tag nil) (bookmark nil) (parent-records nil) (want nil))
    (let ((*at-op* op))
      (when ref
        (multiple-value-setq (tag bookmark) (%named-ref store ref)))
      (setf parent-records
            (cond (parents-p (mapcar (lambda (d) (%resolve-record store d)) parents))
                  ((and bookmark (eq (first bookmark) :one))
                   (list (%commit-record store (getf (rest bookmark) :cid) ref)))
                  (t '())))
      (when (and ref expected-p (not tag))
        (setf want (%want store expected))))
    (when tag
      (%fail 'rev:tag-immutable :name ref :target (getf tag :rid)))
    (let ((actual (%bookmark-actual bookmark)))
      (when ref
        (cond (expected-p
               (unless (equal want actual)
                 (%fail 'rev:ref-conflict :name ref :expected want :actual actual)))
              ((consp actual)
               (%fail 'rev:ref-conflict :name ref :expected nil :actual actual
                                        :message "the bookmark is conflicted"))))
      (let* ((parent-cids (mapcar (lambda (r) (getf r :commit-id)) parent-records))
             (state (%content-state store content (first parent-cids))))
        (%check-state state)
        (let* ((cid (%commit-in-workspace store parent-cids state message provenance valid-at))
               (record (%commit-record store cid cid)))
          (when ref
            (let ((op2 (current-operation store)))
              (flet ((give-up (now)
                       (%abandon store cid)
                       (%fail 'rev:ref-conflict :name ref :expected (if expected-p want actual)
                                                :actual (%bookmark-actual now)
                                                :message "another jj operation moved the bookmark")))
                (let ((now (nth-value 1 (let ((*at-op* op2)) (%named-ref store ref)))))
                  (unless (equal (%bookmark-actual now) actual)
                    (give-up now)))
                (run-jj store (list "bookmark" "set" ref "-r" cid "--allow-backwards")
                        :at-operation op2)
                (let ((now (nth-value 1 (%named-ref store ref))))
                  (unless (and now (eq (first now) :one) (string= cid (getf (rest now) :cid)))
                    (give-up now))))))
          (let ((revision (%revision record)))
            (values revision
                    (and ref (list :ref-moved (copy-seq ref) (and (stringp actual) actual)
                                   (rev:revision-id revision))))))))))

(defmethod rev:commit-revision ((store jj-store) content
                                &key (parents nil parents-p) ref (expected nil expected-p)
                                  message provenance valid-at id)
  (check-type ref (or null string))
  (check-type parents list)
  (check-type valid-at (or null dt:instant))
  (when id
    (error 'rev:revision-error :message "jj chooses revision ids; :ID is not accepted"))
  (when (and expected-p (null ref))
    (error 'rev:revision-error
           :message (format nil "commit-revision :expected ~s given without :ref" expected)))
  (unless (or (diff:tree-dir-p content) (stringp content) (typep content 'diff:diff)
              (typep content 'rev:revision-payload))
    (error 'rev:revision-error
           :message (format nil "cannot commit ~s as jj content" (type-of content))))
  (let ((provenance (copy-list provenance)))
    (loop
      (multiple-value-bind (ok result)
          (%attempt store (lambda ()
                            (%commit-locked store content parents parents-p ref
                                            expected expected-p message provenance valid-at)))
        (cond
          (ok (destructuring-bind (revision event) result
                (%notify store event)
                (return revision)))
          ((typep result 'rev:ref-conflict)
           (%with-cas-restarts (store ref result expected expected-p
                                :use-current (let ((r (%find-ref-quietly store ref)))
                                               (and r (rev:resolve-revision
                                                       store (rev:ref-target r)))))))
          (t (error result)))))))
