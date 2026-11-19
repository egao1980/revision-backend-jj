(in-package #:revision-backend-jj/tests)

;;; The revision-protocol law rows that apply to a jj store.
;;;   Law 1: the graph is acyclic (jj chooses every id; caller ids are
;;;          refused, see commit-refusals-are-atomic); revisions never change
;;;          (REVISION values, commit-id designators and immutable change ids
;;;          — mutable change ids follow rewrites, see rewrites-and-ids); tags
;;;          never move (tags-never-move); ref CAS is linearizable for one
;;;          store shared by threads (the emulation serializes in the image).
;;;   Law 2: as-of is monotonic along its line, both axes, while ON only moves
;;;          forward (jj's default) — the recorded axis reads the op log.
;;;   Law 3: apply / inverse / self-diff (state-diff-laws in content-test,
;;;          conflicted states in conflict-test); revision deltas compose
;;;          associatively.
;;; Laws 4–6 (three-way, plans, projections) are not V2.

(defun snapshot (rv)
  (list (rev:revision-id rv) (rev:revision-parent-ids rv) (rev:revision-message rv)
        (rev:revision-content rv) (rev:revision-provenance rv)
        (unix (rev:revision-recorded-at rv)) (unix (rev:revision-valid-at rv))))

(deftest law-1-revisions-never-change
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r))
           (c2 (snapshot (rev:resolve-revision s (getf k :c2))))
           (c3-object (rev:resolve-revision s (getf k :c3)))
           (c3 (snapshot c3-object))
           (c3-commit (rev:revision-content c3-object)))
      (rev:commit-revision s (diff:make-tree) :ref "main" :message "later")
      (rev:move-ref s "main" (getf k :c1))
      (rev:tag-revision s "keep" (getf k :c2))
      (rev:delete-ref s "main")
      (jj* r (list "describe" "-r" (getf k :c3) "-m" "rewritten") :ignore-working-copy t
           :env (time-env (+ +t0+ 900)))
      (ok (equal c2 (snapshot (rev:resolve-revision s (getf k :c2)))) "an immutable change id")
      (ok (equal c3 (snapshot (rev:resolve-revision s c3-commit))) "a commit id, now hidden")
      (ok (equal c3 (snapshot (rev:resolve-revision s c3-object))) "a REVISION object")
      (ok (equal c3 (snapshot c3-object)) "the value itself"))))

(deftest law-1-returned-lists-are-not-shared
  (with-test-repo (r)
    (let* ((k (build-merge r))
           (s (open-store r))
           (rv (rev:resolve-revision s (getf k :x)))
           (parents (rev:revision-parent-ids rv))
           (prov (rev:revision-provenance rv)))
      (setf (first parents) "mallory"
            (getf prov :author-name) "mallory")
      (ok (equal (list (getf k :m1) (getf k :f2)) (rev:revision-parent-ids rv)))
      (ok (equal "Test User" (getf (rev:revision-provenance rv) :author-name)))
      (let ((targets (rev:target-revisions (jj:make-jj-working-copy s))))
        (setf (first targets) "mallory")
        (ok (equal (list (getf k :x)) (rev:target-revisions (jj:make-jj-working-copy s))))))))

(deftest-parametrize law-1-ref-cas-linearizable
    ((threads per-thread) :ids ("2x5" "3x4")
     (2 5)
     (3 4))
  ;; Workers commit onto main with the default parent (the tip), retrying on
  ;; REF-CONFLICT. Linearizable CAS ⇒ one line of THREADS × PER-THREAD + 1
  ;; revisions, main never conflicted, and jj agrees.
  (with-test-repo (r)
    (build-working-copy r)
    (let ((s (open-store r))
          (failures '())
          (lock (bt2:make-lock :name "failures")))
      (mapc #'bt2:join-thread
            (loop for i below threads
                  collect (let ((i i))
                            (bt2:make-thread
                             (lambda ()
                               (handler-case
                                   (handler-bind ((rev:ref-conflict
                                                    (lambda (c) (declare (ignore c))
                                                      (invoke-restart (find-restart 'rev:retry)))))
                                     (dotimes (n per-thread)
                                       (rev:commit-revision
                                        s (diff:make-tree "n.txt"
                                                          (diff:make-tree-file (format nil "~d ~d~%" i n)))
                                        :ref "main" :message (format nil "w~d n~d" i n))))
                                 (error (e)
                                   (bt2:with-lock-held (lock)
                                     (push (princ-to-string e) failures)))))
                             :name (format nil "committer ~d" i)))))
      (ok (null failures) (format nil "worker errors: ~{~a~^; ~}" (last failures 1)))
      (when (null failures)
        (let ((n (1+ (* threads per-thread))))
          (ok (= n (length (rev:walk-revisions s (rev:rev-ref "main") :order :first-parent))))
          (ok (= n (length (changes-of r "::main ~ root()"))) "no merges, no lost commits")
          (ok (= 1 (length (bookmark-target r "main"))) "main is not conflicted")
          (ok (null (jj:conflicted-bookmarks s))))))))

(deftest-parametrize law-2-as-of-monotonic
    ((axis t1 t2) :ids ("rec-15-50" "rec-50-250" "rec-120-120" "rec-150-1000"
                        "val-0-150" "val-minus-0" "val-149-150")
     (:recorded 20 50) (:recorded 50 250) (:recorded 120 120) (:recorded 150 1000)
     (:valid 0 150) (:valid -10000 0) (:valid 149 150))
  (with-test-repo (r)
    (build-linear r)
    (let ((s (open-store r)))
      (flet ((at (offset)
               (rev:resolve-revision s (rev:rev-as-of (instant (+ +t0+ offset)) :on "main" :axis axis))))
        (ok (rev:ancestor-p s (at t1) (at t2)) "earlier time → ancestor-or-self")))))

(deftest law-3-revision-deltas-compose-associatively
  (with-test-repo (r)
    (let* ((k (build-content r))
           (s (open-store r))
           (d1 (rev:revision-delta s (getf k :k1)))
           (d2 (rev:revision-delta s (getf k :k2)))
           (d3 (rev:revision-delta s (getf k :k3)))
           (empty (diff:make-tree))
           (s3 (rev:revision-state s (getf k :k3))))
      (ok (state= s3 (diff:apply-diff empty (diff:compose-diffs (diff:compose-diffs d1 d2) d3))))
      (ok (state= s3 (diff:apply-diff empty (diff:compose-diffs d1 (diff:compose-diffs d2 d3))))))))
