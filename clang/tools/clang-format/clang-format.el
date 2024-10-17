;;; clang-format.el --- Format code using clang-format  -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Keywords: tools, c
;; Package-Requires: ((cl-lib "0.3"))
;; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

;;; Commentary:

;; This package allows to filter code through clang-format to fix its formatting.
;; clang-format is a tool that formats C/C++/Obj-C code according to a set of
;; style options, see <http://clang.llvm.org/docs/ClangFormatStyleOptions.html>.
;; Note that clang-format 3.4 or newer is required.

;; clang-format.el is available via MELPA and can be installed via
;;
;;   M-x package-install clang-format
;;
;; when ("melpa" . "http://melpa.org/packages/") is included in
;; `package-archives'.  Alternatively, ensure the directory of this
;; file is in your `load-path' and add
;;
;;   (require 'clang-format)
;;
;; to your .emacs configuration.

;; You may also want to bind `clang-format-region' to a key:
;;
;;   (global-set-key [C-M-tab] 'clang-format-region)

;;; Code:

(require 'cl-lib)
(require 'xml)

(defgroup clang-format nil
  "Format code using clang-format."
  :group 'tools)

(defcustom clang-format-executable
  (or (executable-find "clang-format")
      "clang-format")
  "Location of the clang-format executable.

A string containing the name or the full path of the executable."
  :group 'clang-format
  :type '(file :must-match t)
  :risky t)

(defcustom clang-format-style nil
  "Style argument to pass to clang-format.

By default clang-format will load the style configuration from
a file named .clang-format located in one of the parent directories
of the buffer."
  :group 'clang-format
  :type '(choice (string) (const nil))
  :safe #'stringp)
(make-variable-buffer-local 'clang-format-style)

(defcustom clang-format-fallback-style "none"
  "Fallback style to pass to clang-format.

This style will be used if clang-format-style is set to \"file\"
and no .clang-format is found in the directory of the buffer or
one of parent directories. Set to \"none\" to disable formatting
in such buffers."
  :group 'clang-format
  :type 'string
  :safe #'stringp)
(make-variable-buffer-local 'clang-format-fallback-style)

(defun clang-format--extract (xml-node)
  "Extract replacements and cursor information from XML-NODE."
  (unless (and (listp xml-node) (eq (xml-node-name xml-node) 'replacements))
    (error "Expected <replacements> node"))
  (let ((nodes (xml-node-children xml-node))
        (incomplete-format (xml-get-attribute xml-node 'incomplete_format))
        replacements
        cursor)
    (dolist (node nodes)
      (when (listp node)
        (let* ((children (xml-node-children node))
               (text (car children)))
          (cl-case (xml-node-name node)
            (replacement
             (let* ((offset (xml-get-attribute-or-nil node 'offset))
                    (length (xml-get-attribute-or-nil node 'length)))
               (when (or (null offset) (null length))
                 (error "<replacement> node does not have offset and length attributes"))
               (when (cdr children)
                 (error "More than one child node in <replacement> node"))

               (setq offset (string-to-number offset))
               (setq length (string-to-number length))
               (push (list offset length text) replacements)))
            (cursor
             (setq cursor (string-to-number text)))))))

    ;; Sort by decreasing offset, length.
    (setq replacements (sort (delq nil replacements)
                             (lambda (a b)
                               (or (> (car a) (car b))
                                   (and (= (car a) (car b))
                                        (> (cadr a) (cadr b)))))))

    (list replacements cursor (string= incomplete-format "true"))))

(defun clang-format--replace (offset length &optional text)
  "Replace the region defined by OFFSET and LENGTH with TEXT.
OFFSET and LENGTH are measured in bytes, not characters.  OFFSET
is a zero-based file offset, assuming ‘utf-8-unix’ coding."
  (let ((start (clang-format--filepos-to-bufferpos offset 'exact 'utf-8-unix))
        (end (clang-format--filepos-to-bufferpos (+ offset length) 'exact
                                                 'utf-8-unix)))
    (goto-char start)
    (delete-region start end)
    (when text
      (insert text))))

;; ‘bufferpos-to-filepos’ and ‘filepos-to-bufferpos’ are new in Emacs 25.1.
;; Provide fallbacks for older versions.
(defalias 'clang-format--bufferpos-to-filepos
  (if (fboundp 'bufferpos-to-filepos)
      'bufferpos-to-filepos
    (lambda (position &optional _quality _coding-system)
      (1- (position-bytes position)))))

(defalias 'clang-format--filepos-to-bufferpos
  (if (fboundp 'filepos-to-bufferpos)
      'filepos-to-bufferpos
    (lambda (byte &optional _quality _coding-system)
      (byte-to-position (1+ byte)))))

(defun clang-format--git-diffs-get-diff-lines (file-orig file-new)
  "Return all line regions that contain diffs between FILE-ORIG and
FILE-NEW.  If there is no diff 'nil' is returned. Otherwise the
return is a 'list' of lines in the format '--lines=<start>:<end>'
which can be passed directly to 'clang-format'"
  ;; Temporary buffer for output of diff.
  (with-temp-buffer
    (let ((status (call-process
                   "diff"
                   nil
                   (current-buffer)
                   nil
                   ;; Binary diff has different behaviors that we
                   ;; aren't interested in.
                   "-a"
                   ;; Printout changes as only the line groups.
                   "--changed-group-format=--lines=%dF:%dL "
                   ;; Ignore unchanged content.
                   "--unchanged-group-format="
                   file-orig
                   file-new
                   )
                  )
          (stderr (concat (if (zerop (buffer-size)) "" ": ")
                          (buffer-substring-no-properties
                           (point-min) (line-end-position)))))
      (when (stringp status)
        (error "(diff killed by signal %s%s)" status stderr))
      (unless (= status 0)
        (unless (= status 1)
          (error "(diff returned unsuccessfully %s%s)" status stderr)))


      (if (= status 0)
          ;; Status == 0 -> no Diff.
          nil
        (progn
          ;; Split "--lines=<S0>:<E0>... --lines=<SN>:<SN>" output to
          ;; a list for return.
          (s-split
           " "
           (string-trim
            (buffer-substring-no-properties
             (point-min) (point-max)))))))))

(defun clang-format--git-diffs-get-git-head-file ()
  "Returns a temporary file with the content of 'buffer-file-name' at
git revision HEAD. If the current buffer is either not a file or not
in a git repo, this results in an error"
  ;; Needs current buffer to be a file
  (unless (buffer-file-name)
    (error "Buffer is not visiting a file"))
  ;; Need to be able to find version control (git) root
  (unless (vc-root-dir)
    (error "File not known to git"))
  ;; Need version control to in fact be git
  (unless (string-equal (vc-backend (buffer-file-name)) "Git")
    (error "Not using git"))

  (let ((tmpfile-git-head (make-temp-file "clang-format-tmp-git-head-content")))
    ;; Get filename relative to git root
    (let ((git-file-name (substring
                          (expand-file-name (buffer-file-name))
                          (string-width (expand-file-name (vc-root-dir)))
                          nil)))
      (let ((status (call-process
                     "git"
                     nil
                     `(:file, tmpfile-git-head)
                     nil
                     "show" (concat "HEAD:" git-file-name)))
            (stderr (with-temp-buffer
                      (unless (zerop (cadr (insert-file-contents tmpfile-git-head)))
                        (insert ": "))
                      (buffer-substring-no-properties
                       (point-min) (line-end-position)))))
        (when (stringp status)
          (error "(git show HEAD:%s killed by signal %s%s)"
                 git-file-name status stderr))
        (unless (zerop status)
          (error "(git show HEAD:%s returned unsuccessfully %s%s)"
                 git-file-name status stderr))))
    ;; Return temporary file so we can diff it.
    tmpfile-git-head))

(defun clang-format--region-impl (start end &optional style assume-file-name lines)
  "Common implementation for 'clang-format-buffer',
'clang-format-region', and 'clang-format-git-diffs'. START and END
refer to the region to be formatter. STYLE and ASSUME-FILE-NAME are
used for configuring the clang-format. And LINES is used to pass
specific locations for reformatting (i.e diff locations)."
  (unless style
    (setq style clang-format-style))

  (unless assume-file-name
    (setq assume-file-name (buffer-file-name (buffer-base-buffer))))

  (let ((file-start (clang-format--bufferpos-to-filepos start 'approximate
                                                        'utf-8-unix))
        (file-end (clang-format--bufferpos-to-filepos end 'approximate
                                                      'utf-8-unix))
        (cursor (clang-format--bufferpos-to-filepos (point) 'exact 'utf-8-unix))
        (temp-buffer (generate-new-buffer " *clang-format-temp*"))
        (temp-file (make-temp-file "clang-format"))
        ;; Output is XML, which is always UTF-8.  Input encoding should match
        ;; the encoding used to convert between buffer and file positions,
        ;; otherwise the offsets calculated above are off.  For simplicity, we
        ;; always use ‘utf-8-unix’ and ignore the buffer coding system.
        (default-process-coding-system '(utf-8-unix . utf-8-unix)))
    (unwind-protect
        (let ((status (apply #'call-process-region
                             nil nil clang-format-executable
                             nil `(,temp-buffer ,temp-file) nil
                             `("--output-replacements-xml"
                               ;; Guard against a nil assume-file-name.
                               ;; If the clang-format option -assume-filename
                               ;; is given a blank string it will crash as per
                               ;; the following bug report
                               ;; https://bugs.llvm.org/show_bug.cgi?id=34667
                               ,@(and assume-file-name
                                      (list "--assume-filename" assume-file-name))
                               ,@(and style (list "--style" style))
                               "--fallback-style" ,clang-format-fallback-style
                               ,@(and lines lines)
                               ,@(and (not lines)
                                      (list
                                       "--offset" (number-to-string file-start)
                                       "--length" (number-to-string
                                                   (- file-end file-start))))
                               "--cursor" ,(number-to-string cursor))))
              (stderr (with-temp-buffer
                        (unless (zerop (cadr (insert-file-contents temp-file)))
                          (insert ": "))
                        (buffer-substring-no-properties
                         (point-min) (line-end-position)))))
          (cond
           ((stringp status)
            (error "(clang-format killed by signal %s%s)" status stderr))
           ((not (zerop status))
            (error "(clang-format failed with code %d%s)" status stderr)))

          (cl-destructuring-bind (replacements cursor incomplete-format)
              (with-current-buffer temp-buffer
                (clang-format--extract (car (xml-parse-region))))
            (save-excursion
              (dolist (rpl replacements)
                (apply #'clang-format--replace rpl)))
            (when cursor
              (goto-char (clang-format--filepos-to-bufferpos cursor 'exact
                                                             'utf-8-unix)))
            (if incomplete-format
                (message "(clang-format: incomplete (syntax errors)%s)" stderr)
              (message "(clang-format: success%s)" stderr))))
      (delete-file temp-file)
      (when (buffer-name temp-buffer) (kill-buffer temp-buffer)))))

;;;###autoload
(defun clang-format-git-diffs (&optional style assume-file-name)
  "The same as 'clang-format-buffer' but only operates on the git
diffs from HEAD in the buffer. If no STYLE is given uses
`clang-format-style'. Use ASSUME-FILE-NAME to locate a style config
file. If no ASSUME-FILE-NAME is given uses the function
`buffer-file-name'."
  (interactive)
  (let ((tmpfile-git-head
         (clang-format--git-diffs-get-git-head-file))
        (tmpfile-curbuf (make-temp-file "clang-format-git-tmp")))
    ;; Move current buffer to a temporary file to take a diff. Even if
    ;; current-buffer is backed by a file, we want to diff the buffer
    ;; contents which might not be saved.
    (write-region nil nil tmpfile-curbuf nil 'nomessage)
    ;; Git list of lines with a diff.
    (let ((diff-lines
           (clang-format--git-diffs-get-diff-lines
            tmpfile-git-head tmpfile-curbuf)))
      ;; If we have any diffs, format them.
      (when diff-lines
        (clang-format--region-impl
         (point-min)
         (point-max)
         style
         assume-file-name
         diff-lines)))))

;;;###autoload
(defun clang-format-region (start end &optional style assume-file-name)
  "Use clang-format to format the code between START and END according
to STYLE.  If called interactively uses the region or the current
statement if there is no no active region. If no STYLE is given uses
`clang-format-style'. Use ASSUME-FILE-NAME to locate a style config
file, if no ASSUME-FILE-NAME is given uses the function
`buffer-file-name'."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (list (point) (point))))
  (clang-format--region-impl start end style assume-file-name))

;;;###autoload
(defun clang-format-buffer (&optional style assume-file-name)
  "Use clang-format to format the current buffer according to STYLE.
If no STYLE is given uses `clang-format-style'. Use ASSUME-FILE-NAME
to locate a style config file. If no ASSUME-FILE-NAME is given uses
the function `buffer-file-name'."
  (interactive)
  (clang-format--region-impl
   (point-min)
   (point-max)
   style
   assume-file-name))

;;;###autoload
(defalias 'clang-format 'clang-format-region)

(provide 'clang-format)
;;; clang-format.el ends here
