(in-package #:revision-backend-jj)

;;; ------------------------------------------------------------------
;;; Machine output. Every jj command whose output the backend reads runs
;;; with one of the -T templates below; each prints one JSON object per entry
;;; on its own line (a literal LF after each object). The templates are part
;;; of the contract: they were run against jj 0.47.1 and the test suite runs
;;; them again against the installed jj (parse-test).
;;;
;;; The parsers are pure functions of the decoded stdout (a string); no jj
;;; runs. Lines are separated by LF; a CR right before an LF is ignored and
;;; blank lines are skipped. A line that is not a JSON object, or lacks a key
;;; the parser documents, or holds a value of the wrong JSON type, signals
;;; REVISION-PROTOCOL:REVISION-ERROR whose message names the line number.
;;; Never another condition type, for any input string. Each returns a fresh
;;; list of plists in input order; tests compare by key (GETF), so key order
;;; inside a plist is not part of the contract. Booleans are T / NIL; JSON
;;; arrays are lists; "" → NIL.
;;; ------------------------------------------------------------------

(defparameter *commit-template*
  "'{\"change_id\":' ++ json(change_id)
++ ',\"commit_id\":' ++ json(commit_id)
++ ',\"parents\":' ++ json(parents.map(|p| p.commit_id()))
++ ',\"parent_change_ids\":' ++ json(parents.map(|p| p.change_id()))
++ ',\"parent_divergent\":' ++ json(parents.map(|p| p.divergent()))
++ ',\"description\":' ++ json(description)
++ ',\"author\":{\"name\":' ++ json(author.name()) ++ ',\"email\":' ++ json(author.email()) ++ ',\"time\":' ++ author.timestamp().format(\"%s\") ++ '}'
++ ',\"committer\":{\"name\":' ++ json(committer.name()) ++ ',\"email\":' ++ json(committer.email()) ++ ',\"time\":' ++ committer.timestamp().format(\"%s\") ++ '}'
++ ',\"conflict\":' ++ json(conflict)
++ ',\"divergent\":' ++ json(divergent)
++ ',\"immutable\":' ++ json(immutable)
++ ',\"empty\":' ++ json(empty)
++ ',\"hidden\":' ++ json(hidden)
++ ',\"root\":' ++ json(root)
++ ',\"working_copy\":' ++ json(current_working_copy)
++ '}' ++ \"\\n\""
  "Template (a `Commit` template) for `jj log --no-graph -T` / `jj show`:
one JSON object per commit. Parsed by PARSE-COMMIT-RECORDS.")

(defparameter *operation-template*
  "'{\"id\":' ++ json(id)
++ ',\"parents\":' ++ json(parents.map(|p| p.id()))
++ ',\"start_ms\":\"' ++ time.start().format(\"%s%3f\") ++ '\"'
++ ',\"end_ms\":\"' ++ time.end().format(\"%s%3f\") ++ '\"'
++ ',\"description\":' ++ json(description)
++ ',\"snapshot\":' ++ json(snapshot)
++ ',\"root\":' ++ json(root)
++ '}' ++ \"\\n\""
  "Template (an `Operation` template) for `jj op log --no-graph -T`: one JSON
object per operation, times as strings of the unix milliseconds (\"%s%3f\":
the root operation prints \"0000\", which is no JSON number). Parsed by
PARSE-OPERATION-RECORDS.")

(defparameter *ref-template*
  "if(!remote && present,
  '{\"name\":' ++ json(name)
  ++ ',\"conflict\":' ++ json(conflict)
  ++ ',\"targets\":' ++ json(added_targets.map(|c| c.commit_id()))
  ++ ',\"target_change_ids\":' ++ json(added_targets.map(|c| c.change_id()))
  ++ '}' ++ \"\\n\")"
  "Template (a `CommitRef` template) for `jj bookmark list -T` and
`jj tag list -T`: one JSON object per present local ref; remote refs and
deleted-but-tracked bookmarks print nothing. A conflicted bookmark lists every
added target. Parsed by PARSE-REF-RECORDS.")

(defparameter *file-template*
  "'{\"path\":' ++ json(path)
++ ',\"type\":' ++ json(file_type)
++ ',\"executable\":' ++ json(executable)
++ ',\"conflict\":' ++ json(conflict)
++ ',\"sides\":' ++ conflict_side_count
++ '}' ++ \"\\n\""
  "Template (a `TreeEntry` template) for `jj file list -T`: one JSON object
per file, paths slash-separated from the repository root. Parsed by
PARSE-FILE-RECORDS.")

(defparameter *diff-template*
  "'{\"status\":' ++ json(status)
++ ',\"source\":' ++ json(source.path())
++ ',\"path\":' ++ json(path)
++ ',\"source_type\":' ++ json(source.file_type())
++ ',\"target_type\":' ++ json(target.file_type())
++ ',\"source_executable\":' ++ json(source.executable())
++ ',\"target_executable\":' ++ json(target.executable())
++ '}' ++ \"\\n\""
  "Template (a `TreeDiffEntry` template) for `jj diff --from A --to B -T`:
one JSON object per changed file. Parsed by PARSE-DIFF-RECORDS.")

;;; ------------------------------------------------------------------
;;; The line engine shared by the five parsers. Every failure is a
;;; REVISION-ERROR naming the line; the JSON layer's own condition
;;; (JSON-PROTOCOL:JSON-ERROR) is the only foreign one translated.
;;; ------------------------------------------------------------------

(defun %parse-fail (line control &rest args)
  (error 'rev:revision-error
         :message (format nil "jj output line ~d: ~?" line control args)))

(defun %blank-line-p (line)
  (every (lambda (c) (member c '(#\Space #\Tab #\Return))) line))

(defun %output-lines (input)
  "→ list of (line-number . text) of INPUT's non-blank lines; a CR right before
the LF is dropped."
  (unless (stringp input)
    (%parse-fail 0 "input is not a string: ~s" (type-of input)))
  (let ((n (length input))
        (start 0)
        (number 0)
        (out '()))
    (loop while (< start n)
          do (let* ((end (or (position #\Newline input :start start) n))
                    (stop (if (and (> end start) (char= #\Return (char input (1- end))))
                              (1- end)
                              end))
                    (text (subseq input start stop)))
               (incf number)
               (unless (%blank-line-p text)
                 (push (cons number text) out))
               (setf start (1+ end))))
    (nreverse out)))

(defun %decode-object (number text)
  (let ((value (handler-case (json:decode text)
                 (json:json-error (e)
                   (%parse-fail number "not JSON (~a)" (json:json-error-message e))))))
    (unless (hash-table-p value)
      (%parse-fail number "not a JSON object"))
    value))

(defun %parse-lines (input fn)
  "FN (object line-number) → plist, for each non-blank line of INPUT."
  (loop for (number . text) in (%output-lines input)
        collect (funcall fn (%decode-object number text) number)))

(defun %field (object key line)
  (multiple-value-bind (value found) (gethash key object)
    (unless found (%parse-fail line "missing key ~s" key))
    value))

(defun %string-field (object key line)
  (let ((v (%field object key line)))
    (unless (stringp v) (%parse-fail line "~s is not a string" key))
    v))

(defun %bool-field (object key line)
  (let ((v (%field object key line)))
    (unless (member v '(t nil)) (%parse-fail line "~s is not a boolean" key))
    v))

(defun %integer-field (object key line)
  (let ((v (%field object key line)))
    (unless (integerp v) (%parse-fail line "~s is not an integer" key))
    v))

(defun %object-field (object key line)
  (let ((v (%field object key line)))
    (unless (hash-table-p v) (%parse-fail line "~s is not an object" key))
    v))

(defun %list-field (object key line predicate what)
  (let ((v (%field object key line)))
    (unless (and (vectorp v) (not (stringp v)) (every predicate v))
      (%parse-fail line "~s is not an array of ~a" key what))
    (coerce v 'list)))

(defun %strings-field (object key line)
  (%list-field object key line #'stringp "strings"))

(defun %bools-field (object key line)
  (%list-field object key line (lambda (x) (member x '(t nil))) "booleans"))

(defun %digits-field (object key line)
  "A string of decimal digits (leading zeros allowed) → integer."
  (let ((v (%string-field object key line)))
    (unless (and (plusp (length v)) (every (lambda (c) (char<= #\0 c #\9)) v))
      (%parse-fail line "~s is not a string of digits: ~s" key v))
    (parse-integer v)))

(defun %enum-field (object key line table &key empty-nil)
  (let ((v (%string-field object key line)))
    (cond ((and empty-nil (string= v "")) nil)
          ((cdr (assoc v table :test #'string=)))
          (t (%parse-fail line "~s has an unknown value ~s" key v)))))

(defparameter +file-types+
  '(("file" . :file) ("symlink" . :symlink) ("tree" . :tree)
    ("git-submodule" . :git-submodule) ("conflict" . :conflict)))

(defparameter +diff-statuses+
  '(("modified" . :modified) ("added" . :added) ("removed" . :removed)
    ("copied" . :copied) ("renamed" . :renamed)))

(defun %signature (object key line)
  (let ((sig (%object-field object key line)))
    (values (%string-field sig "name" line)
            (%string-field sig "email" line)
            (%integer-field sig "time" line))))

(defun parse-commit-records (input)
  "Parse *COMMIT-TEMPLATE* output INPUT (a string). → list of plists:

  (:change-id s :commit-id s :parents (commit-id …) :parent-change-ids (s …)
   :parent-divergent (b …) :description s :author-name s :author-email s :author-time n
   :committer-name s :committer-email s :committer-time n
   :conflict b :divergent b :immutable b :empty b :hidden b :root b
   :working-copy b)

:DESCRIPTION exactly as jj printed it (usually with its final newline);
times are integer unix seconds; PARENTS, PARENT-CHANGE-IDS and
PARENT-DIVERGENT are parallel lists in commit order (the root commit has
none; a root change's parent is the root commit, id 40 zeros)."
  (%parse-lines
   input
   (lambda (o n)
     (multiple-value-bind (author-name author-email author-time) (%signature o "author" n)
       (multiple-value-bind (committer-name committer-email committer-time)
           (%signature o "committer" n)
         (list :change-id (%string-field o "change_id" n)
               :commit-id (%string-field o "commit_id" n)
               :parents (%strings-field o "parents" n)
               :parent-change-ids (%strings-field o "parent_change_ids" n)
               :parent-divergent (%bools-field o "parent_divergent" n)
               :description (%string-field o "description" n)
               :author-name author-name :author-email author-email
               :author-time author-time
               :committer-name committer-name :committer-email committer-email
               :committer-time committer-time
               :conflict (%bool-field o "conflict" n)
               :divergent (%bool-field o "divergent" n)
               :immutable (%bool-field o "immutable" n)
               :empty (%bool-field o "empty" n)
               :hidden (%bool-field o "hidden" n)
               :root (%bool-field o "root" n)
               :working-copy (%bool-field o "working_copy" n)))))))

(defun parse-operation-records (input)
  "Parse *OPERATION-TEMPLATE* output INPUT (a string). → list of plists:

  (:id s :parents (s …) :start-ms n :end-ms n :description s
   :snapshot b :root b)

START-MS / END-MS are integers: the time strings read as decimal digits
(leading zeros allowed; anything else → REVISION-ERROR)."
  (%parse-lines
   input
   (lambda (o n)
     (list :id (%string-field o "id" n)
           :parents (%strings-field o "parents" n)
           :start-ms (%digits-field o "start_ms" n)
           :end-ms (%digits-field o "end_ms" n)
           :description (%string-field o "description" n)
           :snapshot (%bool-field o "snapshot" n)
           :root (%bool-field o "root" n)))))

(defun parse-ref-records (input)
  "Parse *REF-TEMPLATE* output INPUT (a string). → list of plists:

  (:name s :conflict b :targets (commit-id …) :target-change-ids (s …))

TARGETS has one element for a normal ref and two or more for a conflicted
bookmark; TARGET-CHANGE-IDS is parallel to it."
  (%parse-lines
   input
   (lambda (o n)
     (list :name (%string-field o "name" n)
           :conflict (%bool-field o "conflict" n)
           :targets (%strings-field o "targets" n)
           :target-change-ids (%strings-field o "target_change_ids" n)))))

(defun parse-file-records (input)
  "Parse *FILE-TEMPLATE* output INPUT (a string). → list of plists:

  (:path s :type k :executable b :conflict b :sides n)

TYPE is one of :FILE :SYMLINK :TREE :GIT-SUBMODULE :CONFLICT (jj's
file_type strings as keywords); any other string → REVISION-ERROR. SIDES is
the integer conflict_side_count (1 when not conflicted)."
  (%parse-lines
   input
   (lambda (o n)
     (list :path (%string-field o "path" n)
           :type (%enum-field o "type" n +file-types+)
           :executable (%bool-field o "executable" n)
           :conflict (%bool-field o "conflict" n)
           :sides (%integer-field o "sides" n)))))

(defun parse-diff-records (input)
  "Parse *DIFF-TEMPLATE* output INPUT (a string). → list of plists:

  (:status k :source s :path s :source-type k :target-type k
   :source-executable b :target-executable b)

STATUS is one of :MODIFIED :ADDED :REMOVED :COPIED :RENAMED; any other
string → REVISION-ERROR. SOURCE is the source path (equal to PATH unless
copied / renamed). SOURCE-TYPE / TARGET-TYPE are keywords as in
PARSE-FILE-RECORDS, or NIL for jj's \"\" (the side is absent: an added file
has no source type, a removed one no target type)."
  (%parse-lines
   input
   (lambda (o n)
     (list :status (%enum-field o "status" n +diff-statuses+)
           :source (%string-field o "source" n)
           :path (%string-field o "path" n)
           :source-type (%enum-field o "source_type" n +file-types+ :empty-nil t)
           :target-type (%enum-field o "target_type" n +file-types+ :empty-nil t)
           :source-executable (%bool-field o "source_executable" n)
           :target-executable (%bool-field o "target_executable" n)))))
