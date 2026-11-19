(in-package #:revision-backend-jj/tests)

;;; Parsers of the backend's own -T templates: hand corpora, live output of
;;; the exported templates run by the real jj, malformed input, fuzz.

(defparameter +h1+ "1111111111111111111111111111111111111111")
(defparameter +h2+ "2222222222222222222222222222222222222222")
(defparameter +c1+ "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk")
(defparameter +c2+ "lmnopqrstuvwxyzklmnopqrstuvwxyzk")

(defun json-line (&rest parts)
  (format nil "~{~a~}~%" parts))

(defun json-crlf (&rest parts)
  (format nil "~{~a~}~c~c" parts #\Return #\Newline))

(deftest parse-commit-records-corpus
  (let* ((input (concatenate
                 'string
                 (json-crlf "{\"change_id\":\"" +c1+ "\",\"commit_id\":\"" +h1+ "\","
                            "\"parents\":[\"" +h2+ "\",\"0000000000000000000000000000000000000000\"],"
                            "\"parent_change_ids\":[\"" +c2+ "\",\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"],"
                            "\"parent_divergent\":[true,false],"
                            "\"description\":\"line one\\n\\nbody \\\"quoted\\\" \\u00e9 \\\\ end\\n\","
                            "\"author\":{\"name\":\"A Person\",\"email\":\"a@example.invalid\",\"time\":1699990000},"
                            "\"committer\":{\"name\":\"C Person\",\"email\":\"c@example.invalid\",\"time\":1700000000},"
                            "\"conflict\":true,\"divergent\":false,\"immutable\":true,\"empty\":false,"
                            "\"hidden\":false,\"root\":false,\"working_copy\":false}")
                 (string #\Newline) ; blank lines are skipped (and CR LF above tolerated)
                 (json-line "{\"change_id\":\"" +c2+ "\",\"commit_id\":\"" +h2+ "\",\"parents\":[],"
                            "\"parent_change_ids\":[],\"parent_divergent\":[],\"description\":\"\","
                            "\"author\":{\"name\":\"\",\"email\":\"\",\"time\":0},"
                            "\"committer\":{\"name\":\"\",\"email\":\"\",\"time\":0},"
                            "\"conflict\":false,\"divergent\":true,\"immutable\":false,\"empty\":true,"
                            "\"hidden\":true,\"root\":false,\"working_copy\":true}")))
         (records (jj:parse-commit-records input)))
    (ok (= 2 (length records)))
    (ok (plist-matches-p
         (list :change-id +c1+ :commit-id +h1+
               :parents (list +h2+ "0000000000000000000000000000000000000000")
               :parent-change-ids (list +c2+ "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
               :parent-divergent (list t nil)
               :description (format nil "line one~%~%body \"quoted\" ~c \\ end~%" (code-char 233))
               :author-name "A Person" :author-email "a@example.invalid" :author-time 1699990000
               :committer-name "C Person" :committer-email "c@example.invalid"
               :committer-time 1700000000
               :conflict t :divergent nil :immutable t :empty nil :hidden nil :root nil
               :working-copy nil)
         (first records)))
    (ok (plist-matches-p (list :parents nil :parent-change-ids nil :description ""
                               :divergent t :empty t :hidden t :working-copy t)
                         (second records)))
    (ok (null (jj:parse-commit-records "")))))

(deftest parse-operation-records-corpus
  (let ((records (jj:parse-operation-records
                  (concatenate
                   'string
                   (json-line "{\"id\":\"ab12\",\"parents\":[\"cd34\",\"ef56\"],\"start_ms\":\"1700000000123\","
                              "\"end_ms\":\"1700000000456\",\"description\":\"reconcile divergent operations\","
                              "\"snapshot\":false,\"root\":false}")
                   (json-line "{\"id\":\"0000\",\"parents\":[],\"start_ms\":\"0000\",\"end_ms\":\"0000\","
                              "\"description\":\"\",\"snapshot\":false,\"root\":true}")))))
    (ok (= 2 (length records)))
    (ok (plist-matches-p '(:id "ab12" :parents ("cd34" "ef56") :start-ms 1700000000123
                           :end-ms 1700000000456 :description "reconcile divergent operations"
                           :snapshot nil :root nil)
                         (first records)))
    (ok (plist-matches-p '(:parents nil :root t :start-ms 0 :end-ms 0) (second records)))
    (ok (signals (jj:parse-operation-records
                  (json-line "{\"id\":\"x\",\"parents\":[],\"start_ms\":\"12a\",\"end_ms\":\"1\","
                             "\"description\":\"\",\"snapshot\":false,\"root\":false}"))
                 'rev:revision-error)
        "a time that is not digits")))

(deftest parse-ref-records-corpus
  (let ((records (jj:parse-ref-records
                  (concatenate
                   'string
                   (json-line "{\"name\":\"feature/x y\",\"conflict\":false,\"targets\":[\"" +h1+ "\"],"
                              "\"target_change_ids\":[\"" +c1+ "\"]}")
                   (json-line "{\"name\":\"main\",\"conflict\":true,\"targets\":[\"" +h1+ "\",\"" +h2+ "\"],"
                              "\"target_change_ids\":[\"" +c1+ "\",\"" +c2+ "\"]}")))))
    (ok (equal '("feature/x y" "main") (mapcar (lambda (r) (getf r :name)) records)))
    (ok (plist-matches-p (list :conflict nil :targets (list +h1+) :target-change-ids (list +c1+))
                         (first records)))
    (ok (plist-matches-p (list :conflict t :targets (list +h1+ +h2+)
                               :target-change-ids (list +c1+ +c2+))
                         (second records)))))

(deftest-parametrize parse-file-records-types
    ((type keyword) :ids ("file" "symlink" "tree" "submodule" "conflict")
     ("file" :file) ("symlink" :symlink) ("tree" :tree) ("git-submodule" :git-submodule)
     ("conflict" :conflict))
  (let ((r (first (jj:parse-file-records
                   (json-line "{\"path\":\"dir/a b.txt\",\"type\":\"" type "\",\"executable\":true,"
                              "\"conflict\":false,\"sides\":1}")))))
    (ok (plist-matches-p (list :path "dir/a b.txt" :type keyword :executable t :conflict nil :sides 1)
                         r))))

(deftest-parametrize parse-diff-records-statuses
    ((status keyword) :ids ("modified" "added" "removed" "copied" "renamed")
     ("modified" :modified) ("added" :added) ("removed" :removed) ("copied" :copied)
     ("renamed" :renamed))
  (let ((r (first (jj:parse-diff-records
                   (json-line "{\"status\":\"" status "\",\"source\":\"old/a.txt\",\"path\":\"new/a.txt\","
                              "\"source_type\":\"\",\"target_type\":\"symlink\","
                              "\"source_executable\":false,\"target_executable\":true}")))))
    (ok (plist-matches-p (list :status keyword :source "old/a.txt" :path "new/a.txt"
                               :source-type nil :target-type :symlink
                               :source-executable nil :target-executable t)
                         r))))

;;; ---- live output of the exported templates --------------------------

(deftest live-commit-template
  (with-test-repo (r)
    (let* ((k (build-merge r))
           (out (jj* r (list "log" "--no-graph" "-r" "all()" "-T" jj:*commit-template*)
                     :ignore-working-copy t))
           (records (jj:parse-commit-records out))
           (x (find (getf k :x) records :key (lambda (p) (getf p :change-id)) :test #'equal)))
      (ok (= (length (jj-log r "all()" "change_id")) (length records)) "one record per commit")
      (ok (equal (jj-log r "all()" "commit_id") (mapcar (lambda (p) (getf p :commit-id)) records)))
      (ok x)
      (when x
        (ok (equal (list (getf k :m1) (getf k :f2)) (getf x :parent-change-ids)) "parent order")
        (ok (equal (jj-log r (format nil "~a-" (getf k :x)) "commit_id") (getf x :parents)))
        (ok (equal (lines "merge feature") (getf x :description)))
        (ok (= (+ +t0+ 400) (getf x :committer-time)))
        (ok (equal "Test User" (getf x :author-name)))
        (ok (equal "test@example.invalid" (getf x :committer-email))))
      (let ((f1 (find (getf k :f1) records :key (lambda (p) (getf p :change-id)) :test #'equal)))
        (ok (and f1 (= (- +t0+ 5000) (getf f1 :author-time)))))
      (ok (getf (find "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" records
                      :key (lambda (p) (getf p :change-id)) :test #'equal)
                :root)
          "the root commit is a record with :root t")
      (ok (= 1 (count-if (lambda (p) (getf p :working-copy)) records))))))

(deftest live-operation-template
  (with-test-repo (r)
    (build-linear r)
    (let ((records (jj:parse-operation-records
                    (jj* r (list "op" "log" "--no-graph" "-T" jj:*operation-template*)
                         :ignore-working-copy t))))
      (ok (equal (jj-log-ops r) (mapcar (lambda (o) (getf o :id)) records)))
      (ok (= (* 1000 (+ +t0+ 300)) (getf (first records) :end-ms)))
      (ok (getf (car (last records)) :root)))))

(deftest live-ref-template
  (with-test-repo (r)
    (let ((k (build-linear r)))
      (let ((bookmarks (jj:parse-ref-records
                        (jj* r (list "bookmark" "list" "-T" jj:*ref-template*) :ignore-working-copy t)))
            (tags (jj:parse-ref-records
                   (jj* r (list "tag" "list" "-T" jj:*ref-template*) :ignore-working-copy t))))
        (ok (equal '("main") (mapcar (lambda (b) (getf b :name)) bookmarks))
            "local bookmarks only (no main@git)")
        (ok (equal (list (getf k :c3)) (getf (first bookmarks) :target-change-ids)))
        (ok (equal '("v1" "v2") (mapcar (lambda (b) (getf b :name)) tags)))
        (ok (equal (list (commit-of r (getf k :c1))) (getf (first tags) :targets)))))))

(deftest live-file-template
  (with-test-repo (r)
    (let* ((k (build-content r))
           (records (jj:parse-file-records
                     (jj* r (list "file" "list" "-r" (getf k :k2) "-T" jj:*file-template*)
                          :ignore-working-copy t))))
      (ok (equal (jj-lines r "file" "list" "-r" (getf k :k2) "-T" "path ++ \"\\n\"")
                 (mapcar (lambda (f) (getf f :path)) records)))
      (let ((run (find "run.sh" records :key (lambda (f) (getf f :path)) :test #'equal)))
        (ok (and run (getf run :executable) (eq :file (getf run :type)))))
      (unless (windows-p)
        (ok (eq :symlink (getf (find "link" records :key (lambda (f) (getf f :path)) :test #'equal)
                               :type)))))))

(deftest live-diff-template
  (with-test-repo (r)
    (let* ((k (build-content r))
           (records (jj:parse-diff-records
                     (jj* r (list "diff" "--from" (getf k :k1) "--to" (getf k :k2)
                                  "-T" jj:*diff-template*)
                          :ignore-working-copy t))))
      (ok (equal (jj-lines r "diff" "--from" (getf k :k1) "--to" (getf k :k2) "-T" "path ++ \"\\n\"")
                 (mapcar (lambda (f) (getf f :path)) records)))
      (let ((empty (find "empty.txt" records :key (lambda (f) (getf f :path)) :test #'equal)))
        (ok (and empty (eq :removed (getf empty :status)) (null (getf empty :target-type))))))))

;;; ---- malformed input and fuzz -----------------------------------------

(defparameter +parsers+
  (list #'jj:parse-commit-records #'jj:parse-operation-records #'jj:parse-ref-records
        #'jj:parse-file-records #'jj:parse-diff-records))

(deftest-parametrize malformed-input-signals-revision-error
    ((input) :ids ("not-json" "array" "truncated" "missing-keys" "wrong-type" "bad-enum")
     ((json-line "hello"))
     ((json-line "[1,2,3]"))
     ((json-line "{\"change_id\":\"abc"))
     ((json-line "{}"))
     ((json-line "{\"change_id\":1,\"id\":2,\"name\":3,\"path\":4,\"status\":5}"))
     ((json-line "{\"path\":\"a\",\"type\":\"socket\",\"executable\":false,\"conflict\":false,\"sides\":1,"
                 "\"status\":\"exploded\",\"source\":\"a\",\"source_type\":\"\",\"target_type\":\"\","
                 "\"source_executable\":false,\"target_executable\":false}")))
  (dolist (parse +parsers+)
    (ok (signals (funcall parse input) 'rev:revision-error))))

(defun fuzz-string (state)
  (let ((alphabet "{}[]\":,\\ntrue01falsenull ab\"{\"path\":")
        (n (random 80 state)))
    (with-output-to-string (s)
      (dotimes (i n)
        (if (zerop (random 12 state))
            (write-char #\Newline s)
            (write-char (char alphabet (random (length alphabet) state)) s))))))

(deftest-parametrize parsers-never-signal-other-conditions
    ((seed) :ids ("seed-1" "seed-2" "seed-3" "seed-4" "seed-5")
     (1) (2) (3) (4) (5))
  (let ((state (sb-ext:seed-random-state seed))
        (bad '()))
    (dotimes (i 200)
      (let ((input (fuzz-string state)))
        (dolist (parse +parsers+)
          (handler-case (let ((result (funcall parse input)))
                          (unless (listp result) (push (list :not-a-list input) bad)))
            (rev:revision-error () nil)
            (error (e) (push (list (type-of e) input) bad))))))
    (ok (null bad) (format nil "first offender: ~s" (first bad)))))
