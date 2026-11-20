(in-package #:revision-backend-jj/tests)

;;; 0.3.0 — revision-protocol 0.4.0 (#2): :EXPECTED without :REF signals;
;;; TAG-REWRITE-P is NIL, so REPLACE-ANNOTATION is never offered.

(deftest expected-without-ref-signals
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r))
           (ops (length (jj-log-ops r))))
      (ok (signals (rev:commit-revision s (diff:make-tree) :expected (getf k :c3))
                   'rev:revision-error))
      (ok (signals (rev:commit-revision s (diff:make-tree) :expected nil) 'rev:revision-error))
      (ok (= ops (length (jj-log-ops r))) "nothing written"))))

(deftest no-tag-rewrite
  (with-test-repo (r)
    (let* ((k (build-linear r))
           (s (open-store r)))
      (ok (eq nil (rev:tag-rewrite-p s)))
      (ok (not (member 'rev:replace-annotation
                       (restart-names-in 'rev:tag-immutable
                                         (lambda () (rev:tag-revision s "v1" (getf k :c3)))))))
      (ok (signals (rev:tag-revision s "v1" (getf k :c1) :annotation "x") 'rev:revision-error)
          "an annotation is refused before any tag rule"))))
