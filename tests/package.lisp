(defpackage #:revision-backend-jj/tests
  (:use #:cl #:rove)
  (:local-nicknames (#:jj #:revision-backend-jj)
                    (#:rev #:revision-protocol)
                    (#:diff #:diff-protocol)
                    (#:dt #:datetime-protocol)
                    (#:pathlib #:cl-stack-pathlib)))
