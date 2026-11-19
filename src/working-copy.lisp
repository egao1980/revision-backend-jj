(in-package #:revision-backend-jj)

;;; ------------------------------------------------------------------
;;; JJ-WORKING-COPY — the store's workspace as a REVISION-PROTOCOL target.
;;;
;;; In jj the working copy IS a commit: @, the working-copy commit of the
;;; store's workspace. Files on disk are recorded into @ by a snapshot
;;; (`jj util snapshot`, or any jj command run without --ignore-working-
;;; copy), which rewrites @ (same change id, new commit id). The snapshot
;;; follows jj's own rules and the user's configuration: .gitignore files,
;;; snapshot.auto-track, snapshot.max-new-file-size.
;;;
;;; Every operation below that observes the disk — TARGET-STATE,
;;; TARGET-DRIFT, CAPTURE-REVISION, TARGET-STAMP, WORKING-COPY-REVISION,
;;; STATE-DIFF with a working copy — snapshots first. None of them writes,
;;; deletes or touches a file in the workspace: contents and modification
;;; times stay byte-identical (the tree they leave @ with is the tree on
;;; disk).
;;;
;;; The stamp = @'s parents. TARGET-REVISIONS → their revision ids in commit
;;; order, NIL when @'s only parent is the root commit (an unstamped
;;; target). TARGET-STAMP REVISIONS (revisions or ids; NIL = root()) replaces
;;; @ by a new change with those parents and @'s tree and description, made
;;; the working-copy commit, and abandons the old @ (mechanism, informative:
;;; `jj new --no-edit P…`, `jj restore --from <old @ commit> --into NEW`,
;;; `jj edit NEW`, `jj abandon <old @>`). Several revisions are allowed (@
;;; becomes a merge), unlike revision-backend-git's single stamp.
;;;
;;; TARGET-STATE → the state of @ after the snapshot (REVISION-STATE rules).
;;;
;;; TARGET-DRIFT → after the snapshot: more than one stamped revision →
;;; REVISION-ERROR; NIL when @'s state equals the stamped revision's state
;;; (the empty tree when unstamped); otherwise STATE-DIFF from the stamp to
;;; the working copy, level :CHANGES. Drift = the working-copy commit's own
;;; changes.
;;;
;;; CAPTURE-REVISION → after the snapshot, a revision whose state is
;;; TARGET-STATE and whose parents are PARENTS (designators; default
;;; TARGET-REVISIONS), description MESSAGE (default "capture"); then @ is a
;;; new empty change on top of it, so TARGET-DRIFT is NIL and
;;; TARGET-REVISIONS is (its id). With the default parents the captured
;;; revision IS the old @ change (`jj commit -m MESSAGE`: same change id, the
;;; snapshot's tree); with other parents it is a new change (see
;;; TARGET-STAMP's mechanism) and the old @ is abandoned. → the captured
;;; REVISION.
;;;
;;; TARGET-FIDELITIES → NIL, TARGET-TRANSACTIONAL-P → NIL in V2.
;;; Not V2: (SETF TARGET-STATE), PLAN-TRANSITION / EXECUTE-PLAN, projections
;;; (`jj new --no-edit A B` merge projection), `jj edit` / `jj rebase` plans.
;;; ------------------------------------------------------------------

(defclass jj-working-copy (rev:revision-target)
  ((store :initarg :store :reader working-copy-store))
  (:documentation "The workspace of a JJ-STORE (its @) as a revision target.
See the comment above the class in src/working-copy.lisp for the stamp,
state, drift and capture rules."))

(defun jj-working-copy-p (x)
  "T when X is a JJ-WORKING-COPY."
  (typep x 'jj-working-copy))

(defun make-jj-working-copy (store)
  "→ JJ-WORKING-COPY over STORE's workspace. Runs no jj command."
  (declare (ignore store))
  (%not-implemented 'make-jj-working-copy))

(defun working-copy-path (working-copy)
  "→ absolute directory pathname of WORKING-COPY's workspace root (its
store's JJ-STORE-PATH)."
  (declare (ignore working-copy))
  (%not-implemented 'working-copy-path))

(defun working-copy-revision (working-copy)
  "Snapshot, then → the REVISION of @, the working-copy commit."
  (declare (ignore working-copy))
  (%not-implemented 'working-copy-revision))

(defmethod rev:target-revisions ((target jj-working-copy))
  (%not-implemented 'rev:target-revisions))

(defmethod rev:target-stamp ((target jj-working-copy) revisions)
  (declare (ignore revisions))
  (%not-implemented 'rev:target-stamp))

(defmethod rev:target-state ((target jj-working-copy))
  (%not-implemented 'rev:target-state))

(defmethod rev:target-drift ((target jj-working-copy) store)
  (declare (ignore store))
  (%not-implemented 'rev:target-drift))

(defmethod rev:capture-revision ((target jj-working-copy) store
                                 &key (parents nil parents-p) message)
  (declare (ignore store parents parents-p message))
  (%not-implemented 'rev:capture-revision))

(defmethod rev:target-fidelities ((target jj-working-copy))
  (%not-implemented 'rev:target-fidelities))

(defmethod rev:target-transactional-p ((target jj-working-copy))
  (%not-implemented 'rev:target-transactional-p))
