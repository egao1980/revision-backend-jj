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
  (declare (ignore input))
  (%not-implemented 'parse-commit-records))

(defun parse-operation-records (input)
  "Parse *OPERATION-TEMPLATE* output INPUT (a string). → list of plists:

  (:id s :parents (s …) :start-ms n :end-ms n :description s
   :snapshot b :root b)

START-MS / END-MS are integers: the time strings read as decimal digits
(leading zeros allowed; anything else → REVISION-ERROR)."
  (declare (ignore input))
  (%not-implemented 'parse-operation-records))

(defun parse-ref-records (input)
  "Parse *REF-TEMPLATE* output INPUT (a string). → list of plists:

  (:name s :conflict b :targets (commit-id …) :target-change-ids (s …))

TARGETS has one element for a normal ref and two or more for a conflicted
bookmark; TARGET-CHANGE-IDS is parallel to it."
  (declare (ignore input))
  (%not-implemented 'parse-ref-records))

(defun parse-file-records (input)
  "Parse *FILE-TEMPLATE* output INPUT (a string). → list of plists:

  (:path s :type k :executable b :conflict b :sides n)

TYPE is one of :FILE :SYMLINK :TREE :GIT-SUBMODULE :CONFLICT (jj's
file_type strings as keywords); any other string → REVISION-ERROR. SIDES is
the integer conflict_side_count (1 when not conflicted)."
  (declare (ignore input))
  (%not-implemented 'parse-file-records))

(defun parse-diff-records (input)
  "Parse *DIFF-TEMPLATE* output INPUT (a string). → list of plists:

  (:status k :source s :path s :source-type k :target-type k
   :source-executable b :target-executable b)

STATUS is one of :MODIFIED :ADDED :REMOVED :COPIED :RENAMED; any other
string → REVISION-ERROR. SOURCE is the source path (equal to PATH unless
copied / renamed). SOURCE-TYPE / TARGET-TYPE are keywords as in
PARSE-FILE-RECORDS, or NIL for jj's \"\" (the side is absent: an added file
has no source type, a removed one no target type)."
  (declare (ignore input))
  (%not-implemented 'parse-diff-records))
