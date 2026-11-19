(in-package #:revision-backend-jj/tests)

;;; Graph walks, merge bases, ancestry, ranges, heads — against jj revsets.

(defun topo (repo revset)
  "Real jj: change ids of REVSET, parents first (jj log --reversed)."
  (jj-lines repo "log" "--no-graph" "--reversed" "-r" revset "-T" "change_id ++ \"\\n\""))

(deftest parents-children-heads
  (with-test-repo (r)
    (let* ((k (build-merge r))
           (s (open-store r)))
      (ok (equal (list (getf k :m1) (getf k :f2)) (ids (rev:revision-parents s (getf k :x)))))
      (ok (null (rev:revision-parents s (getf k :base))) "the root commit is no parent")
      (ok (set= (list (getf k :f1) (getf k :m1)) (ids (rev:revision-children s (getf k :base)))))
      (ok (set= (changes-of r (format nil "children(~a)" (getf k :base)))
                (ids (rev:revision-children s (getf k :base)))))
      (ok (set= (changes-of r "heads(all())") (ids (rev:heads s))))
      (ok (member (change-of r "@") (ids (rev:heads s)) :test #'equal)
          "the working-copy commit is a head")
      (ok (not (member "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" (ids (rev:heads s)) :test #'equal)))
      (ok (set= (list (change-of r "@")) (ids (rev:revision-children s (getf k :x))))))))

(deftest-parametrize walk-orders
    ((order from until) :ids ("topo-x" "topo-x-until-f1" "first-parent-x" "topo-d" "topo-left-right")
     (:topo :x nil)
     (:topo :x :f1)
     (:first-parent :x nil)
     (:topo :d nil)
     (:topo '(:d :e) '(:b)))
  (with-test-repo (r)
    (let* ((k (if (member from '(:x)) (build-merge r) (build-criss-cross r)))
           (s (open-store r))
           (from-ids (mapcar (lambda (x) (getf k x)) (uiop:ensure-list from)))
           (until-ids (mapcar (lambda (x) (getf k x)) (uiop:ensure-list until)))
           (revset (format nil "(~{::~a~^ | ~})~@[ ~~ (~{::~a~^ | ~})~] ~~ root()"
                           from-ids until-ids))
           (expected (if (eq order :first-parent)
                         (topo r (format nil "first_ancestors(~a) ~~ root()" (first from-ids)))
                         (topo r revset)))
           (walk (rev:walk-revisions s (if (cdr from-ids) from-ids (first from-ids))
                                     :order order
                                     :until (when until-ids
                                              (if (cdr until-ids) until-ids (first until-ids))))))
      (ok (equal expected (ids walk)) (format nil "~(~a~) = jj log --reversed" order))
      (ok (equal (reverse expected)
                 (ids (rev:walk-revisions s (if (cdr from-ids) from-ids (first from-ids))
                                          :order order :reverse t
                                          :until (when until-ids
                                                   (if (cdr until-ids) until-ids (first until-ids))))))
          "reverse"))))

(deftest walk-time-order
  (with-test-repo (r)
    (let* ((k (build-merge r))
           (s (open-store r))
           (walk (rev:walk-revisions s (getf k :x) :order :time)))
      (ok (equal (list (getf k :base) (getf k :f1) (getf k :f2) (getf k :m1) (getf k :x)) (ids walk))
          "ascending committer time")
      (ok (equal (mapcar #'unix (mapcar #'rev:revision-recorded-at walk))
                 (sort (mapcar #'unix (mapcar #'rev:revision-recorded-at walk)) #'<))))))

(deftest walk-first-parent-skips-the-side-branch
  (with-test-repo (r)
    (let* ((k (build-merge r))
           (s (open-store r)))
      (ok (equal (list (getf k :base) (getf k :m1) (getf k :x))
                 (ids (rev:walk-revisions s (rev:rev-ref "main") :order :first-parent)))))))

(deftest walk-footprint
  (with-test-repo (r)
    (let* ((k (build-merge r))
           (s (open-store r))
           (all (topo r (format nil "::~a ~~ root()" (getf k :x)))))
      (flet ((keep (&rest names)
               (remove-if-not (lambda (id) (member id (mapcar (lambda (n) (getf k n)) names)
                                                   :test #'equal))
                              all)))
        (ok (equal (keep :f1 :f2 :x)
                   (ids (rev:walk-revisions s (getf k :x) :footprint '("tree:/feature.txt"))))
            "the merge's delta (against m1) adds feature.txt, so it is kept; walk order unchanged")
        (ok (equal (keep :m1)
                   (ids (rev:walk-revisions s (getf k :x) :footprint '("tree:/main.txt")))))
        (ok (equal all (ids (rev:walk-revisions s (getf k :x) :footprint nil))) "NIL keeps all")))))

(deftest merge-base-and-ancestry
  (with-test-repo (r)
    (let* ((k (build-criss-cross r))
           (s (open-store r)))
      (ok (set= (list (getf k :b) (getf k :c))
                (ids (rev:merge-base s (getf k :d) (getf k :e) :all t))))
      (ok (set= (changes-of r (format nil "heads(::~a & ::~a)" (getf k :d) (getf k :e)))
                (ids (rev:merge-base s (getf k :d) (getf k :e) :all t))))
      (let ((one (rev:merge-base s (getf k :d) (getf k :e))))
        (ok (member (rev:revision-id one) (list (getf k :b) (getf k :c)) :test #'equal))
        (ok (equal (first (changes-of r (format nil "heads(::~a & ::~a)" (getf k :d) (getf k :e))))
                   (rev:revision-id one))
            "ALL NIL: the first in jj log order"))
      (ok (equal (getf k :a) (rev:revision-id (rev:merge-base s (getf k :b) (getf k :c)))))
      (ok (null (rev:merge-base s (getf k :d) (getf k :u))) "only the root is common → NIL")
      (ok (null (rev:merge-base s (getf k :d) (getf k :u) :all t)))
      (ok (rev:ancestor-p s (getf k :a) (getf k :d)))
      (ok (rev:ancestor-p s (getf k :d) (getf k :d)) "itself")
      (ok (not (rev:ancestor-p s (getf k :d) (getf k :a))))
      (ok (not (rev:ancestor-p s (getf k :u) (getf k :d))))
      (ok (rev:ancestor-p s (rev:rev-ref "left") (getf k :d))))))

(deftest revision-range
  (with-test-repo (r)
    (let* ((k (build-merge r))
           (s (open-store r)))
      (ok (equal (topo r (format nil "::~a ~~ ::~a" (getf k :x) (getf k :m1)))
                 (ids (rev:revision-range s (getf k :x) (getf k :m1)))))
      (ok (set= (list (getf k :f1) (getf k :f2) (getf k :x))
                (ids (rev:revision-range s (getf k :x) (getf k :m1)))))
      (ok (equal (topo r (format nil "::~a ~~ root()" (getf k :x)))
                 (ids (rev:revision-range s (getf k :x) nil)))
          "nothing excluded")
      (ok (null (rev:revision-range s (getf k :m1) (getf k :x))))
      (ok (set= (list (getf k :f1) (getf k :f2) (getf k :m1))
                (ids (rev:revision-range s (list (getf k :m1) (getf k :f2)) (list (getf k :base)))))))))

(deftest graph-follows-rewrites
  (with-test-repo (r)
    (let* ((k (build-merge r))
           (s (open-store r)))
      ;; Rewrite f1: jj rebases f2 and x onto the new commit; ids stay.
      (jj* r (list "describe" "-r" (getf k :f1) "-m" "f1 reworded") :ignore-working-copy t
           :env (time-env (+ +t0+ 600)))
      (ok (equal (list (getf k :m1) (getf k :f2)) (ids (rev:revision-parents s (getf k :x)))))
      (ok (equal "f1 reworded" (rev:revision-message (first (rev:revision-parents s (getf k :f2))))))
      (ok (equal (topo r (format nil "::~a ~~ root()" (getf k :x)))
                 (ids (rev:walk-revisions s (getf k :x))))))))
