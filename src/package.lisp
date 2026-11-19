(defpackage #:revision-backend-jj
  (:use #:cl)
  (:nicknames #:stack-rev-jj)
  (:local-nicknames (#:rev #:revision-protocol)
                    (#:diff #:diff-protocol)
                    (#:dt #:datetime-protocol)
                    (#:proc #:process-protocol)
                    (#:pathlib #:cl-stack-pathlib)
                    (#:json #:json-protocol))
  (:export
   ;; conditions (jj-specific; everything else is a revision-protocol condition).
   ;; VC-TOOL-VERSION-ERROR becomes revision-protocol's symbol, re-exported
   ;; here, once revision-protocol#4 lands.
   #:vc-tool-version-error
   #:vc-tool-version-error-tool
   #:vc-tool-version-error-found
   #:vc-tool-version-error-required
   #:jj-command-error
   #:jj-command-error-command
   #:jj-command-error-exit-code
   #:jj-command-error-stderr

   ;; jj program and version
   #:*jj-program*
   #:*minimum-jj-version*
   #:parse-jj-version
   #:jj-version

   ;; store
   #:jj-store
   #:jj-store-p
   #:make-jj-store
   #:jj-store-path
   #:jj-store-repo-path
   #:jj-store-workspace
   #:jj-store-colocated-p
   #:jj-store-env
   #:run-jj
   #:jj-capabilities

   ;; operation log (recorded time, CAS emulation)
   #:current-operation
   #:list-operations

   ;; jj-only views of refs and conflicts
   #:conflicted-bookmarks
   #:revision-conflicts

   ;; working copy (a revision-protocol target)
   #:jj-working-copy
   #:jj-working-copy-p
   #:make-jj-working-copy
   #:working-copy-store
   #:working-copy-path
   #:working-copy-revision

   ;; read-only revision filesystem (cl-stack-pathlib)
   #:revision-filesystem
   #:revision-filesystem-p
   #:make-revision-filesystem
   #:revision-filesystem-store
   #:revision-filesystem-revision
   #:revision-path

   ;; machine output: the -T templates the backend runs, and their parsers
   #:*commit-template*
   #:*operation-template*
   #:*ref-template*
   #:*file-template*
   #:*diff-template*
   #:parse-commit-records
   #:parse-operation-records
   #:parse-ref-records
   #:parse-file-records
   #:parse-diff-records))
