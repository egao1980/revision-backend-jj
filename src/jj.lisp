(in-package #:revision-backend-jj)

;;; ------------------------------------------------------------------
;;; The jj program, its version, and how every jj command runs.
;;; Exported names, lambda lists and docstrings are the contract (with the
;;; brief, cl-stack docs/capabilities/revision-backend-jj.md).
;;; ------------------------------------------------------------------

(defparameter *jj-program* "jj"
  "The jj executable MAKE-JJ-STORE uses when :JJ is not given: a program name
looked up on PATH, or an absolute path (a string or pathname).")

(defparameter *minimum-jj-version* "0.47.1"
  "Oldest jj release the backend accepts, as a version string. Locked for V2
to the release CI installs on every runner (official release binaries of
jj-vcs/jj v0.47.1, the latest stable on 2026-11-19; pinned with checksums in
.github/workflows/test.yml). jj's CLI and templates still change between
releases, so the minimum moves with the pin: bumping it is a PR whose CI run
is the evidence. MAKE-JJ-STORE compares the probed version with the value of
this variable at call time, so binding it higher makes any jj look too old
(tests do this).")

;;; The fixed options of every jj command. They come right after the program
;;; name, before the caller's arguments. --config layers sit above the user's
;;; and the repository's configuration, so output never depends on them.
;;; Commands that only read the repository additionally get
;;; --ignore-working-copy (never snapshot, never touch the disk); that is per
;;; command, not here (see the store comment in src/store.lisp).

(defvar *operation-template*)          ; defined with the other templates in src/parse.lisp

(defparameter +fixed-options+
  '("--no-pager"
    "--color=never"
    "--quiet"
    "--config" "ui.conflict-marker-style=diff"
    "--config" "ui.diff-formatter=:git"
    "--config" "ui.log-word-wrap=false"
    "--config" "working-copy.eol-conversion=none")
  "Global options placed before the caller's arguments in every jj command.")

(defparameter +fixed-environment+
  '(("NO_COLOR" . "1")
    ("JJ_EDITOR" . "jj-editor-disabled"))
  "Environment variables set for every jj command (name . value), added to the
inherited environment and winning over the store's :ENV. JJ_EDITOR names a
program that does not exist: a command that would open an editor fails
instead of waiting (the backend always passes -m).")

(defun parse-jj-version (string)
  "→ list of non-negative integers (major minor patch …) parsed from STRING:
either the output of `jj --version` (\"jj 0.47.1\", the release binaries'
\"jj 0.47.1-d16ee1fc88a72c54142241b079a34bbf3b033bc0\", with or without a
final newline) or a bare version (\"0.47.1\", \"0.47\"). Parsing stops at the
first component that is not all digits, so build suffixes are dropped:
\"0.47.1-d16e…\" → (0 47 1), \"0.48.0-dev\" → (0 48 0). A string with no
leading numeric component → NIL. Missing trailing components are not padded
(\"0.47\" → (0 47)); comparisons treat them as 0."
  (check-type string string)
  (let* ((s (string-trim '(#\Space #\Tab #\Newline #\Return) string))
         (s (if (and (>= (length s) 3) (string= "jj " s :end2 3))
                (string-left-trim " " (subseq s 3))
                s))
         (s (subseq s 0 (or (position-if (lambda (c) (member c '(#\Space #\Tab #\Newline)))
                                         s)
                            (length s))))
         (parts '())
         (start 0))
    (loop
      (let* ((digits-end (or (position-if-not (lambda (c) (char<= #\0 c #\9)) s :start start)
                             (length s))))
        (when (= digits-end start) (return))
        (push (parse-integer s :start start :end digits-end) parts)
        (unless (and (< digits-end (length s)) (char= #\. (char s digits-end)))
          (return))
        (setf start (1+ digits-end))))
    (nreverse parts)))

(defun %version< (a b)
  "Version lists A < B, missing components read as 0."
  (loop for i below (max (length a) (length b))
        for x = (or (nth i a) 0)
        for y = (or (nth i b) 0)
        do (cond ((< x y) (return t)) ((> x y) (return nil)))
        finally (return nil)))

(defun %version-string (parts)
  (format nil "~{~d~^.~}" parts))

;;; ------------------------------------------------------------------
;;; The store
;;; ------------------------------------------------------------------

(defclass jj-store (rev:revision-store)
  ((path :initarg :path :reader jj-store-path)
   (repo-path :initarg :repo-path :reader jj-store-repo-path)
   (workspace :initarg :workspace :reader jj-store-workspace)
   (colocated-p :initarg :colocated-p :reader jj-store-colocated-p)
   (env :initarg :env :initform '() :reader %jj-store-env)
   (jj :initarg :jj :reader %jj-store-program)
   (version :initarg :version :reader %jj-store-version)
   (permit-force :initarg :permit-force :initform nil
                 :reader %jj-store-permit-force)
   (listener :initform nil :accessor %jj-store-listener)
   ;; Serializes ref updates (CAS emulation) made through this store.
   (lock :initform (bt2:make-recursive-lock :name "jj-store")
         :reader %jj-store-lock)
   ;; Commit id → state facts (immutable: a commit never changes).
   (content-cache :initform (make-hash-table :test 'equal)
                  :reader %jj-store-content-cache)
   (cache-lock :initform (bt2:make-lock :name "jj-store cache")
               :reader %jj-store-cache-lock))
  (:documentation "A REVISION-STORE over one jj repository, seen from one of
its workspaces, driven through the jj CLI only (no jj-lib).

Revisions are jj changes. REVISION-ID is the full change id (32 characters
from \"k\"…\"z\"); for a divergent change (several visible commits share the
change id) each commit's REVISION-ID is its full commit id instead.
REVISION-CONTENT is the commit id of the snapshot the REVISION value
describes, so a REVISION object used as a designator always names that exact
commit even after the change is rewritten. See src/store.lisp for parents,
times, provenance, the root commit and rewrites.

Refs: local bookmarks are :MOVABLE refs, local tags are :TAG refs; remote
bookmarks and tags are not refs. CONTENT-PRIMARY is :STATE; states are
DIFF-PROTOCOL tree values; the empty state is (DIFF-PROTOCOL:MAKE-TREE).

The store holds no long-lived process (jj has no batch mode). A store may be
used from several threads: ref updates made through one store are serialized
by a lock (linearizable within the image); against other jj processes CAS is
emulated through the operation log (see src/store.lisp)."))

(defun jj-store-p (x)
  "T when X is a JJ-STORE."
  (typep x 'jj-store))

(defun make-jj-store (path &key (jj *jj-program*) env permit-force)
  "→ JJ-STORE over the jj workspace containing PATH (a string or pathname
naming the workspace root or any directory below it).

First probes `JJ --version` (once per program per image is enough; the
check against *MINIMUM-JJ-VERSION* runs on every call). A version older than
*MINIMUM-JJ-VERSION* signals VC-TOOL-VERSION-ERROR (:TOOL \"jj\", :FOUND the
numeric version string, e.g. \"0.46.0\", :REQUIRED *MINIMUM-JJ-VERSION*); a
program that cannot be started signals VC-TOOL-VERSION-ERROR with :FOUND NIL.
No other jj command runs before that check.

PATH outside any jj workspace (or missing) signals JJ-COMMAND-ERROR (from
`jj workspace root`). A plain git repository without .jj is outside.
Afterwards JJ-STORE-PATH is the absolute directory pathname of the workspace
root, JJ-STORE-REPO-PATH the absolute directory pathname of the repository
(the .jj/repo/ directory jj resolves, which a secondary workspace shares with
its main one), JJ-STORE-WORKSPACE the workspace name (\"default\" for the
first one), JJ-STORE-COLOCATED-P true when the workspace root also holds the
git repository (a colocated repo, `jj git init` default) and NIL for a
non-colocated one (`jj git init --no-colocate`, or a secondary workspace).

ENV: alist of (NAME . VALUE) strings added to the environment of every jj
command this store runs (HOME, JJ_CONFIG, JJ_USER, JJ_EMAIL,
JJ_OP_TIMESTAMP …); the fixed variables win over ENV.
PERMIT-FORCE: NIL, T, or a predicate of the ref name — REVISION-PROTOCOL:
PERMIT-FORCE-P, the gate of the FORCE restart."
  (let* ((program (if (pathnamep jj) (uiop:native-namestring jj) jj))
         (env (copy-alist env))
         (found (%probe-version program env))
         (required *minimum-jj-version*))
    (when (or (eq found :missing)
              (%version< found (parse-jj-version required)))
      (error 'vc-tool-version-error
             :tool "jj"
             :found (if (eq found :missing) nil (%version-string found))
             :required required
             :message (format nil "jj ~a: need ~a or later"
                              (if (eq found :missing) "cannot be run"
                                  (%version-string found))
                              required)))
    (let* ((dir (uiop:ensure-directory-pathname path))
           (out (if (uiop:directory-exists-p dir)
                    ;; jj finds the workspace from the current directory
                    ;; (-R would have to name the root itself)
                    (%invoke-jj program env dir (list "workspace" "root") :root-args nil)
                    (%invoke-jj program env nil
                                (list "-R" (uiop:native-namestring dir) "workspace" "root"))))
           (root (uiop:ensure-directory-pathname
                  (uiop:parse-native-namestring
                   (string-right-trim '(#\Newline #\Return) out))))
           (repo-path (%repo-path root))
           (workspace (%workspace-name program env root)))
      (make-instance 'jj-store
                     :path root
                     :repo-path repo-path
                     :workspace workspace
                     :colocated-p (and (uiop:directory-exists-p
                                        (merge-pathnames ".jj/repo/" root))
                                       (uiop:directory-exists-p
                                        (merge-pathnames ".git/" root))
                                       t)
                     :env env
                     :jj program
                     :version found
                     :permit-force permit-force))))

(defvar *version-cache* (make-hash-table :test 'equal)
  "Program string → version list of `PROGRAM --version` (successful probes).")

(defvar *version-lock* (bt2:make-lock :name "jj version cache"))

(defun %probe-version (program env)
  "→ the version list PROGRAM reports, or :MISSING when it cannot be run."
  (or (bt2:with-lock-held (*version-lock*) (gethash program *version-cache*))
      (let ((found
              (handler-case
                  (multiple-value-bind (code out)
                      (proc:run (list program "--version")
                                :output :string :error-output :string
                                :env (append env +fixed-environment+))
                    (and (eql code 0) (parse-jj-version out)))
                (proc:process-error () nil))))
        (if found
            (bt2:with-lock-held (*version-lock*)
              (setf (gethash program *version-cache*) found))
            :missing))))

(defun %repo-path (root)
  "The .jj/repo/ directory of the workspace at ROOT (a secondary workspace's
.jj/repo is a file naming its main one's, relative to .jj/)."
  (let ((dir (merge-pathnames ".jj/repo/" root))
        (file (merge-pathnames ".jj/repo" root)))
    (cond ((uiop:directory-exists-p dir) dir)
          ((probe-file file)
           (let ((target (string-right-trim
                          '(#\Newline #\Return #\Space)
                          (uiop:read-file-string file :external-format :utf-8))))
             (let ((main (uiop:ensure-directory-pathname
                          (uiop:merge-pathnames* (uiop:parse-native-namestring target)
                                                 (merge-pathnames ".jj/" root)))))
               (uiop:ensure-directory-pathname (or (probe-file main) main)))))
          (t dir))))

(defun %workspace-name (program env root)
  (let ((names (uiop:split-string
                (%invoke-jj program env root
                            (list "workspace" "list" "-T"
                                  "if(target.current_working_copy(), name ++ \"\\n\")"))
                :separator '(#\Newline))))
    (or (find-if (lambda (s) (plusp (length s)))
                 (mapcar (lambda (s) (string-right-trim '(#\Return) s)) names))
        "default")))

(defun jj-store-env (store)
  "→ fresh copy of the :ENV alist STORE was made with."
  (copy-alist (%jj-store-env store)))

(defun jj-version (store)
  "→ the version of STORE's jj program as a dotted string of the numeric
components `jj --version` reported (\"0.47.1\" for
\"jj 0.47.1-d16ee1fc…\")."
  (%version-string (%jj-store-version store)))

(defun run-jj (store args &key input (output :string) (ok-exit-codes '(0))
                            (ignore-working-copy t) at-operation)
  "Run STORE's jj with the fixed environment, the fixed options, then ARGS (a
list of strings), in STORE's workspace root (with -R pointing at it).
→ (values stdout exit-code stderr).

IGNORE-WORKING-COPY (default T) adds --ignore-working-copy: the command
neither snapshots nor updates the working copy. NIL lets jj snapshot first,
as any plain jj command does. AT-OPERATION, an operation id string, adds
--at-op ID (which also implies no snapshot).
INPUT: NIL, a string (sent as UTF-8) or an (unsigned-byte 8) vector, written
to standard input. OUTPUT :STRING decodes stdout as UTF-8; :OCTETS returns the
exact bytes as an (unsigned-byte 8) vector. STDERR is always a string.
An exit code not in OK-EXIT-CODES signals JJ-COMMAND-ERROR (:COMMAND ARGS,
:EXIT-CODE, :STDERR). Runs through PROCESS-PROTOCOL (*PROCESS-BACKEND*)."
  (%invoke-jj (%jj-store-program store) (%jj-store-env store) (jj-store-path store)
              args
              :input input :output output :ok-exit-codes ok-exit-codes
              :ignore-working-copy ignore-working-copy :at-operation at-operation))

(defun %invoke-jj (program env root args &key input (output :string) (ok-exit-codes '(0))
                                           (ignore-working-copy t) at-operation
                                           (root-args t))
  "Run PROGRAM with the fixed options, -R ROOT (when ROOT and ROOT-ARGS),
--ignore-working-copy / --at-op as asked, then ARGS. → (values stdout code
stderr); an exit code outside OK-EXIT-CODES signals JJ-COMMAND-ERROR."
  (let ((argv (append (list program)
                      +fixed-options+
                      (when (and root root-args)
                        (list "-R" (uiop:native-namestring root)))
                      (when ignore-working-copy (list "--ignore-working-copy"))
                      (when at-operation (list "--at-op" at-operation))
                      args)))
    (multiple-value-bind (code out err)
        (apply #'proc:run argv
               :input input
               :output (if (eq output :octets) :octets :string)
               :error-output :string
               :env (append env +fixed-environment+)
               :env-mode :merge
               (when root (list :directory root)))
      (let ((err (or err "")))
        (unless (member code ok-exit-codes)
          (error 'jj-command-error
                 :command (copy-list args) :exit-code code :stderr err
                 :message (format nil "jj ~{~a~^ ~} exited with ~a" args code)))
        (values out code err)))))

(defun jj-capabilities (store)
  "→ fresh plist of STORE's revision-protocol capabilities (the plan's
capability names; revision-protocol has query GFs for only some of them):

  :PRIMARY :STATE          :MERGES T             :CHILDREN-INDEX T
  :VALID-TIME T            :REF-CAS NIL          :ATOMIC-MULTI-REF NIL
  :GC NIL                  :SIGNED NIL           :TRANSACTIONAL-APPLY NIL
  :PROJECTION NIL          :CONFLICTED-REVISIONS T   :TAG-REWRITE NIL

:REF-CAS NIL: CAS is emulated (serialized in the image, divergence detected
across processes), not guaranteed by jj. :CONFLICTED-REVISIONS T: a revision
may record unresolved conflicts (REVISION-CONFLICTS). :TAG-REWRITE NIL: jj
tags carry no annotation, so there is nothing to rewrite (TAG-REWRITE-P)."
  (declare (ignore store))
  (list :primary :state :merges t :children-index t :valid-time t
        :ref-cas nil :atomic-multi-ref nil :gc nil :signed nil
        :transactional-apply nil :projection nil :conflicted-revisions t
        :tag-rewrite nil))

;;; revision-protocol's capability queries (revision-protocol#5).

(defmethod rev:ref-cas-p ((store jj-store))
  "NIL: CAS is emulated over the operation log (see JJ-CAPABILITIES)."
  nil)

(defmethod rev:conflicted-revisions-p ((store jj-store))
  "T: a revision may record unresolved conflicts (REVISION-CONFLICTS)."
  t)

(defmethod rev:tag-rewrite-p ((store jj-store))
  "NIL: jj tags carry no annotation (TAG-REVISION refuses :ANNOTATION), so
TAG-REVISION never offers REPLACE-ANNOTATION. `jj tag set --allow-move` moves a
tag, which the protocol forbids."
  nil)

;;; ------------------------------------------------------------------
;;; The operation log — jj's recorded-time axis.
;;; ------------------------------------------------------------------

(defun current-operation (store)
  "→ the id (full hex string) of STORE's current operation: the single head
of the operation log after jj has reconciled any concurrent heads (reading
the repository does that, creating a \"reconcile divergent operations\"
operation). The same id `jj op log -n1 --no-graph -T id` prints."
  (string-trim '(#\Newline #\Return #\Space)
               (run-jj store (list "op" "log" "-n1" "--no-graph" "-T" "id"))))

(defun list-operations (store &key limit)
  "→ fresh list of plists, one per operation, in `jj op log` order (newest
first; LIMIT NIL = all, else at most LIMIT entries), parsed from
*OPERATION-TEMPLATE* output (PARSE-OPERATION-RECORDS keys: :ID :PARENTS
:START-MS :END-MS :DESCRIPTION :SNAPSHOT :ROOT). Includes the root operation
when LIMIT allows."
  (check-type limit (or null (integer 0)))
  (if (eql limit 0)
      '()
      (parse-operation-records
       (run-jj store (append (list "op" "log" "--no-graph" "-T" *operation-template*)
                             (when limit (list "-n" (princ-to-string limit))))))))
