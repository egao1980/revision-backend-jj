(in-package #:revision-backend-jj/tests)

;;; Conflicted revisions (:conflicted-revisions T): jj records an unresolved
;;; merge as a commit. A conflicted file appears in a state as its
;;; materialized conflict (ui.conflict-marker-style=diff, whatever the user
;;; configured), and REVISION-CONFLICTS names the paths.

(defun materialized (repo change path &key (style "diff"))
  (jj* repo (list "--config" (format nil "ui.conflict-marker-style=~a" style)
                  "file" "show" "-r" change (format nil "root-file:~s" path))
       :ignore-working-copy t :output :octets))

(deftest conflicted-revision-fields
  (with-test-repo (r)
    (let* ((k (build-conflict r))
           (s (open-store r)))
      (ok (equal "true" (jj-field r (getf k :m) "conflict")) "jj recorded the conflict")
      (ok (eq t (getf (rev:revision-provenance (rev:resolve-revision s (getf k :m))) :conflict)))
      (ok (null (getf (rev:revision-provenance (rev:resolve-revision s (getf k :left))) :conflict)))
      (ok (equal '(("a.txt" . 2)) (jj:revision-conflicts s (getf k :m))))
      (ok (equal '(("a.txt" . 2)) (jj:revision-conflicts s "@")) "@ inherits it")
      (ok (null (jj:revision-conflicts s (getf k :base))))
      (ok (signals (jj:revision-conflicts s "no_such_rev") 'rev:revision-not-found)))))

(deftest conflicted-file-in-a-state
  (with-test-repo (r :config (format nil "[ui]~%conflict-marker-style = \"snapshot\""))
    (let* ((k (build-conflict r))
           (s (open-store r))
           (state (rev:revision-state s (getf k :m)))
           (a (file-at state "a.txt"))
           (expected (materialized r (getf k :m) "a.txt")))
      (ok (not (equalp expected (materialized r (getf k :m) "a.txt" :style "snapshot")))
          "the user's style would print something else")
      (ok (and a (eq :text (diff:tree-file-type a))))
      (ok (and a (equalp expected (utf8 (diff:tree-file-content a))))
          "exactly jj's materialization with the fixed diff style")
      (ok (and a (= #o100644 (mode-of a))))
      (ok (and a (search "<<<<<<<" (diff:tree-file-content a))))
      (ok (equal (lines "other") (diff:tree-file-content (file-at state "other.txt")))
          "unconflicted files are plain"))))

(deftest conflicted-states-diff-and-apply
  (with-test-repo (r)
    (let* ((k (build-conflict r))
           (s (open-store r)))
      (dolist (level '(:summary :changes :content))
        (let ((d (rev:state-diff s (getf k :left) (getf k :m) :level level)))
          (ok (equal '(("a.txt")) (remove-duplicates (mapcar (lambda (p) (subseq p 0 1)) (change-paths d))
                                                     :test #'equal))
              (format nil "~(~a~): only a.txt differs" level))
          (ok (state= (rev:revision-state s (getf k :m))
                      (diff:apply-diff (rev:revision-state s (getf k :left)) d))
              (format nil "~(~a~): applies" level))))
      (ok (state= (rev:revision-state s (getf k :m))
                  (diff:apply-diff (rev:revision-state s (getf k :left)) (rev:revision-delta s (getf k :m))))
          "the merge's delta against its first parent"))))

(deftest resolving-a-conflict-is-a-new-commit-of-the-change
  (with-test-repo (r)
    (let* ((k (build-conflict r))
           (s (open-store r))
           (before (rev:resolve-revision s (getf k :m))))
      ;; Resolve in @ (a child of m) and squash it into m: m is rewritten.
      (put-file r "a.txt" (lines "resolved"))
      (jj* r (list "squash" "--into" (getf k :m) "--use-destination-message") :env (time-env (+ +t0+ 600)))
      (let ((after (rev:resolve-revision s (getf k :m))))
        (ok (equal (rev:revision-id before) (rev:revision-id after)) "same change")
        (ok (null (getf (rev:revision-provenance after) :conflict)))
        (ok (null (jj:revision-conflicts s (getf k :m))))
        (ok (equal '(("a.txt" . 2)) (jj:revision-conflicts s before))
            "the pinned old commit still has its conflict")))))
