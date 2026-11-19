(in-package #:revision-backend-jj)

;;; ------------------------------------------------------------------
;;; REVISION-FILESYSTEM — a read-only cl-stack-pathlib filesystem over the
;;; tree of one jj commit, so every pathlib tool (read-text, iterdir, walk,
;;; glob, grep, stat, content-hash …) reads any revision without a checkout.
;;;
;;; Paths are POSIX, rooted at "/" (the repository root). The filesystem is
;;; pinned to the COMMIT id resolved when it was made: rewriting the change
;;; or moving a bookmark later does not change what it reads (a hidden
;;; commit stays readable). Listings come from `jj file list -r COMMIT -T
;;; *FILE-TEMPLATE*` (cacheable for the filesystem's lifetime: a commit never
;;; changes), contents from `jj file show -r COMMIT` (exact bytes); jj prints
;;; nothing for a symlink, so its target comes from the git-format diff
;;; against root() (informative). Directories are implied by file paths.
;;;
;;;   fs-exists-p / fs-file-p / fs-directory-p   entries; a symlink entry is a
;;;                                              file and FS-SYMLINK-P
;;;   fs-symlink-p / fs-read-symlink             the target as a pathname (not
;;;                                              followed)
;;;   fs-executable-p                            jj's executable bit
;;;   fs-readable-p                              exists; fs-writable-p → NIL
;;;   fs-file-size                               byte length of the content
;;;   fs-last-modified                           the commit's committer
;;;                                              timestamp, universal time, for
;;;                                              every entry
;;;   fs-iterdir                                 children sorted by name
;;;                                              (STRING<, jj's path order)
;;;   fs-read-bytes                              exact content; a conflicted
;;;                                              file reads as its materialized
;;;                                              conflict (REVISION-STATE)
;;;   fs-walk / fs-glob                          as zip-filesystem (IGNORE too)
;;;   fs-stat                                    kind :FILE / :DIRECTORY
;;;                                              (:SYMLINK without following),
;;;                                              mode #o644 / #o755, mtime as
;;;                                              fs-last-modified
;;;   fs-parse / fs-join / fs-parent / fs-name / fs-absolute / fs-resolve /
;;;   fs-normpath / fs-expanduser / fs-same-p    POSIX, like zip-filesystem
;;;   every mutating GF, fs-make-temp, fs-as-uri → PATHLIB:UNSUPPORTED-OPERATION
;;;   a missing path                             → PATHLIB:PATH-NOT-FOUND
;;;   (read-bytes, file-size, iterdir, stat; with pathlib's restarts where
;;;   zip-filesystem offers them)
;;; Git submodule entries are directories with no children.
;;; H2a GFs (fs-read-range, fs-read-lines, fs-open, fs-content-hash,
;;; fs-grep) may use pathlib's portable defaults.
;;; ------------------------------------------------------------------

(defclass revision-filesystem (pathlib:filesystem)
  ((store :initarg :store :reader revision-filesystem-store)
   (revision :initarg :revision :reader revision-filesystem-revision)
   ;; "/a/b" → (path . node) of a file, or :DIR; built on first use.
   (index :initform nil :accessor %fs-index)
   (index-lock :initform (bt2:make-lock :name "revision-filesystem")
               :reader %fs-index-lock))
  (:default-initargs :name "jj-revision")
  (:documentation "Read-only CL-STACK-PATHLIB filesystem over one jj commit's
tree. REVISION-FILESYSTEM-REVISION is the REVISION (its REVISION-CONTENT the
pinned commit id)."))

(defun revision-filesystem-p (x)
  "T when X is a REVISION-FILESYSTEM."
  (typep x 'revision-filesystem))

(defun make-revision-filesystem (store designator)
  "→ REVISION-FILESYSTEM over the commit DESIGNATOR names in STORE (any
designator RESOLVE-REVISION takes), pinned to its commit id. Signals what
RESOLVE-REVISION signals."
  (make-instance 'revision-filesystem
                 :store store
                 :revision (rev:resolve-revision store designator)))

(defun revision-path (store designator &optional (path "/"))
  "→ CL-STACK-PATHLIB:PATH for PATH (a POSIX string, default \"/\") on a fresh
REVISION-FILESYSTEM of DESIGNATOR in STORE."
  (let ((fs (make-revision-filesystem store designator)))
    (pathlib:make-path (pathlib:fs-parse fs path) :filesystem fs)))

;;; The index: built once from the commit's cached entries.

(defun %fs-commit (fs)
  (rev:revision-content (revision-filesystem-revision fs)))

(defun %ensure-parents (table key)
  (loop for slash = (position #\/ key :from-end t)
        while (and slash (plusp slash))
        do (setf key (subseq key 0 slash))
           (unless (gethash key table)
             (setf (gethash key table) :dir))))

(defun %index (fs)
  (bt2:with-lock-held ((%fs-index-lock fs))
    (or (%fs-index fs)
        (let ((table (make-hash-table :test 'equal)))
          (setf (gethash "/" table) :dir)
          (dolist (e (%entries (revision-filesystem-store fs) (%fs-commit fs)))
            (let ((key (concatenate 'string "/" (car e))))
              (setf (gethash key table)
                    (if (eq :gitlink (diff:tree-file-type (cdr e))) :dir e))
              (%ensure-parents table key)))
          (setf (%fs-index fs) table)))))

(defun %fs-key (fs pathname)
  (let* ((pn (pathlib:fs-absolute fs pathname))
         (s (pathlib::%pathname-as-posix pn))
         (s (if (and (plusp (length s)) (char= (char s 0) #\/)) s (concatenate 'string "/" s)))
         (s (string-right-trim "/" s)))
    (if (zerop (length s)) "/" s)))

(defun %fs-entry (fs pathname)
  "→ (values entry found-p): (path . node) of a file, or :DIR."
  (gethash (%fs-key fs pathname) (%index fs)))

(defun %fs-file (fs pathname)
  "The (path . node) of the file at PATHNAME, or NIL."
  (let ((e (%fs-entry fs pathname)))
    (and (consp e) e)))

(defun %fs-missing (fs pathname)
  (pathlib::%restart-path-not-found fs (pathlib:fs-absolute fs pathname)
                                    :message "no such file in the revision"
                                    :allow-create-file nil
                                    :allow-create-directory nil
                                    :allow-ignore nil))

(defun %fs-read-only (fs op pathname)
  (pathlib::%unsupported fs op pathname))

(defun %file-octets (node)
  (let ((content (diff:tree-file-content node)))
    (if (stringp content)
        (%octets content)
        (copy-seq content))))

;;; POSIX path algebra, as zip-filesystem.

(defmethod pathlib:fs-parse ((fs revision-filesystem) designator &key directory)
  (let ((pn (etypecase designator
              (pathname designator)
              (string (pathlib::%parse-posix designator))
              (pathlib:path (pathlib:path-pathname designator)))))
    (if directory (uiop:ensure-directory-pathname pn) pn)))

(defmethod pathlib:fs-join ((fs revision-filesystem) base relative)
  (uiop:merge-pathnames* (pathlib:fs-parse fs relative)
                         (uiop:ensure-directory-pathname (pathlib:fs-parse fs base))))

(defmethod pathlib:fs-parent ((fs revision-filesystem) pathname)
  (pathlib::%logical-parent (pathlib:fs-parse fs pathname)))

(defmethod pathlib:fs-name ((fs revision-filesystem) pathname)
  (pathlib::%file-namestring* (pathlib:fs-parse fs pathname)))

(defmethod pathlib:fs-absolute ((fs revision-filesystem) pathname &key (defaults "/"))
  (let ((pn (pathlib:fs-parse fs pathname))
        (base (pathlib:fs-parse fs defaults :directory t)))
    (if (uiop:absolute-pathname-p pn) pn (uiop:merge-pathnames* pn base))))

(defmethod pathlib:fs-resolve ((fs revision-filesystem) pathname &key (strict t))
  (let ((abs (pathlib:fs-normpath fs (pathlib:fs-absolute fs pathname))))
    (if (or (not strict) (pathlib:fs-exists-p fs abs))
        abs
        (%fs-missing fs abs))))

(defmethod pathlib:fs-normpath ((fs revision-filesystem) pathname)
  (let ((pn (pathlib:fs-parse fs pathname)))
    (multiple-value-bind (abs? stack dir?) (pathlib::%collapse-dot-segments pn)
      (pathlib:fs-parse fs
                        (cond ((and abs? (null stack)) "/")
                              (abs? (format nil "/~{~A~^/~}" stack))
                              ((null stack) ".")
                              (t (format nil "~{~A~^/~}" stack)))
                        :directory dir?))))

(defmethod pathlib:fs-expanduser ((fs revision-filesystem) pathname)
  (pathlib:fs-parse fs pathname))

;;; Predicates and metadata

(defmethod pathlib:fs-exists-p ((fs revision-filesystem) pathname)
  (nth-value 1 (%fs-entry fs pathname)))

(defmethod pathlib:fs-file-p ((fs revision-filesystem) pathname)
  (and (%fs-file fs pathname) t))

(defmethod pathlib:fs-directory-p ((fs revision-filesystem) pathname)
  (eq :dir (%fs-entry fs pathname)))

(defmethod pathlib:fs-symlink-p ((fs revision-filesystem) pathname)
  (let ((e (%fs-file fs pathname)))
    (and e (eql #o120000 (diff:tree-file-mode (cdr e))))))

(defmethod pathlib:fs-readable-p ((fs revision-filesystem) pathname)
  (pathlib:fs-exists-p fs pathname))

(defmethod pathlib:fs-writable-p ((fs revision-filesystem) pathname)
  (declare (ignore pathname))
  nil)

(defmethod pathlib:fs-executable-p ((fs revision-filesystem) pathname)
  (let ((e (%fs-file fs pathname)))
    (and e (eql #o100755 (diff:tree-file-mode (cdr e))))))

(defmethod pathlib:fs-file-size ((fs revision-filesystem) pathname)
  (let ((e (%fs-file fs pathname)))
    (if e
        (length (%file-octets (cdr e)))
        (error 'pathlib:path-not-found :filesystem fs :path pathname
                                       :message "no such file in the revision"))))

(defun %fs-mtime (fs)
  (+ (dt:instant-seconds (rev:revision-recorded-at (revision-filesystem-revision fs)))
     (encode-universal-time 0 0 0 1 1 1970 0)))

(defmethod pathlib:fs-last-modified ((fs revision-filesystem) pathname)
  (unless (pathlib:fs-exists-p fs pathname)
    (error 'pathlib:path-not-found :filesystem fs :path pathname
                                   :message "no such path in the revision"))
  (%fs-mtime fs))

(defmethod pathlib:fs-iterdir ((fs revision-filesystem) pathname)
  (let* ((key (%fs-key fs pathname))
         (prefix (if (string= key "/") "/" (concatenate 'string key "/")))
         (out '()))
    (unless (eq :dir (gethash key (%index fs)))
      (error 'pathlib:path-not-found :filesystem fs :path pathname
                                     :message "no such directory in the revision"))
    (maphash (lambda (k v)
               (declare (ignore v))
               (when (and (uiop:string-prefix-p prefix k)
                          (not (string= k key))
                          (not (find #\/ k :start (length prefix))))
                 (push k out)))
             (%index fs))
    (mapcar (lambda (k) (pathlib:fs-parse fs k)) (sort out #'string<))))

(defmethod pathlib:fs-glob ((fs revision-filesystem) pathname pattern &key recursive ignore)
  (let* ((base-key (%fs-key fs pathname))
         (prefix (if (string= base-key "/") "/" (concatenate 'string base-key "/")))
         (matcher (pathlib::%resolve-ignore fs pathname ignore))
         (out '()))
    (maphash
     (lambda (k v)
       (when (and (uiop:string-prefix-p prefix k) (not (string= k base-key)))
         (let* ((rel (subseq k (length prefix)))
                (nm (file-namestring k))
                (nested-p (find #\/ rel)))
           (when (and (plusp (length rel))
                      (not (and matcher (pathlib:ignore-path-p matcher rel :directory (eq v :dir))))
                      (or recursive (find #\/ pattern) (not nested-p))
                      (if (find #\/ pattern)
                          (pathname-match-p rel (pathlib::%wild-pattern pattern))
                          (and nm (pathlib::%name-matches-p nm pattern))))
             (push k out)))))
     (%index fs))
    (mapcar (lambda (k) (pathlib:fs-parse fs k)) (sort out #'string<))))

(defmethod pathlib:fs-walk ((fs revision-filesystem) pathname &key (top-down t) follow-symlinks ignore)
  (declare (ignore follow-symlinks))
  (let* ((out '())
         (root (pathlib:fs-absolute fs pathname))
         (ignored-p (pathlib::%ignore-predicate fs root ignore)))
    (labels ((walk* (dir)
               (let* ((entries (pathlib:fs-iterdir fs dir))
                      (files (remove-if-not (lambda (p) (pathlib:fs-file-p fs p)) entries))
                      (dirs (remove-if-not (lambda (p) (pathlib:fs-directory-p fs p)) entries)))
                 (when ignored-p
                   (setf files (remove-if (lambda (f) (funcall ignored-p f nil)) files)
                         dirs (remove-if (lambda (d) (funcall ignored-p d t)) dirs)))
                 (when top-down (push (list dir files dirs) out))
                 (dolist (d dirs) (walk* d))
                 (unless top-down (push (list dir files dirs) out)))))
      (walk* root)
      (nreverse out))))

(defmethod pathlib:fs-read-symlink ((fs revision-filesystem) pathname)
  (let ((e (%fs-file fs pathname)))
    (cond ((null e) (%fs-missing fs pathname))
          ((eql #o120000 (diff:tree-file-mode (cdr e)))
           (pathlib::%parse-posix (diff:tree-file-content (cdr e))))
          (t (error 'pathlib:path-error :filesystem fs :path pathname
                                        :message "not a symlink")))))

(defmethod pathlib:fs-read-bytes ((fs revision-filesystem) pathname)
  (let ((e (%fs-file fs pathname)))
    (if e
        (%file-octets (cdr e))
        (%fs-missing fs pathname))))

(defmethod pathlib:fs-stat ((fs revision-filesystem) pathname &key (follow-symlinks t))
  (declare (ignore follow-symlinks))
  (let ((pn (pathlib:fs-parse fs pathname)))
    (multiple-value-bind (e found) (%fs-entry fs pn)
      (cond ((not found)
             (error 'pathlib:path-not-found :filesystem fs :path pn
                                            :message "path does not exist"))
            ((eq e :dir)
             (make-instance 'pathlib:file-stat :path pn :kind :directory :size 0
                                               :mtime (%fs-mtime fs) :mode #o755
                                               :filesystem fs))
            (t
             (let ((node (cdr e)))
               (make-instance 'pathlib:file-stat
                              :path pn
                              :kind (if (eql #o120000 (diff:tree-file-mode node)) :symlink :file)
                              :size (length (%file-octets node))
                              :mtime (%fs-mtime fs)
                              :mode (if (eql #o100755 (diff:tree-file-mode node)) #o755 #o644)
                              :filesystem fs)))))))

(defmethod pathlib:fs-same-p ((fs revision-filesystem) a b)
  (string= (%fs-key fs a) (%fs-key fs b)))

;;; Read-only

(defmethod pathlib:fs-mkdir ((fs revision-filesystem) pathname &key parents exist-ok)
  (declare (ignore parents exist-ok))
  (%fs-read-only fs 'pathlib:fs-mkdir pathname))

(defmethod pathlib:fs-rmdir ((fs revision-filesystem) pathname)
  (%fs-read-only fs 'pathlib:fs-rmdir pathname))

(defmethod pathlib:fs-unlink ((fs revision-filesystem) pathname &key missing-ok)
  (declare (ignore missing-ok))
  (%fs-read-only fs 'pathlib:fs-unlink pathname))

(defmethod pathlib:fs-touch ((fs revision-filesystem) pathname &key exist-ok)
  (declare (ignore exist-ok))
  (%fs-read-only fs 'pathlib:fs-touch pathname))

(defmethod pathlib:fs-rename ((fs revision-filesystem) source target &key replace)
  (declare (ignore target replace))
  (%fs-read-only fs 'pathlib:fs-rename source))

(defmethod pathlib:fs-copy ((fs revision-filesystem) source target &key replace)
  (declare (ignore target replace))
  (%fs-read-only fs 'pathlib:fs-copy source))

(defmethod pathlib:fs-create-symlink ((fs revision-filesystem) link target)
  (declare (ignore target))
  (%fs-read-only fs 'pathlib:fs-create-symlink link))

(defmethod pathlib:fs-write-bytes ((fs revision-filesystem) pathname bytes
                                   &key append if-exists if-does-not-exist)
  (declare (ignore bytes append if-exists if-does-not-exist))
  (%fs-read-only fs 'pathlib:fs-write-bytes pathname))

(defmethod pathlib:fs-write-atomic ((fs revision-filesystem) pathname bytes &key expected-hash)
  (declare (ignore bytes expected-hash))
  (%fs-read-only fs 'pathlib:fs-write-atomic pathname))

(defmethod pathlib:fs-make-temp ((fs revision-filesystem) &key directory prefix suffix)
  (declare (ignore directory prefix suffix))
  (%fs-read-only fs 'pathlib:fs-make-temp nil))

(defmethod pathlib:fs-as-uri ((fs revision-filesystem) pathname)
  (%fs-read-only fs 'pathlib:fs-as-uri pathname))
