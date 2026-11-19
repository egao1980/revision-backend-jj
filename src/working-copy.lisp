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
  (check-type store jj-store)
  (make-instance 'jj-working-copy :store store))

(defun working-copy-path (working-copy)
  "→ absolute directory pathname of WORKING-COPY's workspace root (its
store's JJ-STORE-PATH)."
  (jj-store-path (working-copy-store working-copy)))

(defun %snapshot (store)
  "Record the workspace's files into @ (jj's snapshot rules)."
  (run-jj store (list "util" "snapshot") :ignore-working-copy nil))

(defun %at (store)
  "Commit record of @ (no snapshot)."
  (or (first (%log store "@"))
      (error 'rev:revision-error :message "the workspace has no working-copy commit")))

(defun working-copy-revision (working-copy)
  "Snapshot, then → the REVISION of @, the working-copy commit."
  (let ((store (working-copy-store working-copy)))
    (%snapshot store)
    (%revision (%at store))))

(defmethod rev:target-revisions ((target jj-working-copy))
  (%record-parent-ids (%at (working-copy-store target))))

(defun %heads (store)
  (mapcar (lambda (r) (getf r :commit-id)) (%log store "heads(all())")))

(defun %new-change (store parent-cids message)
  "`jj new --no-edit -m MESSAGE P…` → the change id of the new commit."
  (let ((before (%heads store)))
    (run-jj store (append (list "new" "--no-edit" "-m" message)
                          (if parent-cids
                              (mapcar #'%cid-arg parent-cids)
                              (list "root()"))))
    (let* ((new (set-difference (%heads store) before :test #'string=))
           (record (and (= 1 (length new)) (%commit-record store (first new) (first new)))))
      (unless record
        (error 'rev:revision-error :message "cannot find the change jj new created"))
      (getf record :change-id))))

(defun %replace-at (store parent-cids message then)
  "Replace @ by a new change on PARENT-CIDS with @'s tree and MESSAGE; THEN
is :EDIT (the new change becomes @) or :NEW (@ becomes an empty child of
it). The old @ is abandoned. → the new change id. Writes no workspace file:
every tree jj checks out equals the tree on disk."
  (%snapshot store)
  (let* ((old (%at store))
         (old-cid (getf old :commit-id))
         (new (%new-change store parent-cids message)))
    (run-jj store (list "restore" "--from" old-cid "--into" new))
    (ecase then
      (:edit (run-jj store (list "edit" new) :ignore-working-copy nil))
      (:new (run-jj store (list "new" new) :ignore-working-copy nil)))
    (let ((old-now (first (%try-log store old-cid))))
      (when (and old-now (not (getf old-now :hidden)))
        (run-jj store (list "abandon" old-cid))))
    new))

(defmethod rev:target-stamp ((target jj-working-copy) revisions)
  (let* ((store (working-copy-store target))
         (records (mapcar (lambda (d) (%resolve-record store d)) revisions))
         (unique '()))
    (dolist (r records)
      (unless (find (%rid r) unique :key #'%rid :test #'string=)
        (push r unique)))
    (setf unique (nreverse unique))
    (%snapshot store)
    (%replace-at store (mapcar (lambda (r) (getf r :commit-id)) unique)
                 (getf (%at store) :description) :edit)
    (rev:target-revisions target)))

(defmethod rev:target-state ((target jj-working-copy))
  (let ((store (working-copy-store target)))
    (%snapshot store)
    (%state store (getf (%at store) :commit-id))))

(defmethod rev:target-drift ((target jj-working-copy) store)
  (declare (ignore store))
  (let ((store (working-copy-store target)))
    (%snapshot store)
    (let* ((at (%at store))
           (parents (remove +root-commit-id+ (getf at :parents) :test #'string=)))
      (when (rest parents)
        (error 'rev:revision-error
               :message "the working copy is stamped with several revisions"))
      (let ((stamp (or (first parents) +root-commit-id+))
            (cid (getf at :commit-id)))
        (unless (diff:state-equal (rev:content-engine store)
                                  (%state store stamp) (%state store cid))
          (%state-diff store stamp cid :changes nil))))))

(defun %capture-metaedit (store change valid-at provenance)
  "Give the captured CHANGE COMMIT-REVISION's author time (VALID-AT) and the
identities in PROVENANCE: `jj metaedit`, which rewrites it in place (same change
id) with the committer from --config user.name / user.email. @ is its
descendant, so the working copy is updated (its files do not change)."
  (when (or valid-at provenance)
    (let ((author-name (getf provenance :author-name))
          (author-email (getf provenance :author-email))
          (committer-name (getf provenance :committer-name))
          (committer-email (getf provenance :committer-email)))
      (run-jj store
              (append (list "metaedit" "-r" change)
                      (when valid-at
                        (list "--author-timestamp" (%rfc3339 valid-at)))
                      (when (or author-name author-email)
                        (let ((now (rev:revision-provenance (rev:resolve-revision store change))))
                          (list "--author"
                                (format nil "~a <~a>"
                                        (or author-name (getf now :author-name))
                                        (or author-email (getf now :author-email))))))
                      (when committer-name
                        (list "--config" (format nil "user.name=~a" committer-name)))
                      (when committer-email
                        (list "--config" (format nil "user.email=~a" committer-email))))
              :ignore-working-copy nil))))

(defmethod rev:capture-revision ((target jj-working-copy) store
                                 &key (parents nil parents-p) message provenance
                                   valid-at id)
  (declare (ignore store))
  (when id
    (error 'rev:revision-error :message "jj chooses revision ids; :ID is not accepted"))
  (check-type valid-at (or null dt:instant))
  (let ((store (working-copy-store target))
        (message (or message "capture")))
    (%snapshot store)
    (let ((change (if parents-p
                      (let ((cids (mapcar (lambda (d) (%resolve-cid store d)) parents)))
                        (%replace-at store cids message :new))
                      (let ((change (getf (%at store) :change-id)))
                        (run-jj store (list "commit" "-m" message) :ignore-working-copy nil)
                        change))))
      (%capture-metaedit store change valid-at provenance)
      (rev:resolve-revision store change))))

(defmethod rev:target-fidelities ((target jj-working-copy))
  nil)

(defmethod rev:target-transactional-p ((target jj-working-copy))
  nil)
