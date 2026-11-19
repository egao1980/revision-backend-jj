(defsystem "revision-backend-jj"
  :version "0.1.0"
  :description "revision-protocol backend over the jj (Jujutsu) CLI: changes as revisions (change ids, commit id in provenance), bookmarks and tags as refs with CAS emulated through the operation log, recorded-time as-of via --at-op, graph walks via revsets, state diffs via jj diff --git and diff-protocol, working-copy drift and capture of @, a read-only cl-stack-pathlib filesystem per revision"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "revision-protocol" "0.2.0")
               (:version "diff-protocol" "0.2.0")
               (:version "datetime-protocol" "0.1.3")
               (:version "process-protocol" "0.3.0")
               (:version "process-backend-uiop" "0.2.0")
               (:version "cl-stack-pathlib" "0.4.0")
               (:version "encoding-protocol" "0.2.0")
               (:version "json-protocol" "0.2.1")
               (:version "json-backend-jzon" "0.2.0")
               (:version "bordeaux-threads" "0.9.4"))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "jj")
               (:file "parse")
               (:file "store")
               (:file "working-copy")
               (:file "filesystem"))
  :in-order-to ((test-op (test-op "revision-backend-jj/tests"))))

(defsystem "revision-backend-jj/tests"
  :depends-on ("revision-backend-jj" "revision-protocol" "diff-protocol"
               "datetime-protocol" "cl-stack-pathlib" "bordeaux-threads" "babel" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "fixtures")
               (:file "version-test")
               (:file "parse-test")
               (:file "resolve-test")
               (:file "ref-test")
               (:file "commit-test")
               (:file "graph-test")
               (:file "as-of-test")
               (:file "content-test")
               (:file "conflict-test")
               (:file "working-copy-test")
               (:file "filesystem-test")
               (:file "law-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
