(in-package #:revision-backend-jj)

;;; Conditions. Everything a revision store reports through the protocol
;;; (REVISION-NOT-FOUND, AMBIGUOUS-REVISION, REF-CONFLICT, TAG-IMMUTABLE,
;;; REVISION-ERROR ...) is REVISION-PROTOCOL's own type: the backend signals
;;; those.
;;;
;;;   revision-error
;;;   ├── vc-tool-version-error (tool found required)   revision-protocol's,
;;;   │                                                  re-exported here
;;;   └── jj-command-error      (command exit-code stderr)
;;;
;;; VC-TOOL-VERSION-ERROR (TOOL "jj", FOUND the numeric version jj reported
;;; such as "0.46.0" or NIL when it could not be started) is signalled by
;;; MAKE-JJ-STORE before any other jj command runs. It is the same condition
;;; revision-backend-git signals (revision-protocol#4); callers that write
;;; STACK-REV-JJ:VC-TOOL-VERSION-ERROR keep working.

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
