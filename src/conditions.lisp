(in-package #:revision-backend-jj)

;;; Conditions. Everything a revision store reports through the protocol
;;; (REVISION-NOT-FOUND, AMBIGUOUS-REVISION, REF-CONFLICT, TAG-IMMUTABLE,
;;; REVISION-ERROR ...) is REVISION-PROTOCOL's own type: the backend signals
;;; those. Only two conditions are jj-specific:
;;;
;;;   revision-error
;;;   ├── vc-tool-version-error (tool found required)
;;;   └── jj-command-error      (command exit-code stderr)
;;;
;;; VC-TOOL-VERSION-ERROR has the same name, slots and readers as
;;; revision-backend-git's. revision-protocol#4 moves it into the protocol;
;;; this package then imports and re-exports the protocol's symbol (callers
;;; that write STACK-REV-JJ:VC-TOOL-VERSION-ERROR keep working).

(define-condition vc-tool-version-error (rev:revision-error)
  ((tool :initarg :tool :reader vc-tool-version-error-tool :initform nil)
   (found :initarg :found :reader vc-tool-version-error-found :initform nil)
   (required :initarg :required :reader vc-tool-version-error-required
             :initform nil))
  (:report (lambda (c s)
             (format s "~a ~a is too old or missing: found ~a, need ~a or later"
                     (or (vc-tool-version-error-tool c) "tool")
                     (if (vc-tool-version-error-found c) "version" "program")
                     (or (vc-tool-version-error-found c) "nothing")
                     (vc-tool-version-error-required c))))
  (:documentation "The version-control program TOOL (a string, \"jj\") is
older than REQUIRED (a version string), or cannot be run at all. FOUND is the
numeric version string the program reported (\"0.46.0\"), or NIL when it could
not be started. Signalled by MAKE-JJ-STORE, before any other jj command runs."))

(define-condition jj-command-error (rev:revision-error)
  ((command :initarg :command :reader jj-command-error-command :initform nil)
   (exit-code :initarg :exit-code :reader jj-command-error-exit-code
              :initform nil)
   (stderr :initarg :stderr :reader jj-command-error-stderr :initform nil))
  (:report (lambda (c s)
             (format s "jj ~{~a~^ ~} exited with ~a"
                     (jj-command-error-command c)
                     (jj-command-error-exit-code c))
             (let ((err (jj-command-error-stderr c)))
               (when (and err (plusp (length err)))
                 (format s ": ~a" (string-right-trim '(#\Newline #\Return) err))))))
  (:documentation "A jj command exited with a status the caller did not
accept. COMMAND is the argument list the caller passed to RUN-JJ (after the
program name and the fixed options), EXIT-CODE the integer status, STDERR the
decoded standard error (a string, possibly empty). Failures with a protocol
meaning (an unknown revision, a stale CAS value, a refused tag move) are
translated to the protocol's conditions instead and never surface as
JJ-COMMAND-ERROR."))
