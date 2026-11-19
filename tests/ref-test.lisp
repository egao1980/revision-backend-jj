(in-package #:revision-backend-jj/tests)

;;; Refs: bookmarks and tags, CAS emulated over the operation log, restarts,
;;; tag rules, conflicted bookmarks, the listener; every update is checked
;;; against the real jj.

(defun bookmark-target (repo name)
  "Real jj: change ids the local bookmark NAME points at (several when
conflicted; NIL when absent), sorted."
  (sort (remove "" (jj-lines repo "bookmark" "list" "-T"
                             (format nil "if(!remote && name == ~s, added_targets.map(|c| c.change_id()).join(\"\\n\") ++ \"\\n\")"
                                     name))
                :test #'string=)
        #'string<))

(defun tag-target (repo name)
  (first (jj-lines repo "tag" "list" "-T"
                   (format nil "if(name == ~s, added_targets.map(|c| c.change_id()).join(\"\\n\") ++ \"\\n\")"
                           name))))

(defun conflict-main (repo k)
  "Make bookmark main (on :x of BUILD-MERGE) conflicted: two concurrent
operations move it to :m1 and to :f2. → the sorted pair of change ids."
  (let ((op (current-op repo)))
    (jj* repo (list "--at-op" op "bookmark" "set" "main" "-r" (getf k :m1) "--allow-backwards")
         :env (time-env (+ +t0+ 500)))
    (jj* repo (list "--at-op" op "bookmark" "set" "main" "-r" (getf k :f2) "--allow-backwards")
         :env (time-env (+ +t0+ 501)))
    (sort (list (getf k :m1) (getf k :f2)) #'string<)))

(deftest find-ref-and-list-refs
  (with-test-repo (r)
    (let ((k (build-linear r)))
      (set-bookmark r "feature/x" (getf k :c1) :at (+ +t0+ 400))
      (let ((s (open-store r)))
        (ok (null (rev:find-ref s "nope")))
        (let ((main (rev:find-ref s "main")))
          (ok (rev:revision-ref-p main))
          (ok (eq :movable (rev:ref-kind main)))
          (ok (equal (getf k :c3) (rev:ref-target main)) "target = the change id")
          (ok (null (rev:ref-annotation main))))
        (let ((v1 (rev:find-ref s "v1")))
          (ok (eq :tag (rev:ref-kind v1)))
          (ok (equal (getf k :c1) (rev:ref-target v1)))
          (ok (null (rev:ref-annotation v1)) "jj tags have no annotation"))
        (ok (equal '("feature/x" "main" "v1" "v2") (mapcar #'rev:ref-name (rev:list-refs s))))
        (ok (equal '("feature/x" "main") (mapcar #'rev:ref-name (rev:list-refs s :kind :movable))))
        (ok (equal '("v1" "v2") (mapcar #'rev:ref-name (rev:list-refs s :kind :tag))))
        (ok (equal '("feature/x") (mapcar #'rev:ref-name (rev:list-refs s :prefix "feature/"))))))))

(deftest bookmark-and-tag-share-a-name
  (with-test-repo (r)
    (let ((k (build-linear r)))
      (set-tag r "main" (getf k :c1) :at (+ +t0+ 400))
      (let* ((s (open-store r))
             (refs (remove "main" (rev:list-refs s) :key #'rev:ref-name :test-not #'string=)))
        (ok (equal '(:movable :tag) (mapcar #'rev:ref-kind refs)) "both listed, bookmark first")
        (ok (eq :tag (rev:ref-kind (rev:find-ref s "main"))) "find-ref picks the tag")
        (ok (signals (rev:move-ref s "main" (getf k :c2)) 'rev:tag-immutable))
        (ok (equal (list (getf k :c3)) (bookmark-target r "main")) "bookmark untouched")))))

(deftest remote-bookmarks-are-not-refs
  (with-test-repo (r)
    (let ((k (build-linear r)))
      (declare (ignore k))
      ;; Colocated: jj shows main@git; it must not appear as a protocol ref.
      (ok (equal '("main" "v1" "v2") (mapcar #'rev:ref-name (rev:list-refs (open-store r))))))))

(deftest move-ref-updates-jj
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r)))
      (let ((ref (rev:move-ref s "topic" (getf k :c1))))
        (ok (equal "topic" (rev:ref-name ref)))
        (ok (eq :movable (rev:ref-kind ref)))
        (ok (equal (getf k :c1) (rev:ref-target ref))))
      (ok (equal (list (getf k :c1)) (bookmark-target r "topic")) "a real bookmark")
      (rev:move-ref s "topic" (rev:rev-ref "main"))
      (ok (equal (list (getf k :c3)) (bookmark-target r "topic")))
      (rev:move-ref s "topic" (getf k :c2))
      (ok (equal (list (getf k :c2)) (bookmark-target r "topic")) "backwards is allowed")
      (ok (signals (rev:move-ref s "topic" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
                   'rev:revision-not-found))
      (ok (equal (list (getf k :c2)) (bookmark-target r "topic")) "unchanged after a failure")
      (ok (signals (rev:move-ref s "topic" "root()") 'rev:revision-not-found)
          "the root commit is no target"))))

(deftest move-ref-cas
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r)))
      (testing "matching expected"
        (rev:move-ref s "main" (getf k :c2) :expected (getf k :c3))
        (ok (equal (list (getf k :c2)) (bookmark-target r "main"))))
      (testing "expected NIL: create only"
        (rev:move-ref s "fresh" (getf k :c1) :expected nil)
        (ok (equal (list (getf k :c1)) (bookmark-target r "fresh")))
        (ok (signals (rev:move-ref s "fresh" (getf k :c2) :expected nil) 'rev:ref-conflict)))
      (testing "stale expected"
        (let ((c (capture-condition (rev:ref-conflict)
                   (rev:move-ref s "main" (getf k :c1) :expected (getf k :c3)))))
          (ok (typep c 'rev:ref-conflict))
          (when c
            (ok (equal "main" (rev:ref-conflict-name c)))
            (ok (equal (getf k :c3) (rev:ref-conflict-expected c)))
            (ok (equal (getf k :c2) (rev:ref-conflict-actual c)))))
        (ok (equal (list (getf k :c2)) (bookmark-target r "main"))))
      (testing "another jj process moved the bookmark"
        (set-bookmark r "main" (getf k :c1) :at (+ +t0+ 600))
        (let ((c (capture-condition (rev:ref-conflict)
                   (rev:move-ref s "main" (getf k :c3) :expected (getf k :c2)))))
          (ok (typep c 'rev:ref-conflict))
          (when c (ok (equal (getf k :c1) (rev:ref-conflict-actual c))))))
      (testing "expected matches by change id across a rewrite"
        (rev:move-ref s "topic" (getf k :c3))
        (jj* r (list "describe" "-r" (getf k :c3) "-m" "reworded") :ignore-working-copy t
             :env (time-env (+ +t0+ 700)))
        (rev:move-ref s "topic" (getf k :c2) :expected (getf k :c3))
        (ok (equal (list (getf k :c2)) (bookmark-target r "topic")))))))

(deftest ref-conflict-restarts
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r)))
      (testing "restarts offered (no force by default)"
        (let ((names (restart-names-in 'rev:ref-conflict
                                       (lambda () (rev:move-ref s "main" (getf k :c1)
                                                                :expected (getf k :c2))))))
          (ok (member 'rev:use-current names))
          (ok (member 'rev:retry names))
          (ok (not (member 'rev:force names)))))
      (testing "use-current returns the current ref unchanged"
        (let ((result (invoking (rev:ref-conflict rev:use-current)
                        (rev:move-ref s "main" (getf k :c1) :expected (getf k :c2)))))
          (ok (equal (getf k :c3) (rev:ref-target result)))
          (ok (equal (list (getf k :c3)) (bookmark-target r "main")))))
      (testing "retry moves with expected = current"
        (let ((result (invoking (rev:ref-conflict rev:retry)
                        (rev:move-ref s "main" (getf k :c1) :expected (getf k :c2)))))
          (ok (equal (getf k :c1) (rev:ref-target result)))
          (ok (equal (list (getf k :c1)) (bookmark-target r "main")))))
      (testing "commit-revision on a moved ref: use-current returns the tip, nothing committed"
        (let* ((heads-before (sort (jj-log r "heads(all())" "commit_id") #'string<))
               (result (invoking (rev:ref-conflict rev:use-current)
                         (rev:commit-revision s (getf k :c2) :ref "main"
                                              :expected (getf k :c3) :message "lost"))))
          (ok (equal (getf k :c1) (rev:revision-id result)))
          (ok (equal (list (getf k :c1)) (bookmark-target r "main")) "nothing moved")
          (ok (equal heads-before (sort (jj-log r "heads(all())" "commit_id") #'string<))
              "no new visible commit"))))))

(deftest force-restart-is-gated
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r :permit-force (lambda (name) (string= name "scratch")))))
      (ok (rev:permit-force-p s "scratch"))
      (ok (not (rev:permit-force-p s "main")))
      (ok (not (rev:permit-force-p (open-store r) "scratch")) "default NIL")
      (ok (rev:permit-force-p (open-store r :permit-force t) "anything"))
      (rev:move-ref s "scratch" (getf k :c1))
      (ok (member 'rev:force
                  (restart-names-in 'rev:ref-conflict
                                    (lambda () (rev:move-ref s "scratch" (getf k :c2)
                                                             :expected (getf k :c3))))))
      (ok (not (member 'rev:force
                       (restart-names-in 'rev:ref-conflict
                                         (lambda () (rev:move-ref s "main" (getf k :c2)
                                                                  :expected (getf k :c1)))))))
      (let ((result (invoking (rev:ref-conflict rev:force)
                      (rev:move-ref s "scratch" (getf k :c2) :expected (getf k :c3)))))
        (ok (equal (getf k :c2) (rev:ref-target result)))
        (ok (equal (list (getf k :c2)) (bookmark-target r "scratch")))))))

(deftest tags-never-move
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r)))
      (let ((c (capture-condition (rev:tag-immutable) (rev:move-ref s "v1" (getf k :c3)))))
        (ok (typep c 'rev:tag-immutable))
        (when c
          (ok (equal "v1" (rev:tag-immutable-name c)))))
      (ok (member 'rev:create-new-tag
                  (restart-names-in 'rev:tag-immutable
                                    (lambda () (rev:move-ref s "v1" (getf k :c3))))))
      (let ((result (invoking (rev:tag-immutable rev:create-new-tag "v3")
                      (rev:move-ref s "v1" (getf k :c3)))))
        (ok (equal "v3" (rev:ref-name result)))
        (ok (eq :tag (rev:ref-kind result)))
        (ok (equal (getf k :c3) (tag-target r "v3")) "a real jj tag"))
      (ok (equal (getf k :c1) (tag-target r "v1")) "v1 untouched")
      (ok (signals (rev:delete-ref s "v1") 'rev:tag-immutable))
      (ok (signals (rev:commit-revision s (diff:make-tree) :ref "v1") 'rev:tag-immutable))
      (ok (equal (getf k :c1) (tag-target r "v1"))))))

(deftest tag-revision-rules
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r))
           (op-count (length (jj-log-ops r))))
      (testing "new tag"
        (let ((tag (rev:tag-revision s "v9" (getf k :c3))))
          (ok (eq :tag (rev:ref-kind tag)))
          (ok (equal (getf k :c3) (rev:ref-target tag)))
          (ok (null (rev:ref-annotation tag)))
          (ok (equal (getf k :c3) (tag-target r "v9")))
          (ok (equal "true" (jj-field r (getf k :c3) "immutable")) "tagging makes it immutable")))
      (testing "same target: idempotent, nothing written"
        (let ((ops (length (jj-log-ops r))))
          (ok (equal (getf k :c3) (rev:ref-target (rev:tag-revision s "v9" (getf k :c3)))))
          (ok (= ops (length (jj-log-ops r))) "no new operation")))
      (testing "other target"
        (let ((c (capture-condition (rev:tag-immutable) (rev:tag-revision s "v9" (getf k :c1)))))
          (ok (typep c 'rev:tag-immutable))
          (when c (ok (equal "v9" (rev:tag-immutable-name c))))))
      (testing "over a bookmark"
        (let ((c (capture-condition (rev:ref-conflict) (rev:tag-revision s "main" (getf k :c1)))))
          (ok (typep c 'rev:ref-conflict))
          (when c
            (ok (null (rev:ref-conflict-expected c)))
            (ok (equal (getf k :c3) (rev:ref-conflict-actual c)))))
        (ok (null (tag-target r "main"))))
      (testing "annotations are refused"
        (ok (signals (rev:tag-revision s "v10" (getf k :c1) :annotation "notes")
                     'rev:revision-error))
        (ok (null (tag-target r "v10"))))
      (ok (< op-count (length (jj-log-ops r)))))))

(deftest delete-ref-rules
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r)))
      (rev:move-ref s "gone" (getf k :c1))
      (ok (eq t (rev:delete-ref s "gone")))
      (ok (null (bookmark-target r "gone")))
      (ok (null (rev:find-ref s "gone")))
      (ok (signals (rev:delete-ref s "gone") 'rev:revision-not-found))
      (rev:move-ref s "kept" (getf k :c1))
      (let ((c (capture-condition (rev:ref-conflict)
                 (rev:delete-ref s "kept" :expected (getf k :c2)))))
        (ok (typep c 'rev:ref-conflict))
        (when c (ok (equal (getf k :c1) (rev:ref-conflict-actual c)))))
      (ok (null (invoking (rev:ref-conflict rev:use-current)
                  (rev:delete-ref s "kept" :expected (getf k :c2)))))
      (ok (equal (list (getf k :c1)) (bookmark-target r "kept")) "use-current keeps it")
      (invoking (rev:ref-conflict rev:retry)
        (rev:delete-ref s "kept" :expected (getf k :c2)))
      (ok (null (bookmark-target r "kept")) "retry deletes")
      (ok (eq t (rev:delete-ref s "main" :expected (getf k :c3))))
      (ok (equal (getf k :c3) (change-of r (getf k :c3))) "the change stays visible"))))

(deftest ref-listener-events
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r))
           (events '()))
      (ok (null (rev:ref-listener s)))
      (setf (rev:ref-listener s) (lambda (e) (push e events)))
      (rev:move-ref s "topic" (getf k :c1))
      (rev:move-ref s "topic" (getf k :c2))
      (rev:tag-revision s "v5" (getf k :c3))
      (rev:tag-revision s "v5" (getf k :c3))
      (ignore-errors (rev:move-ref s "topic" (getf k :c3) :expected (getf k :c1)))
      (rev:delete-ref s "topic")
      (let ((c (rev:commit-revision s (getf k :c3) :ref "made" :message "m")))
        (ok (equal (list (list :ref-moved "topic" nil (getf k :c1))
                         (list :ref-moved "topic" (getf k :c1) (getf k :c2))
                         (list :ref-moved "v5" nil (getf k :c3))
                         (list :ref-moved "topic" (getf k :c2) nil)
                         (list :ref-moved "made" nil (rev:revision-id c)))
                   (reverse events))
            "one event per change; none for idempotent or failed updates"))
      (setf (rev:ref-listener s) nil)
      (rev:move-ref s "quiet" (getf k :c1))
      (ok (= 5 (length events))))))

(deftest conflicted-bookmarks
  (with-test-repo (r :colocate nil)
    (let* ((k (build-merge r))
           (pair (conflict-main r k))
           (s (open-store r)))
      (ok (equal pair (bookmark-target r "main")) "jj left main conflicted")
      (ok (equal (list (cons "main" pair)) (jj:conflicted-bookmarks s)))
      (ok (equal '("feature") (mapcar #'rev:ref-name (rev:list-refs s)))
          "list-refs leaves it out")
      (testing "find-ref signals ref-conflict"
        (let ((c (capture-condition (rev:ref-conflict) (rev:find-ref s "main"))))
          (ok (typep c 'rev:ref-conflict))
          (when c
            (ok (equal "main" (rev:ref-conflict-name c)))
            (ok (equal pair (rev:ref-conflict-actual c)))))
        (ok (null (invoking (rev:ref-conflict rev:use-current) (rev:find-ref s "main")))))
      (testing "rev-ref is ambiguous"
        (let ((c (capture-condition (rev:ambiguous-revision)
                   (rev:resolve-revision s (rev:rev-ref "main")))))
          (ok (typep c 'rev:ambiguous-revision))
          (when c (ok (equal pair (sort (copy-list (rev:ambiguous-revision-candidates c)) #'string<))))))
      (testing "a CAS against a conflicted bookmark"
        (let ((names (restart-names-in 'rev:ref-conflict
                                       (lambda () (rev:move-ref s "main" (getf k :x)
                                                                :expected (getf k :m1))))))
          (ok (member 'rev:use-current names))
          (ok (not (member 'rev:retry names)) "no single current value to retry with"))
        (let ((c (capture-condition (rev:ref-conflict)
                   (rev:move-ref s "main" (getf k :x) :expected (getf k :m1)))))
          (when c (ok (equal pair (rev:ref-conflict-actual c)))))
        (ok (null (invoking (rev:ref-conflict rev:use-current)
                    (rev:move-ref s "main" (getf k :x) :expected (getf k :m1)))))
        (ok (equal pair (bookmark-target r "main")) "still conflicted"))
      (testing "an unconditional move resolves it"
        (rev:move-ref s "main" (getf k :x))
        (ok (equal (list (getf k :x)) (bookmark-target r "main")))
        (ok (null (jj:conflicted-bookmarks s)))))))

(deftest force-resolves-a-conflicted-bookmark
  (with-test-repo (r :colocate nil)
    (let* ((k (build-merge r))
           (pair (conflict-main r k))
           (s (open-store r :permit-force t)))
      (ok (equal pair (bookmark-target r "main")))
      (let ((result (invoking (rev:ref-conflict rev:force)
                      (rev:move-ref s "main" (getf k :base) :expected (getf k :m1)))))
        (ok (equal (getf k :base) (rev:ref-target result)))
        (ok (equal (list (getf k :base)) (bookmark-target r "main")))))))
