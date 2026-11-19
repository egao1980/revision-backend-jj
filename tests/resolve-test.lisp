(in-package #:revision-backend-jj/tests)

;;; RESOLVE-REVISION: revision fields against jj, ids under rewrite, every
;;; designator form, the root commit, prefixes, revsets, refs.

(defun jj-field (repo change template)
  (first (jj-log repo change template)))

(deftest revision-fields
  (with-test-repo (r)
    (let ((k (build-linear r)))
      (let* ((s (open-store r))
             (c2 (rev:resolve-revision s (getf k :c2))))
        (ok (rev:revision-p c2))
        (ok (equal (getf k :c2) (rev:revision-id c2)) "the full change id")
        (ok (= 32 (length (rev:revision-id c2))))
        (ok (equal (list (getf k :c1)) (rev:revision-parent-ids c2)))
        (ok (= (+ +t0+ 100) (unix (rev:revision-recorded-at c2))) "committer timestamp")
        (ok (= (- +t0+ 10000) (unix (rev:revision-valid-at c2))) "author timestamp")
        (ok (equal "second" (rev:revision-message c2)))
        (ok (equal (commit-of r (getf k :c2)) (rev:revision-content c2)) "content = commit id")
        (let ((p (rev:revision-provenance c2)))
          (ok (equal (commit-of r (getf k :c2)) (getf p :commit-id)))
          (ok (equal "Test User" (getf p :author-name)))
          (ok (equal "test@example.invalid" (getf p :author-email)))
          (ok (equal "Test User" (getf p :committer-name)))
          (ok (equal "test@example.invalid" (getf p :committer-email)))
          (ok (eq nil (getf p :conflict '%missing)))
          (ok (eq nil (getf p :empty '%missing))))
        (ok (equal (format nil "third~%~%with a body")
                   (rev:revision-message (rev:resolve-revision s (getf k :c3))))
            "one final newline removed, inner ones kept")
        (ok (null (rev:revision-parent-ids (rev:resolve-revision s (getf k :c1))))
            "a change on root() has no parents")
        (let ((wc (rev:resolve-revision s "@")))
          (ok (equal (getf k :wc) (rev:revision-id wc)))
          (ok (equal "" (rev:revision-message wc)))
          (ok (getf (rev:revision-provenance wc) :empty)))))))

(deftest merge-parent-order
  (with-test-repo (r)
    (let ((k (build-merge r)))
      (let ((x (rev:resolve-revision (open-store r) (getf k :x))))
        (ok (equal (list (getf k :m1) (getf k :f2)) (rev:revision-parent-ids x)))
        (ok (equal (jj-log r (getf k :x) "parents.map(|p| p.change_id()).join(\",\")")
                   (list (format nil "~{~a~^,~}" (rev:revision-parent-ids x))))
            "jj agrees on the order")))))

(deftest-parametrize designator-forms
    ((form) :ids ("change-id" "commit-id" "change-prefix" "commit-prefix" "revset-bookmark"
                  "revset-parent" "revset-description" "rev-ref" "rev-tag" "rev-parent"
                  "rev-ancestor" "revision-object")
     (:change-id) (:commit-id) (:change-prefix) (:commit-prefix) (:revset-bookmark)
     (:revset-parent) (:revset-description) (:rev-ref) (:rev-tag) (:rev-parent)
     (:rev-ancestor) (:revision-object))
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r))
           (c2 (getf k :c2))
           (designator
             (ecase form
               (:change-id c2)
               (:commit-id (commit-of r c2))
               (:change-prefix (subseq c2 0 12))
               (:commit-prefix (subseq (commit-of r c2) 0 12))
               (:revset-bookmark "main-")
               (:revset-parent (format nil "~a-" (getf k :c3)))
               (:revset-description "description(exact:\"second\\n\")")
               (:rev-ref (rev:rev-ancestor (rev:rev-ref "main") 1))
               (:rev-tag (rev:rev-tag "v2"))
               (:rev-parent (rev:rev-parent (rev:rev-ref "main")))
               (:rev-ancestor (rev:rev-ancestor (getf k :c3) 1))
               (:revision-object (rev:resolve-revision s c2)))))
      (ok (equal c2 (rev:revision-id (rev:resolve-revision s designator)))))))

(deftest-parametrize not-found-designators
    ((designator) :ids ("unknown-change" "unknown-commit" "short" "bad-revset" "unknown-symbol"
                        "empty-revset" "root-change" "root-commit" "root-revset")
     ("kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk")
     ("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
     ("qq")
     ("(((")
     ("no_such_bookmark")
     ("none()")
     ("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
     ("0000000000000000000000000000000000000000")
     ("root()"))
  (with-test-repo (r)
    (build-linear r)
    (let ((c (capture-condition (rev:revision-error)
               (rev:resolve-revision (open-store r) designator))))
      (ok (typep c 'rev:revision-not-found))
      (when c (ok (equal designator (rev:revision-not-found-designator c)))))))

(deftest not-found-protocol-designators
  (with-test-repo (r)
    (let ((k (build-linear r))
          (s nil))
      (setf s (open-store r))
      (ok (signals (rev:resolve-revision s (rev:rev-ref "nope")) 'rev:revision-not-found))
      (ok (signals (rev:resolve-revision s (rev:rev-tag "main")) 'rev:revision-not-found)
          "a bookmark is not a tag")
      (ok (signals (rev:resolve-revision s (rev:rev-parent (getf k :c1))) 'rev:revision-not-found)
          "the root commit is no parent")
      (ok (signals (rev:resolve-revision s (rev:rev-parent (getf k :c2) 2)) 'rev:revision-not-found))
      (ok (signals (rev:resolve-revision s (rev:rev-ancestor (getf k :c3) 3)) 'rev:revision-not-found)))))

(deftest ambiguous-revset
  (with-test-repo (r)
    (let ((k (build-merge r)))
      (let ((c (capture-condition (rev:ambiguous-revision)
                 (rev:resolve-revision (open-store r) (format nil "~a-" (getf k :x))))))
        (ok (typep c 'rev:ambiguous-revision) "a revset naming two commits")
        (when c
          (ok (set= (list (getf k :m1) (getf k :f2)) (rev:ambiguous-revision-candidates c))))))))

(deftest ambiguous-prefixes
  (with-test-repo (r)
    (build-many r)
    (let ((s (open-store r)))
      (multiple-value-bind (prefix matches)
          (colliding-prefix (jj-log r "all() ~ root()" "change_id"))
        (ok prefix "1024 random change ids share some 4-letter prefix")
        (when prefix
          (let ((c (capture-condition (rev:ambiguous-revision) (rev:resolve-revision s prefix))))
            (ok (typep c 'rev:ambiguous-revision))
            (when c
              (ok (equal matches (sort (copy-list (rev:ambiguous-revision-candidates c)) #'string<))
                  "every matching full change id"))))
        (when matches
          (ok (equal (first matches)
                     (rev:revision-id (rev:resolve-revision s (subseq (first matches) 0 20))))
              "a longer prefix is unique")))
      (multiple-value-bind (prefix matches)
          (colliding-prefix (jj-log r "all() ~ root()" "commit_id"))
        (when prefix
          (let ((c (capture-condition (rev:ambiguous-revision) (rev:resolve-revision s prefix))))
            (ok (typep c 'rev:ambiguous-revision) "commit id prefixes too")
            (when c
              (ok (equal matches (sort (copy-list (rev:ambiguous-revision-candidates c))
                                       #'string<))))))))))

(deftest refs-resolve-tag-first
  (with-test-repo (r)
    (let ((k (build-linear r)))
      (set-tag r "main" (getf k :c1) :at (+ +t0+ 500))
      (let ((s (open-store r)))
        (ok (equal (getf k :c1) (rev:revision-id (rev:resolve-revision s (rev:rev-ref "main"))))
            "the tag wins, as in jj's own symbol resolution")
        (ok (equal (change-of r "main") (getf k :c1)) "jj agrees")
        (ok (equal (getf k :c2) (rev:revision-id (rev:resolve-revision s (rev:rev-tag "v2")))))))))

(deftest rewrites-and-ids
  ;; A mutable change rewritten by jj keeps its revision id; the commit id
  ;; and REVISION objects pin the old snapshot.
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r))
           (old (rev:resolve-revision s (getf k :c3)))
           (old-commit (commit-of r (getf k :c3))))
      (jj* r (list "describe" "-r" (getf k :c3) "-m" "third, reworded") :ignore-working-copy t
           :env (time-env (+ +t0+ 400)))
      (let ((new (rev:resolve-revision s (getf k :c3))))
        (ok (equal (getf k :c3) (rev:revision-id new)) "same change id")
        (ok (equal (commit-of r (getf k :c3)) (getf (rev:revision-provenance new) :commit-id)))
        (ok (not (equal old-commit (rev:revision-content new))))
        (ok (equal "third, reworded" (rev:revision-message new)))
        (ok (= (+ +t0+ 400) (unix (rev:revision-recorded-at new))) "committer time moves")
        (ok (= (+ +t0+ 150) (unix (rev:revision-valid-at new))) "author time stays"))
      (let ((by-commit (rev:resolve-revision s old-commit)))
        (ok (equal (getf k :c3) (rev:revision-id by-commit)) "a hidden commit, by commit id")
        (ok (equal old-commit (rev:revision-content by-commit)))
        (ok (equal (format nil "third~%~%with a body") (rev:revision-message by-commit))))
      (let ((again (rev:resolve-revision s old)))
        (ok (equal old-commit (rev:revision-content again)) "a REVISION object pins its commit")
        (ok (equal (rev:revision-message old) (rev:revision-message again))))
      (ok (equal (format nil "third~%~%with a body") (rev:revision-message old))
          "the REVISION value itself never changed"))))

(deftest immutable-revisions-are-not-rewritten
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r))
           (before (rev:revision-content (rev:resolve-revision s (getf k :c2)))))
      (ok (equal "true" (jj-field r (getf k :c2) "immutable")) "tagged → immutable in jj")
      (ok (= 1 (nth-value 1 (jj* r (list "describe" "-r" (getf k :c2) "-m" "nope")
                                 :ignore-working-copy t :ok '(1))))
          "jj refuses to rewrite it")
      (ok (equal before (rev:revision-content (rev:resolve-revision s (getf k :c2))))))))

(deftest divergent-change
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (c3 (getf k :c3))
           (op (current-op r)))
      ;; Two concurrent rewrites of one change → two visible commits.
      (jj* r (list "--at-op" op "describe" "-r" c3 "-m" "left") :env (time-env (+ +t0+ 400)))
      (jj* r (list "--at-op" op "describe" "-r" c3 "-m" "right") :env (time-env (+ +t0+ 401)))
      (let* ((s (open-store r))
             (commits (sort (jj-log r (format nil "change_id(~a)" c3) "commit_id") #'string<)))
        (ok (= 2 (length commits)) "jj shows the change as divergent")
        (let ((c (capture-condition (rev:ambiguous-revision) (rev:resolve-revision s c3))))
          (ok (typep c 'rev:ambiguous-revision))
          (when c
            (ok (equal commits (sort (copy-list (rev:ambiguous-revision-candidates c)) #'string<))
                "candidates are the commit ids")))
        (dolist (commit commits)
          (let ((rv (rev:resolve-revision s commit)))
            (ok (equal commit (rev:revision-id rv)) "a divergent commit's id is its commit id")
            (ok (equal commit (rev:revision-content rv)))))))))
