(in-package #:revision-backend-jj/tests)

;;; History builders. Each takes a fresh TREPO, builds a history with the real
;;; jj at fixed times, and returns a plist of names → CHANGE ids. Times are
;;; unix seconds: commit time = committer (:recorded on the revision),
;;; author time = :valid; every operation's time is given too (JJ_OP_TIMESTAMP)
;;; so the operation log (the recorded-time axis of REV-AS-OF) is known.
;;; The working copy @ ends as an empty change on the last commit unless
;;; stated.

(defun symlink (repo target relative)
  "Create a symlink RELATIVE → TARGET in REPO's workspace (POSIX only)."
  (ensure-directories-exist (repo-file repo relative))
  (uiop:run-program (list "ln" "-s" target (uiop:native-namestring (repo-file repo relative)))))

(defun build-linear (repo)
  "c1 ← c2 ← c3 (each on the previous), bookmark main following the tip.
c1  commit t0        author t0         op t0+10, main→c1 op t0+20   a.txt
c2  commit t0+100    author t0-10000   op t0+110, main→c2 op t0+120 a.txt edited, b.txt
c3  commit t0+200    author t0+150     op t0+210, main→c3 op t0+220 b.txt removed, dir/c.txt
Tags (op t0+300): v1 at c1, v2 at c2 (so c1, c2 are immutable; c3 is not).
@ = an empty change on c3."
  (put-file repo "a.txt" (lines "one"))
  (let ((c1 (commit-all repo "first" :at +t0+)))
    (set-bookmark repo "main" c1 :at (+ +t0+ 20))
    (put-file repo "a.txt" (lines "one" "two"))
    (put-file repo "b.txt" (lines "bee"))
    (let ((c2 (commit-all repo "second" :at (+ +t0+ 100) :author-at (- +t0+ 10000))))
      (set-bookmark repo "main" c2 :at (+ +t0+ 120))
      (remove-file repo "b.txt")
      (put-file repo "dir/c.txt" (lines "see"))
      (let ((c3 (commit-all repo (format nil "third~%~%with a body") :at (+ +t0+ 200)
                                                                    :author-at (+ +t0+ 150))))
        (set-bookmark repo "main" c3 :at (+ +t0+ 220))
        (set-tag repo "v1" c1 :at (+ +t0+ 300))
        (set-tag repo "v2" c2 :at (+ +t0+ 300))
        (list :c1 c1 :c2 c2 :c3 c3 :wc (change-of repo "@"))))))

(defun build-merge (repo)
  "base ← m1 ← x (x = merge of m1 and f2, first parent m1); base ← f1 ← f2.
Commit times: base t0, f1 t0+100, f2 t0+200, m1 t0+300, x t0+400.
Author times: f1 t0-5000 (old), others = commit time.
Files: base.txt; feature.txt (f1, edited in f2); main.txt (m1).
Bookmarks: main → x, feature → f2. @ = an empty change on x."
  (put-file repo "base.txt" (lines "base"))
  (let ((base (commit-all repo "base" :at +t0+)))
    (put-file repo "feature.txt" (lines "f1"))
    (let ((f1 (commit-all repo "f1" :at (+ +t0+ 100) :author-at (- +t0+ 5000))))
      (put-file repo "feature.txt" (lines "f1" "f2"))
      (let ((f2 (commit-all repo "f2" :at (+ +t0+ 200))))
        (new-change repo (list base) :at (+ +t0+ 250))
        (put-file repo "main.txt" (lines "m1"))
        (let ((m1 (commit-all repo "m1" :at (+ +t0+ 300))))
          (new-change repo (list m1 f2) :at (+ +t0+ 350))
          (let ((x (commit-all repo "merge feature" :at (+ +t0+ 400))))
            (set-bookmark repo "main" x :at (+ +t0+ 450))
            (set-bookmark repo "feature" f2 :at (+ +t0+ 450))
            (list :base base :f1 f1 :f2 f2 :m1 m1 :x x)))))))

(defun build-criss-cross (repo)
  "a; b and c both on a; d = merge(b, c); e = merge(c, b). heads(::d & ::e) =
{b, c}. Also u, an unrelated change on root(). Bookmarks left → d, right → e,
other → u. Commit times a t0, b +100, c +200, d +300, e +400, u +500.
@ = an empty change on u."
  (put-file repo "a.txt" (lines "a"))
  (let ((a (commit-all repo "a" :at +t0+)))
    (put-file repo "b.txt" (lines "b"))
    (let ((b (commit-all repo "b" :at (+ +t0+ 100))))
      (new-change repo (list a) :at (+ +t0+ 150))
      (put-file repo "c.txt" (lines "c"))
      (let ((c (commit-all repo "c" :at (+ +t0+ 200))))
        (new-change repo (list b c) :at (+ +t0+ 250))
        (let ((d (commit-all repo "d" :at (+ +t0+ 300))))
          (new-change repo (list c b) :at (+ +t0+ 350))
          (let ((e (commit-all repo "e" :at (+ +t0+ 400))))
            (new-change repo (list "root()") :at (+ +t0+ 450))
            (put-file repo "u.txt" (lines "u"))
            (let ((u (commit-all repo "u" :at (+ +t0+ 500))))
              (set-bookmark repo "left" d :at (+ +t0+ 600))
              (set-bookmark repo "right" e :at (+ +t0+ 600))
              (set-bookmark repo "other" u :at (+ +t0+ 600))
              (list :a a :b b :c c :d d :e e :u u))))))))

;;; Content history: every kind of file jj records.

(defparameter +main-v1+ (lines "(defun main ()" "  (print :hello))" "" "(main)"))
(defparameter +main-v2+ (lines "(defun main ()" "  (print :hello-world))" "" "(main)"))
(defparameter +ten-lines+ (lines "1" "2" "3" "4" "5" "6" "7" "8" "9" "10"))
(defparameter +ten-lines-edited+ (lines "1" "2" "3" "4" "5" "6" "7" "8" "9" "ten"))
(defparameter +bin-v1+ (octets 0 1 2 3 255 0 10 13))
(defparameter +bin-v2+ (octets 0 1 2 4 255 0 10 13 7))
(defparameter +latin-v1+ (octets 99 97 102 233 10))              ; "café\n" in Latin-1
(defparameter +crlf-v1+ (format nil "one~c~ctwo~c~c" #\Return #\Newline #\Return #\Newline))
(defparameter +crlf-v2+ (format nil "one~c~ctwo~c~cthree~c~c" #\Return #\Newline #\Return
                                #\Newline #\Return #\Newline))

(defun build-content (repo)
  "k1 ← k2 ← k3, bookmark main → k3.
k1: README, bin/data.bin (NUL bytes), crlf.txt, empty.txt (0 bytes),
    latin.txt (invalid UTF-8), old/name.txt (ten lines), run.sh, src/main.lisp,
    thing; link → README (a symlink, not on Windows).
k2: run.sh executable (jj file chmod), link → src/main.lisp, bin/data.bin
    changed, crlf.txt gains a line, empty.txt removed, old/name.txt moved to
    new/name.txt with its last line edited, src/main.lisp edited.
k3: the file thing replaced by a directory thing/inner.txt."
  (put-file repo "README" (lines "hello"))
  (put-file repo "bin/data.bin" +bin-v1+)
  (put-file repo "crlf.txt" +crlf-v1+)
  (put-file repo "empty.txt" (octets))
  (put-file repo "latin.txt" +latin-v1+)
  (put-file repo "old/name.txt" +ten-lines+)
  (put-file repo "run.sh" (lines "echo run"))
  (put-file repo "src/main.lisp" +main-v1+)
  (put-file repo "thing" (lines "a file"))
  (unless (windows-p) (symlink repo "README" "link"))
  (let ((k1 (commit-all repo "k1" :at +t0+)))
    (jj* repo '("file" "chmod" "x" "root-file:\"run.sh\"") :env (time-env (+ +t0+ 50)))
    (unless (windows-p)
      (remove-file repo "link")
      (symlink repo "src/main.lisp" "link"))
    (put-file repo "bin/data.bin" +bin-v2+)
    (put-file repo "crlf.txt" +crlf-v2+)
    (remove-file repo "empty.txt")
    (remove-file repo "old/name.txt")
    (put-file repo "new/name.txt" +ten-lines-edited+)
    (put-file repo "src/main.lisp" +main-v2+)
    (let ((k2 (commit-all repo "k2" :at (+ +t0+ 100))))
      (remove-file repo "thing")
      (put-file repo "thing/inner.txt" (lines "inner"))
      (let ((k3 (commit-all repo "k3" :at (+ +t0+ 200))))
        (set-bookmark repo "main" k3 :at (+ +t0+ 300))
        (list :k1 k1 :k2 k2 :k3 k3)))))

(defun build-conflict (repo)
  "base: a.txt \"one\", other.txt; left and right both on base, editing a.txt
to \"left\" / \"right\"; m = merge(left, right), committed with the conflict
unresolved (jj records it). Bookmark main → m. @ = an empty change on m
(it inherits the conflict)."
  (put-file repo "a.txt" (lines "one"))
  (put-file repo "other.txt" (lines "other"))
  (let ((base (commit-all repo "base" :at +t0+)))
    (put-file repo "a.txt" (lines "left"))
    (let ((left (commit-all repo "left" :at (+ +t0+ 100))))
      (new-change repo (list base) :at (+ +t0+ 150))
      (put-file repo "a.txt" (lines "right"))
      (let ((right (commit-all repo "right" :at (+ +t0+ 200))))
        (new-change repo (list left right) :at (+ +t0+ 250))
        (let ((m (commit-all repo "merge" :at (+ +t0+ 300))))
          (set-bookmark repo "main" m :at (+ +t0+ 400))
          (list :base base :left left :right right :m m))))))

(defun build-working-copy (repo)
  "base: tracked.txt, keep.txt, .gitignore (\"ignored.txt\"); @ an empty change
on it; bookmark main → base."
  (put-file repo "tracked.txt" (lines "tracked"))
  (put-file repo "keep.txt" (lines "keep"))
  (put-file repo ".gitignore" (lines "ignored.txt"))
  (let ((base (commit-all repo "base" :at +t0+)))
    (set-bookmark repo "main" base :at (+ +t0+ 20))
    (list :base base)))

(defun build-many (repo &key (rounds 10))
  "One change, then ROUNDS rounds of `jj duplicate` over every non-root
non-@ commit: 2^ROUNDS changes with random change ids and distinct commit
ids, for ambiguous 4-character prefixes."
  (put-file repo "x.txt" (lines "x"))
  (commit-all repo "dup" :at +t0+)
  (dotimes (i rounds)
    (jj* repo '("duplicate" "all() ~ root() ~ @") :ignore-working-copy t
         :env (time-env (+ +t0+ i 1)))))

(defun colliding-prefix (ids)
  "→ (values prefix matching-ids) for some 4-character prefix shared by two
or more of IDS, or NIL."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (id ids)
      (push id (gethash (subseq id 0 4) table)))
    (loop for prefix being the hash-keys of table using (hash-value matches)
          when (> (length matches) 1)
            do (return-from colliding-prefix (values prefix (sort (copy-list matches) #'string<))))
    nil))
