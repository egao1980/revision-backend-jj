(in-package #:revision-backend-jj/tests)

;;; The jj program: version parsing and the minimum, the version error, the
;;; store's paths, RUN-JJ (fixed options and environment, errors, I/O,
;;; --ignore-working-copy and --at-op), capabilities, the operation log.

(defun real-jj-version ()
  "Numeric dotted version of the real jj, parsed here independently."
  (let* ((out (string-trim '(#\Newline #\Return #\Space)
                           (with-test-repo (r) (jj* r '("--version") :repository nil))))
         (start (length "jj "))
         (end (or (position-if-not (lambda (c) (or (digit-char-p c) (char= c #\.)))
                                   out :start start)
                  (length out))))
    (string-right-trim "." (subseq out start end))))

(defun version<= (a b)
  "Dotted version strings, numerically, missing components = 0."
  (flet ((parts (s) (mapcar #'parse-integer
                            (remove "" (uiop:split-string s :separator '(#\.)) :test #'string=))))
    (loop for x in (append (parts a) '(0 0 0 0))
          for y in (append (parts b) '(0 0 0 0))
          repeat 4
          do (cond ((< x y) (return t)) ((> x y) (return nil)))
          finally (return t))))

(deftest-parametrize parse-jj-version
    ((input expected)
     :ids ("plain" "release-binary" "newline" "dev-build" "bare-3" "bare-2" "nonsense" "empty")
     ("jj 0.47.1" '(0 47 1))
     ("jj 0.47.1-d16ee1fc88a72c54142241b079a34bbf3b033bc0" '(0 47 1))
     ((format nil "jj 0.46.0~%") '(0 46 0))
     ("jj 0.48.0-dev" '(0 48 0))
     ("0.47.1" '(0 47 1))
     ("0.47" '(0 47))
     ("not a version" nil)
     ("" nil))
  (ok (equal expected (jj:parse-jj-version input))))

(deftest minimum-jj-version-is-locked
  (ok (equal "0.47.1" jj:*minimum-jj-version*)
      "V2 minimum = the jj release CI pins (v0.47.1, latest stable 2026-11-19)")
  (ok (equal "jj" jj:*jj-program*)))

(deftest installed-jj-meets-the-minimum
  (ok (version<= jj:*minimum-jj-version* (real-jj-version))
      (format nil "jj ~a on this runner >= ~a" (real-jj-version) jj:*minimum-jj-version*)))

(deftest jj-version-of-a-store
  (with-test-repo (r)
    (ok (equal (real-jj-version) (jj:jj-version (open-store r))))))

(deftest too-old-jj-signals-vc-tool-version-error
  (with-test-repo (r)
    (let ((c (let ((jj:*minimum-jj-version* "999.0.0"))
               (capture-condition (jj:vc-tool-version-error) (open-store r)))))
      (ok (typep c 'jj:vc-tool-version-error))
      (ok (typep c 'rev:revision-error) "a revision-error")
      (when c
        (ok (equal "jj" (jj:vc-tool-version-error-tool c)))
        (ok (equal (real-jj-version) (jj:vc-tool-version-error-found c)))
        (ok (equal "999.0.0" (jj:vc-tool-version-error-required c)))
        (ok (search "999.0.0" (princ-to-string c)) "report names the requirement")))
    (testing "the check reads the variable at call time"
      (ok (jj:jj-store-p (open-store r))))))

(deftest missing-jj-signals-vc-tool-version-error
  (with-test-repo (r)
    (let ((c (capture-condition (jj:vc-tool-version-error)
               (open-store r :jj (uiop:native-namestring
                                  (merge-pathnames "no-such-jj-program" (trepo-root r)))))))
      (ok (typep c 'jj:vc-tool-version-error))
      (when c
        (ok (null (jj:vc-tool-version-error-found c)))
        (ok (equal jj:*minimum-jj-version* (jj:vc-tool-version-error-required c)))))))

(deftest store-paths-colocated
  (with-test-repo (r)
    (put-file r "sub/dir/marker.txt" "m")
    (let ((top (open-store r))
          (below (apply #'jj:make-jj-store (repo-file r "sub/dir/") :env (store-env r) '())))
      (dolist (s (list top below))
        (ok (uiop:directory-pathname-p (jj:jj-store-path s)))
        (ok (equal (truename (trepo-dir r)) (truename (jj:jj-store-path s)))
            "the workspace root, from any directory below it")
        (ok (equal (truename (repo-file r ".jj/repo/")) (truename (jj:jj-store-repo-path s))))
        (ok (equal "default" (jj:jj-store-workspace s)))
        (ok (jj:jj-store-colocated-p s))))))

(deftest store-paths-non-colocated
  (with-test-repo (r :colocate nil)
    (let ((s (open-store r)))
      (ok (not (jj:jj-store-colocated-p s)))
      (ok (equal (truename (trepo-dir r)) (truename (jj:jj-store-path s)))))))

(deftest store-of-a-secondary-workspace
  (with-test-repo (r)
    (build-linear r)
    (let ((ws (merge-pathnames "second/" (trepo-root r))))
      (jj* r (list "workspace" "add" "--name" "second" (uiop:native-namestring ws))
           :env (time-env (+ +t0+ 500)))
      (let ((s (apply #'jj:make-jj-store ws :env (store-env r) '())))
        (ok (equal (truename ws) (truename (jj:jj-store-path s))))
        (ok (equal "second" (jj:jj-store-workspace s)))
        (ok (equal (truename (repo-file r ".jj/repo/")) (truename (jj:jj-store-repo-path s)))
            "shares the main workspace's repository")
        (ok (not (jj:jj-store-colocated-p s)))
        (ok (equal (change-of r "second@") (rev:revision-id (rev:resolve-revision s "@")))
            "@ is this workspace's working-copy commit")))))

(deftest outside-a-repository-signals-jj-command-error
  (with-test-repo (r)
    (let ((plain (merge-pathnames "plain/" (trepo-root r))))
      (ensure-directories-exist plain)
      (let ((c (capture-condition (rev:revision-error)
                 (apply #'jj:make-jj-store plain :env (store-env r) '()))))
        (ok (typep c 'jj:jj-command-error))
        (when c
          (ok (integerp (jj:jj-command-error-exit-code c)))
          (ok (stringp (jj:jj-command-error-stderr c))))))
    (ok (signals (apply #'jj:make-jj-store (merge-pathnames "missing/" (trepo-root r))
                        :env (store-env r) '())
                 'jj:jj-command-error)
        "a missing directory")))

(deftest store-env-is-a-copy
  (with-test-repo (r)
    (let* ((s (open-store r))
           (env (jj:jj-store-env s)))
      (ok (equal (store-env r) env))
      (setf (cdr (first env)) "mallory")
      (ok (equal (store-env r) (jj:jj-store-env s))))))

(deftest run-jj-output-and-errors
  (with-test-repo (r)
    (build-linear r)
    (let ((s (open-store r)))
      (multiple-value-bind (out code err)
          (jj:run-jj s (list "log" "--no-graph" "-r" "main" "-T" "change_id"))
        (ok (equal (change-of r "main") out))
        (ok (eql 0 code))
        (ok (stringp err)))
      (testing "octets"
        (let ((bytes (jj:run-jj s (list "file" "show" "-r" "main" "a.txt") :output :octets)))
          (ok (typep bytes '(vector (unsigned-byte 8))))
          (ok (equalp (utf8 (lines "one" "two")) bytes))))
      (testing "exit codes"
        (let ((c (capture-condition (jj:jj-command-error)
                   (jj:run-jj s (list "log" "-r" "no_such_symbol_xyz")))))
          (ok (typep c 'jj:jj-command-error))
          (when c
            (ok (equal (list "log" "-r" "no_such_symbol_xyz") (jj:jj-command-error-command c)))
            (ok (not (eql 0 (jj:jj-command-error-exit-code c))))
            (ok (search "no_such_symbol_xyz" (jj:jj-command-error-stderr c)))))
        (ok (= 1 (nth-value 1 (jj:run-jj s (list "log" "-r" "no_such_symbol_xyz")
                                         :ok-exit-codes '(0 1))))
            "accepted exit code"))
      (testing "input"
        (jj:run-jj s (list "describe" "-r" "@" "--stdin") :input (format nil "piped ~c" (code-char 233)))
        (ok (equal (lines (format nil "piped ~c" (code-char 233))) (jj* r '("log" "--no-graph" "-r" "@" "-T" "description")
                                         :ignore-working-copy t))
            "a string is sent as UTF-8")))))

(deftest run-jj-fixed-options-win-over-user-config
  (with-test-repo (r :config (format nil "[ui]~%color = \"always\"~%paginate = \"auto\"~%conflict-marker-style = \"snapshot\"~%diff-formatter = \":color-words\"~%[working-copy]~%eol-conversion = \"input-output\""))
    (let ((s (open-store r)))
      (flet ((config-get (key) (string-right-trim '(#\Newline #\Return)
                                           (jj:run-jj s (list "config" "get" key)))))
        (ok (equal "never" (config-get "ui.color")))
        (ok (equal "never" (config-get "ui.paginate")))
        (ok (equal "diff" (config-get "ui.conflict-marker-style")))
        (ok (equal ":git" (config-get "ui.diff-formatter")))
        (ok (equal "none" (config-get "working-copy.eol-conversion")))))))

(deftest run-jj-env-reaches-jj
  (with-test-repo (r)
    (build-working-copy r)
    (let ((s (jj:make-jj-store (trepo-dir r) :env (append (time-env (+ +t0+ 777)) (store-env r)))))
      (jj:run-jj s (list "describe" "-r" "@" "-m" "timed"))
      (ok (equal (list (princ-to-string (+ +t0+ 777)))
                 (jj-log r "@" "committer.timestamp().format(\"%s\")"))
          "JJ_TIMESTAMP from :ENV reached jj"))))

(deftest run-jj-ignore-working-copy
  (with-test-repo (r)
    (build-working-copy r)
    (let ((s (open-store r))
          (before (commit-of r "@")))
      (put-file r "new.txt" (lines "new"))
      (jj:run-jj s (list "log" "-r" "@" "--no-graph" "-T" "commit_id"))
      (ok (equal before (commit-of r "@")) "default: no snapshot")
      (jj:run-jj s (list "log" "-r" "@" "--no-graph" "-T" "commit_id") :ignore-working-copy nil)
      (ok (not (equal before (commit-of r "@"))) ":ignore-working-copy nil snapshots"))))

(deftest run-jj-at-operation
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (op (current-op r)))
      (jj* r (list "describe" "-r" (getf k :c3) "-m" "reworded") :ignore-working-copy t
           :env (time-env (+ +t0+ 400)))
      (let ((s (open-store r)))
        (ok (equal (string-right-trim '(#\Newline) (jj:run-jj s (list "log" "--no-graph" "-r" "main" "-T" "description")
                                                            :at-operation op))
                   (format nil "third~%~%with a body")))
        (ok (equal "reworded" (string-right-trim '(#\Newline)
                                                 (jj:run-jj s (list "log" "--no-graph" "-r" "main" "-T" "description")))))))))

(deftest capabilities
  (with-test-repo (r)
    (let ((caps (jj:jj-capabilities (open-store r))))
      (ok (plist-matches-p '(:primary :state :merges t :children-index t :valid-time t
                             :ref-cas nil :atomic-multi-ref nil :gc nil :signed nil
                             :transactional-apply nil :projection nil
                             :conflicted-revisions t)
                           caps))
      (ok (member :ref-cas caps) ":ref-cas is present (and NIL)")))
  (testing "revision-protocol's capability queries agree"
    (with-test-repo (r)
      (let ((s (open-store r)))
        (ok (eq nil (rev:ref-cas-p s)) ":ref-cas NIL: CAS is emulated over the operation log")
        (ok (eq t (rev:conflicted-revisions-p s)) ":conflicted-revisions T")))))

(deftest vc-tool-version-error-is-the-protocol-condition
  ;; revision-protocol#4: one condition for the git and jj backends, re-exported here.
  (ok (eq 'jj:vc-tool-version-error 'rev:vc-tool-version-error))
  (ok (eq 'jj:vc-tool-version-error-tool 'rev:vc-tool-version-error-tool))
  (ok (eq 'jj:vc-tool-version-error-found 'rev:vc-tool-version-error-found))
  (ok (eq 'jj:vc-tool-version-error-required 'rev:vc-tool-version-error-required))
  (ok (eq :external (nth-value 1 (find-symbol "VC-TOOL-VERSION-ERROR" "REVISION-BACKEND-JJ")))))

(deftest operations
  (with-test-repo (r)
    (build-linear r)
    (let* ((s (open-store r))
           (expected (jj-log-ops r)))
      (ok (equal (first expected) (jj:current-operation s)))
      (let ((ops (jj:list-operations s)))
        (ok (equal expected (mapcar (lambda (o) (getf o :id)) ops)) "jj op log order, root included")
        (ok (getf (car (last ops)) :root))
        (let ((tags-op (first ops)))
          (ok (= (* 1000 (+ +t0+ 300)) (getf tags-op :end-ms)) "JJ_OP_TIMESTAMP")
          (ok (equal (list (second expected)) (getf tags-op :parents)))))
      (ok (= 3 (length (jj:list-operations s :limit 3)))))))

(defun jj-log-ops (repo)
  "Real jj: every operation id, newest first."
  (jj-lines repo "op" "log" "--no-graph" "-T" "id ++ \"\\n\""))
