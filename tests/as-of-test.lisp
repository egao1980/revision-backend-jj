(in-package #:revision-backend-jj/tests)

;;; REV-AS-OF on both axes. :RECORDED reads the operation log (--at-op): the
;;; expected answer is computed here from `jj op log` and `jj --at-op`.

(defun op-at-or-before (repo unix)
  "Real jj: id of the operation with the largest end time <= UNIX (seconds),
or NIL."
  (let ((best nil) (best-end nil))
    (dolist (line (jj-lines repo "op" "log" "--no-graph" "-T"
                            "id ++ \" \" ++ time.end().format(\"%s%3f\") ++ \"\\n\""))
      (destructuring-bind (id end) (uiop:split-string line :separator '(#\Space))
        (let ((end (parse-integer end)))
          (when (and (<= end (* 1000 unix)) (or (null best-end) (> end best-end)))
            (setf best id best-end end)))))
    best))

(defun rewrite-c3 (repo k)
  "After BUILD-LINEAR: reword c3 at t0+400 (op t0+400). → the old commit id."
  (prog1 (commit-of repo (getf k :c3))
    (jj* repo (list "describe" "-r" (getf k :c3) "-m" "third, reworded") :ignore-working-copy t
         :env (time-env (+ +t0+ 400)))))

(deftest-parametrize as-of-recorded
    ((offset expected) :ids ("after-c1" "after-c2" "after-c3-before-rewrite" "after-rewrite"
                             "exactly-at-an-op")
     (50 :c1) (150 :c2) (250 :c3-old) (500 :c3-new) (120 :c2))
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (old (rewrite-c3 r k))
           (s (open-store r))
           (at (+ +t0+ offset))
           (op (op-at-or-before r at))
           (rv (rev:resolve-revision s (rev:rev-as-of (instant at) :on "main" :axis :recorded))))
      (ok op)
      (ok (equal (jj-log r "main" "change_id" :at-op op) (list (rev:revision-id rv)))
          "the revision main named at that operation")
      (ok (equal (jj-log r "main" "commit_id" :at-op op) (list (rev:revision-content rv)))
          "with the commit id it had then")
      (ecase expected
        (:c1 (ok (equal (getf k :c1) (rev:revision-id rv))))
        (:c2 (ok (equal (getf k :c2) (rev:revision-id rv))))
        (:c3-old (ok (equal (getf k :c3) (rev:revision-id rv)))
                 (ok (equal old (rev:revision-content rv)) "the pre-rewrite commit (now hidden)")
                 (ok (equal (format nil "third~%~%with a body") (rev:revision-message rv))))
        (:c3-new (ok (equal (commit-of r (getf k :c3)) (rev:revision-content rv)))
                 (ok (equal "third, reworded" (rev:revision-message rv))))))))

(deftest-parametrize as-of-recorded-not-found
    ((offset) :ids ("before-the-repo" "before-main-existed")
     (-5000) (15))
  (with-test-repo (r)
    (build-linear r)
    (ok (signals (rev:resolve-revision (open-store r)
                                       (rev:rev-as-of (instant (+ +t0+ offset)) :on "main"
                                                                                  :axis :recorded))
                 'rev:revision-not-found))))

(deftest as-of-recorded-on-a-change
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (old (rewrite-c3 r k))
           (s (open-store r)))
      (ok (equal old (rev:revision-content
                      (rev:resolve-revision s (rev:rev-as-of (instant (+ +t0+ 300)) :on (rev:rev-ref "main")))))
          "ON as a designator; :recorded is the default axis")
      (ok (equal old (rev:revision-content
                      (rev:resolve-revision s (rev:rev-as-of (instant (+ +t0+ 300))
                                                                    :on (rev:rev-ancestor (getf k :c3) 0)
                                                                    :axis :recorded))))
          "a change id (wrapped: a bare string ON is a ref name) resolves at that operation too"))))

(deftest-parametrize as-of-valid
    ((offset expected) :ids ("before-c3-author" "c3-author" "far-past-c2" "after-all")
     (100 :c2) (150 :c3) (-10000 :c2) (1000 :c3))
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (rv (rev:resolve-revision (open-store r)
                                     (rev:rev-as-of (instant (+ +t0+ offset)) :on "main" :axis :valid))))
      (ok (equal (getf k expected) (rev:revision-id rv))
          "first parents of main: c3 (author t0+150), c2 (t0-10000), c1 (t0)"))))

(deftest as-of-valid-not-found
  (with-test-repo (r)
    (build-linear r)
    (ok (signals (rev:resolve-revision (open-store r)
                                       (rev:rev-as-of (instant (- +t0+ 20000)) :on "main" :axis :valid))
                 'rev:revision-not-found))))
