(in-package #:revision-backend-jj/tests)

;;; Test support: throwaway jj repositories driven by the REAL jj,
;;; independent of the code under test. Every repository lives in a fresh
;;; temp directory with its own HOME and JJ_CONFIG (user.name / user.email
;;; set there), so the user's jj configuration never applies. Expected
;;; values are computed here by running jj; the backend must agree.
;;;
;;; jj runs through UIOP:RUN-PROGRAM with stdout / stderr redirected to
;;; files, so captures are byte-exact (process-backend-uiop 0.1.0 decodes
;;; output as text; see the brief). Fixture commands set JJ_TIMESTAMP (author
;;; and committer time) and JJ_OP_TIMESTAMP (operation time) explicitly, so
;;; both time axes are known.

(defparameter *jj* "jj")

(defstruct (trepo (:constructor %make-trepo))
  root   ; absolute directory pathname of the temp root
  dir    ; the workspace root
  home   ; the test HOME
  config ; the JJ_CONFIG file
  env)   ; alist (name . value) for every jj call, also given to the store

(defun windows-p ()
  (uiop:os-windows-p))

;;; ---- bytes and text --------------------------------------------------

(defun utf8 (string)
  (babel:string-to-octets string :encoding :utf-8))

(defun from-utf8 (octets)
  (babel:octets-to-string octets :encoding :utf-8))

(defun octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8) :initial-contents bytes))

(defun lines (&rest strings)
  "STRINGS joined, each followed by a newline (LF on every platform)."
  (with-output-to-string (s)
    (dolist (x strings) (write-string x s) (write-char #\Newline s))))

(defun write-octets (pathname octets)
  (ensure-directories-exist pathname)
  (with-open-file (out pathname :direction :output :element-type '(unsigned-byte 8)
                                :if-exists :supersede :if-does-not-exist :create)
    (write-sequence octets out))
  pathname)

(defun read-octets (pathname)
  (with-open-file (in pathname :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence v in)
      v)))

(defun split-lines (string)
  "Lines of STRING without empty ones (a CR before LF is dropped)."
  (remove "" (mapcar (lambda (l) (string-right-trim '(#\Return) l))
                     (uiop:split-string string :separator '(#\Newline)))
          :test #'string=))

;;; ---- time --------------------------------------------------------------

(defparameter +t0+ 1700000000
  "Base unix time of every fixture (2023-11-14T22:13:20Z).")

(defun rfc3339 (unix)
  "UNIX seconds → \"YYYY-MM-DDTHH:MM:SS+00:00\" (what JJ_TIMESTAMP takes)."
  (multiple-value-bind (s mi h d mo y)
      (decode-universal-time (+ unix (encode-universal-time 0 0 0 1 1 1970 0)) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d+00:00" y mo d h mi s)))

(defun time-env (at &key (op-at at))
  "Environment fixing commit timestamps to AT and operation time to OP-AT."
  (list (cons "JJ_TIMESTAMP" (rfc3339 at))
        (cons "JJ_OP_TIMESTAMP" (rfc3339 op-at))))

;;; ---- environment -------------------------------------------------------

(defun %inherited-environment ()
  "→ alist of the current process environment."
  (let ((entries #+sbcl (sb-ext:posix-environ)
                 #-sbcl (loop for name in '("PATH" "Path" "SYSTEMROOT" "SystemRoot" "TEMP"
                                            "TMP" "TMPDIR" "PATHEXT" "COMSPEC" "WINDIR")
                              for value = (uiop:getenv name)
                              when value collect (format nil "~a=~a" name value))))
    (loop for e in entries
          for p = (position #\= e :start 1)
          when p collect (cons (subseq e 0 p) (subseq e (1+ p))))))

(defun %environment (overrides)
  "Environment list (\"NAME=VALUE\" …): the inherited one with OVERRIDES
(alist) replacing entries of the same name (case-insensitive, for Windows).
Inherited JJ_* variables are dropped."
  (let ((base (remove-if (lambda (pair)
                           (or (assoc (car pair) overrides :test #'string-equal)
                               (and (>= (length (car pair)) 3)
                                    (string-equal "JJ_" (car pair) :end2 3))))
                         (%inherited-environment))))
    (loop for (k . v) in (append overrides base)
          collect (format nil "~a=~a" k v))))

;;; ---- running jj -------------------------------------------------------

(defun %temp-file (root name)
  (merge-pathnames (format nil "~a-~36r" name (random (expt 36 8) (make-random-state t))) root))

(defun jj* (repo args &key input env (ok '(0)) (output :string) (repository t)
                        (ignore-working-copy nil))
  "Run real jj ARGS (with -R REPO's workspace unless REPOSITORY is NIL) →
(values stdout exit-code stderr). IGNORE-WORKING-COPY adds the flag. INPUT:
NIL, string or octets. ENV: extra alist on top of REPO's env. OUTPUT :STRING
(UTF-8) or :OCTETS. An exit code not in OK → ERROR."
  (let* ((root (trepo-root repo))
         (out (%temp-file root "out"))
         (err (%temp-file root "err"))
         (in (when input
               (write-octets (%temp-file root "in")
                             (if (stringp input) (utf8 input) input))))
         (argv (append (list *jj* "--no-pager" "--color=never")
                       (when repository
                         (list "-R" (uiop:native-namestring (trepo-dir repo))))
                       (when ignore-working-copy (list "--ignore-working-copy"))
                       args)))
    (unwind-protect
         (let* ((code (nth-value 2 (uiop:run-program
                                    argv
                                    :input in
                                    :output out
                                    :error-output err
                                    :if-output-exists :supersede
                                    :if-error-output-exists :supersede
                                    :ignore-error-status t
                                    :directory (trepo-root repo)
                                    :environment (%environment
                                                  (append env (trepo-env repo))))))
                (stdout (read-octets out))
                (stderr (from-utf8 (read-octets err))))
           (unless (member code ok)
             (error "test jj ~{~a~^ ~} → ~a: ~a" args code stderr))
           (values (if (eq output :octets) stdout (from-utf8 stdout)) code stderr))
      (dolist (f (list out err in))
        (when f (ignore-errors (delete-file f)))))))

(defun jj (repo &rest args)
  "Real jj ARGS in REPO, --ignore-working-copy → stdout with trailing newlines
removed."
  (string-right-trim '(#\Newline #\Return) (jj* repo args :ignore-working-copy t)))

(defun jj-lines (repo &rest args)
  "Real jj ARGS in REPO, --ignore-working-copy → stdout lines (no empty ones)."
  (split-lines (jj* repo args :ignore-working-copy t)))

(defun jj-log (repo revset template &key at-op)
  "Real `jj log --no-graph -r REVSET -T TEMPLATE\\n` → one line per commit, in
jj's order. AT-OP: an operation id."
  (apply #'jj-lines repo
         (append (when at-op (list "--at-op" at-op))
                 (list "log" "--no-graph" "-r" revset
                       "-T" (format nil "~a ++ \"\\n\"" template)))))

(defun change-of (repo revset)
  "Full change id of the single commit REVSET names (real jj)."
  (let ((ids (jj-log repo revset "change_id")))
    (assert (= 1 (length ids)) () "revset ~s names ~d commits" revset (length ids))
    (first ids)))

(defun commit-of (repo revset)
  "Full commit id of the single commit REVSET names (real jj)."
  (let ((ids (jj-log repo revset "commit_id")))
    (assert (= 1 (length ids)) () "revset ~s names ~d commits" revset (length ids))
    (first ids)))

(defun changes-of (repo revset)
  "Change ids of REVSET in jj log order."
  (jj-log repo revset "change_id"))

(defun current-op (repo)
  "Real jj: the current operation id."
  (jj repo "op" "log" "-n1" "--no-graph" "-T" "id"))

;;; ---- repositories ------------------------------------------------------

(defun %make-root ()
  (let ((root (merge-pathnames (format nil "rbj-test-~36r/" (random (expt 36 10)
                                                                      (make-random-state t)))
                               (uiop:ensure-directory-pathname (uiop:temporary-directory)))))
    (ensure-directories-exist root)
    (truename root)))

(defun make-test-repo (&key (colocate t) (config ""))
  "Fresh jj repository (git backend; colocated unless COLOCATE is NIL) in a
fresh temp root → TREPO. HOME is <root>/home, JJ_CONFIG <root>/home/jj.toml
with user.name \"Test User\", user.email \"test@example.invalid\" and then
CONFIG (extra TOML text)."
  (let* ((root (%make-root))
         (home (merge-pathnames "home/" root))
         (dir (merge-pathnames "repo/" root))
         (config-file (merge-pathnames "jj.toml" home)))
    (ensure-directories-exist home)
    (write-octets config-file
                  (utf8 (format nil "[user]~%name = \"Test User\"~%email = \"test@example.invalid\"~%~a~%"
                                config)))
    (let ((repo (%make-trepo
                 :root root :dir dir :home home :config config-file
                 :env (list (cons "HOME" (uiop:native-namestring home))
                            (cons "USERPROFILE" (uiop:native-namestring home))
                            (cons "XDG_CONFIG_HOME"
                                  (uiop:native-namestring (merge-pathnames ".config/" home)))
                            (cons "APPDATA"
                                  (uiop:native-namestring (merge-pathnames "AppData/" home)))
                            (cons "JJ_CONFIG" (uiop:native-namestring config-file))
                            ;; never wait for an editor: a missing program fails fast
                            (cons "JJ_EDITOR" "jj-test-no-editor")))))
      (jj* repo (list "git" "init" (if colocate "--colocate" "--no-colocate")
                      (uiop:native-namestring dir))
           :repository nil :env (time-env +t0+ :op-at (- +t0+ 1000)))
      repo)))

(defun delete-test-repo (repo)
  (ignore-errors (uiop:delete-directory-tree (trepo-root repo) :validate t)))

(defmacro with-test-repo ((var &rest keys) &body body)
  `(let ((,var (make-test-repo ,@keys)))
     (unwind-protect (progn ,@body)
       (delete-test-repo ,var))))

(defun repo-file (repo relative)
  (merge-pathnames relative (trepo-dir repo)))

(defun put-file (repo relative content)
  "Write CONTENT (string → UTF-8 bytes exactly, no newline translation; or
octets) at RELATIVE in REPO's workspace."
  (write-octets (repo-file repo relative)
                (if (stringp content) (utf8 content) content)))

(defun remove-file (repo relative)
  (delete-file (repo-file repo relative)))

(defun file-bytes (repo relative)
  (read-octets (repo-file repo relative)))

(defun commit-all (repo message &key (at +t0+) author-at (op-at (+ at 10)))
  "Snapshot the workspace and `jj commit -m MESSAGE` with commit time AT,
operation time OP-AT; AUTHOR-AT (default AT) is then set with `jj metaedit
--author-timestamp`. → the change id of the committed change (now @-)."
  (jj* repo (list "commit" "-m" message) :env (time-env at :op-at op-at))
  (when author-at
    (jj* repo (list "metaedit" "-r" "@-" "--author-timestamp" (rfc3339 author-at))
         :env (time-env at :op-at op-at)))
  (change-of repo "@-"))

(defun new-change (repo parents &key (at +t0+) (op-at (+ at 10)))
  "`jj new PARENTS…` (the working copy moves there; files on disk follow)."
  (jj* repo (list* "new" parents) :env (time-env at :op-at op-at)))

(defun set-bookmark (repo name change &key (at +t0+))
  (jj* repo (list "bookmark" "set" name "-r" change "--allow-backwards")
       :ignore-working-copy t :env (time-env at)))

(defun set-tag (repo name change &key (at +t0+))
  (jj* repo (list "tag" "set" name "-r" change) :ignore-working-copy t :env (time-env at)))

;;; ---- the store under test ---------------------------------------------

(defun store-env (repo)
  "The :ENV a test store gets: REPO's isolation variables (HOME, JJ_CONFIG …),
never the user's."
  (trepo-env repo))

(defun open-store (repo &rest keys)
  (apply #'jj:make-jj-store (trepo-dir repo) :env (store-env repo) keys))

(defmacro with-store ((var repo &rest keys) &body body)
  `(let ((,var (open-store ,repo ,@keys)))
     ,@body))

;;; ---- small helpers -------------------------------------------------------

(defun ids (revisions)
  (mapcar #'rev:revision-id revisions))

(defun set= (a b)
  (and (subsetp a b :test #'equal) (subsetp b a :test #'equal)
       (= (length (remove-duplicates a :test #'equal))
          (length (remove-duplicates b :test #'equal)))))

(defun unix (instant)
  (dt:instant-seconds instant))

(defun instant (seconds)
  (dt:make-instant seconds))

(defun plist-matches-p (expected actual)
  "Every key of EXPECTED has an EQUALP value in ACTUAL."
  (loop for (k v) on expected by #'cddr
        always (equalp v (getf actual k '%missing))))

(defmacro capture-condition ((type) &body body)
  "Run BODY → the condition of TYPE it signalled, or NIL. Use outside OK."
  (let ((c (gensym "C")))
    `(handler-case (progn ,@body nil)
       (,type (,c) ,c))))

(defun restart-names-in (type thunk)
  "Call THUNK; on the first condition of TYPE record the names of every
restart visible inside the handler (looked up by name, not by condition),
then unwind. → (values names condition)."
  (let ((names nil) (cond nil))
    (block run
      (handler-bind ((condition
                       (lambda (c)
                         (when (typep c type)
                           (setf cond c
                                 names (mapcar #'restart-name (compute-restarts)))
                           (return-from run)))))
        (funcall thunk)))
    (values names cond)))

(defmacro invoking ((type restart &rest args) &body body)
  "Run BODY; on a condition of TYPE invoke RESTART (by name) with ARGS."
  `(handler-bind ((,type (lambda (c) (declare (ignore c))
                           (invoke-restart (find-restart ',restart) ,@args))))
     ,@body))

(defun tree-files (tree &optional prefix)
  "→ alist (\"a/b\" . file-node) of every file in a DIFF-PROTOCOL tree value."
  (loop for (name node) in (diff:tree-entries tree)
        for path = (if prefix (format nil "~a/~a" prefix name) name)
        nconc (if (diff:tree-file-p node)
                  (list (cons path node))
                  (tree-files node path))))

(defun file-at (tree path)
  (cdr (assoc path (tree-files tree) :test #'string=)))

(defun tree-engine ()
  (diff:find-diff-engine :tree))

(defun state= (a b)
  (diff:state-equal (tree-engine) a b))

(defun snapshot-of-workspace (repo)
  "→ alist (relative-path . (octets . mtime)) of every file under REPO's
workspace, .jj and .git excluded, sorted."
  (let ((top (trepo-dir repo)) (out '()))
    (labels ((walk (dir)
               (dolist (f (uiop:directory-files dir))
                 (push (cons (uiop:native-namestring (uiop:enough-pathname f top))
                             (cons (read-octets f) (file-write-date f)))
                       out))
               (dolist (d (uiop:subdirectories dir))
                 (unless (member (car (last (pathname-directory d))) '(".jj" ".git")
                                 :test #'string=)
                   (walk d)))))
      (walk top))
    (sort out #'string< :key #'car)))
