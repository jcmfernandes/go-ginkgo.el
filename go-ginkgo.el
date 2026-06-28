;;; go-ginkgo.el --- Run Ginkgo (BDD) specs from Go buffers, tree-sitter aware -*- lexical-binding: t; -*-

;; Copyright (C) 2026 João Moreira Fernandes

;; Author: João Moreira Fernandes <anusko@gmail.com>
;; Maintainer: João Moreira Fernandes <anusko@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, tools, go, testing
;; URL: https://github.com/jcmfernandes/go-ginkgo

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; go-ginkgo runs Ginkgo (https://onsi.github.io/ginkgo/) BDD specs straight
;; from a Go buffer, driving the `ginkgo' CLI through `compilation-mode'.  It is
;; a tree-sitter-native rework of the unmaintained, Ginkgo-v1-era
;; garslo/ginkgo-mode.  Two design choices make it reliable on modern Ginkgo:
;;
;;   - FINDING THE SPEC AT POINT uses tree-sitter (the buffer's Go parser, e.g.
;;     from `go-ts-mode') rather than a backward text scan for "Describe(" and
;;     friends.  It walks up the syntax tree to the enclosing container/spec
;;     `call_expression' and reads its first string-literal argument.  This
;;     understands the full Ginkgo v2 node set -- Describe/Context/When/It/
;;     Specify/DescribeTable/Entry and their F (focused) and P/X (pending)
;;     decorator variants -- and the real call nesting, so it cannot be fooled
;;     by the text "It(" appearing inside a comment or string.
;;
;;   - THE FOCUS IS AN RE2 REGEXP.  `ginkgo --focus' takes a Go (RE2) regexp,
;;     so a description containing metacharacters -- e.g. the parens in
;;     "handles (key) lookups" -- would, passed verbatim, match nothing and
;;     silently run zero specs.  go-ginkgo escapes the description as an RE2
;;     literal first.  (Emacs's own `regexp-quote' is wrong for this: it leaves
;;     ( ) { } unescaped because they are literal in Emacs regexp syntax,
;;     whereas in RE2 they are metacharacters.)  By default it also stitches
;;     together the *full ancestry* of descriptions, so focusing a deeply
;;     nested `It' targets that one spec rather than every spec that happens to
;;     share its innermost text (see `go-ginkgo-focus-strategy').
;;
;; Output goes through a dedicated `compilation-mode' derivative: navigable
;; (RET / C-x ` jump to the failing line), re-runnable (g), and ANSI-coloured.
;;
;; Quick start:
;;
;;   (require 'go-ginkgo)
;;   (add-hook 'go-ts-mode-hook #'go-ginkgo-mode)
;;   (setq go-ginkgo-keymap-prefix "C-c G")   ; or bind go-ginkgo-command-map
;;
;; The `ginkgo' binary must be on `exec-path'.  See the README for the full
;; command list and customization options.

;;; Code:

(require 'treesit)
(require 'compile)
(require 'ansi-color)
(require 'project)
(require 'seq)

(defgroup go-ginkgo nil
  "Run Ginkgo BDD specs from Go buffers."
  :group 'tools
  :prefix "go-ginkgo-"
  :link '(url-link :tag "Homepage" "https://github.com/jcmfernandes/go-ginkgo"))

;;;; Options

(defcustom go-ginkgo-binary "ginkgo"
  "Name or path of the ginkgo executable (resolved against variable `exec-path')."
  :type 'string)

(defcustom go-ginkgo-extra-args nil
  "Extra arguments always passed to ginkgo spec runs (e.g. build tags).
These are appended to every spec run and to `go-ginkgo-watch', but not to the
scaffolding commands `go-ginkgo-bootstrap' and `go-ginkgo-generate'."
  :type '(repeat string))

(defcustom go-ginkgo-parallel nil
  "Whether to run specs in parallel.
If nil, run serially.  If t, pass -p (Ginkgo auto-selects the worker count).
If an integer, pass --procs N to request that many workers."
  :type '(choice (const :tag "Serial" nil)
                 (const :tag "Automatic (-p)" t)
                 (integer :tag "Fixed worker count")))

(defcustom go-ginkgo-dry-run nil
  "When non-nil, pass --dry-run so ginkgo lists specs without executing them.
Toggle interactively with `go-ginkgo-toggle-dry-run'."
  :type 'boolean)

(defcustom go-ginkgo-focus-strategy 'full-path
  "How `go-ginkgo-run-spec' builds the --focus regexp for the spec at point.

`full-path' (the default) joins the descriptions of every enclosing
container, so a nested spec is targeted precisely -- ginkgo matches --focus
against a spec's full text, which is its ancestors' descriptions joined by
spaces.

`innermost' uses only the nearest enclosing description.  This matches the
historical behaviour of ginkgo-mode and is occasionally handy to re-run a
whole container by its name alone, at the cost of also matching same-named
specs elsewhere in the suite."
  :type '(choice (const :tag "Full ancestry path (precise)" full-path)
                 (const :tag "Innermost description only" innermost)))

(defcustom go-ginkgo-container-nodes
  '("Describe" "FDescribe" "PDescribe" "XDescribe"
    "Context"  "FContext"  "PContext"  "XContext"
    "When"     "FWhen"     "PWhen"     "XWhen"
    "It"       "FIt"       "PIt"       "XIt"
    "Specify"  "FSpecify"  "PSpecify"  "XSpecify"
    "DescribeTable" "FDescribeTable" "PDescribeTable" "XDescribeTable"
    "Entry"    "FEntry"    "PEntry"    "XEntry")
  "Ginkgo constructors whose first string argument is a focusable description.
Includes the F (focused) and P/X (pending) decorator variants.  Extend this if
you wrap Ginkgo's nodes in your own helpers."
  :type '(repeat string))

(defcustom go-ginkgo-buffer-name "*ginkgo*"
  "Name of the compilation buffer used for ginkgo runs."
  :type 'string)

;;;; Internal state

(defvar go-ginkgo--last-run nil
  "The last ginkgo invocation, as a cons (DIRECTORY . ARGS).
Reused by `go-ginkgo-run-last'.")

;;;; Description extraction (tree-sitter)

(defun go-ginkgo--quote-re2 (string)
  "Backslash-escape Go/RE2 regexp metacharacters in STRING.
Emacs's `regexp-quote' is unsuitable here: it leaves ( ) { } unescaped because
they are literal in Emacs regexp syntax, whereas ginkgo's --focus is a Go (RE2)
regexp where they are metacharacters."
  (replace-regexp-in-string "[].+*?(){}|^$\\[]" "\\\\\\&" string))

(defun go-ginkgo--container-call-p (node)
  "Return non-nil if NODE is a call to a Ginkgo container/spec constructor.
Membership is tested against `go-ginkgo-container-nodes'."
  (and (string= (treesit-node-type node) "call_expression")
       (when-let* ((fn (treesit-node-child-by-field-name node "function")))
         (and (string= (treesit-node-type fn) "identifier")
              (member (treesit-node-text fn t) go-ginkgo-container-nodes)
              t))))

(defun go-ginkgo--call-description (call)
  "Return the first string-literal argument of CALL, unquoted, or nil.
CALL is a tree-sitter `call_expression' node."
  (when-let* ((args (treesit-node-child-by-field-name call "arguments"))
              (str (seq-find
                    (lambda (c)
                      (member (treesit-node-type c)
                              '("interpreted_string_literal" "raw_string_literal")))
                    (treesit-node-children args))))
    ;; Drop the surrounding "double" or `raw` quotes.
    (let ((txt (treesit-node-text str t)))
      (substring txt 1 (1- (length txt))))))

(defun go-ginkgo--ensure-parser ()
  "Signal a `user-error' unless the current buffer has a tree-sitter parser."
  (unless (treesit-parser-list)
    (user-error "No tree-sitter parser here (visit the file in go-ts-mode)")))

(defun go-ginkgo--ancestry ()
  "Return the descriptions of the Ginkgo containers enclosing point.
The list is ordered outermost-first; it is empty when point is not inside any
Ginkgo node.  Requires a tree-sitter parser in the current buffer."
  (go-ginkgo--ensure-parser)
  (let ((node (treesit-node-at (point)))
        (acc '()))
    (while node
      (setq node (treesit-parent-until node #'go-ginkgo--container-call-p t))
      (when node
        (when-let* ((desc (go-ginkgo--call-description node)))
          (push desc acc))
        (setq node (treesit-node-parent node))))
    acc))

(defun go-ginkgo--focus-regexp (ancestry)
  "Build a --focus RE2 regexp from ANCESTRY, an outermost-first description list.
Honours `go-ginkgo-focus-strategy'.  Returns nil when ANCESTRY is empty."
  (when ancestry
    (pcase go-ginkgo-focus-strategy
      ('innermost (go-ginkgo--quote-re2 (car (last ancestry))))
      ;; ginkgo joins a spec's container texts with single spaces; a space is
      ;; literal in RE2, so escaping each description and joining with " " yields
      ;; a substring pattern that matches the spec's full text.
      (_ (mapconcat #'go-ginkgo--quote-re2 ancestry " ")))))

;;;; Running

(defun go-ginkgo--base-args ()
  "Return the argument list common to every spec run, from user options."
  (append
   (cond ((integerp go-ginkgo-parallel)
          (list "--procs" (number-to-string go-ginkgo-parallel)))
         (go-ginkgo-parallel (list "-p")))
   (and go-ginkgo-dry-run (list "--dry-run"))
   go-ginkgo-extra-args))

(defun go-ginkgo--project-root ()
  "Return the current project's root directory, or signal a `user-error'."
  (if-let* ((proj (project-current)))
      (project-root proj)
    (user-error "Not inside a project")))

(define-compilation-mode go-ginkgo-compilation-mode "Ginkgo"
  "Compilation mode for `go-ginkgo' spec runs.
Adds a Go-aware error pattern (so locations jump to source) and turns ginkgo's
ANSI colour escapes into real colours."
  (setq-local compilation-error-regexp-alist '(go-ginkgo))
  (setq-local compilation-error-regexp-alist-alist
              ;; A file path ending in .go, a colon, a line, and an optional
              ;; column -- covers both Gomega failure locations and stack traces.
              '((go-ginkgo
                 "\\([^][[:space:]():]+\\.go\\):\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?"
                 1 2 3)))
  (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter nil t))

(defun go-ginkgo--run (directory args)
  "Run ginkgo with ARGS in DIRECTORY through `go-ginkgo-compilation-mode'.
Each element of ARGS is one already-unquoted argument; they are shell-quoted
here.  Records the invocation in `go-ginkgo--last-run'."
  (let* ((default-directory (or directory default-directory))
         (command (mapconcat #'shell-quote-argument
                             (cons go-ginkgo-binary args) " ")))
    (setq go-ginkgo--last-run (cons default-directory args))
    (compilation-start command #'go-ginkgo-compilation-mode
                       (lambda (_) go-ginkgo-buffer-name))))

;;;; Commands

;;;###autoload
(defun go-ginkgo-run-spec ()
  "Run the Ginkgo container or spec enclosing point, via --focus.
The description (or, by default, the full ancestry of descriptions -- see
`go-ginkgo-focus-strategy') is RE2-escaped, so names containing regexp
metacharacters still match."
  (interactive)
  (let ((focus (go-ginkgo--focus-regexp (go-ginkgo--ancestry))))
    (unless focus (user-error "No Ginkgo container/spec at point"))
    (message "ginkgo --focus %s" focus)
    (go-ginkgo--run default-directory
                    (append (go-ginkgo--base-args) (list "--focus" focus)))))

;;;###autoload
(defun go-ginkgo-run-file ()
  "Run only the specs defined in the current file, via --focus-file."
  (interactive)
  (let ((file (buffer-file-name)))
    (unless file (user-error "Buffer is not visiting a file"))
    (go-ginkgo--run default-directory
                    (append (go-ginkgo--base-args)
                            (list "--focus-file" (file-name-nondirectory file))))))

;;;###autoload
(defun go-ginkgo-run-package ()
  "Run the whole Ginkgo suite in the current buffer's directory (the package)."
  (interactive)
  (go-ginkgo--run default-directory (go-ginkgo--base-args)))

;;;###autoload
(defun go-ginkgo-run-project ()
  "Run every Ginkgo suite in the current project, recursively (via -r)."
  (interactive)
  (go-ginkgo--run (go-ginkgo--project-root)
                  (append (go-ginkgo--base-args) (list "-r"))))

;;;###autoload
(defun go-ginkgo-run-labels (filter)
  "Run specs in the current package matching the label FILTER expression.
FILTER is a Ginkgo label-filter query such as \"smoke && !slow\"; it is passed
verbatim to --label-filter.  See the Ginkgo docs on Spec Labels."
  (interactive
   (list (read-string "Label filter (e.g. \"smoke && !slow\"): ")))
  (go-ginkgo--run default-directory
                  (append (go-ginkgo--base-args)
                          (list "--label-filter" filter))))

;;;###autoload
(defun go-ginkgo-run-last ()
  "Re-run the most recent ginkgo invocation, in the directory it ran in."
  (interactive)
  (unless go-ginkgo--last-run (user-error "No previous ginkgo run"))
  (go-ginkgo--run (car go-ginkgo--last-run) (cdr go-ginkgo--last-run)))

;;;###autoload
(defun go-ginkgo-watch ()
  "Watch the current package and re-run its specs on change (ginkgo watch).
This is a long-running process; stop it with \\[kill-compilation] in the
ginkgo buffer."
  (interactive)
  (go-ginkgo--run default-directory (cons "watch" go-ginkgo-extra-args)))

;;;###autoload
(defun go-ginkgo-bootstrap ()
  "Scaffold a suite bootstrap file in the current directory (ginkgo bootstrap)."
  (interactive)
  (go-ginkgo--run default-directory (list "bootstrap")))

;;;###autoload
(defun go-ginkgo-generate ()
  "Scaffold a spec file for the current file (ginkgo generate)."
  (interactive)
  (go-ginkgo--run default-directory
                  (list "generate" (file-name-base (or (buffer-file-name) "")))))

(defun go-ginkgo-toggle-dry-run ()
  "Toggle `go-ginkgo-dry-run' and report the new state."
  (interactive)
  (setq go-ginkgo-dry-run (not go-ginkgo-dry-run))
  (message "go-ginkgo dry-run %s" (if go-ginkgo-dry-run "enabled" "disabled")))

;;;; Minor mode and keymap

(defvar-keymap go-ginkgo-command-map
  :doc "Keymap for `go-ginkgo' commands; bind it under a prefix of your choice."
  "s" #'go-ginkgo-run-spec
  "f" #'go-ginkgo-run-file
  "p" #'go-ginkgo-run-package
  "j" #'go-ginkgo-run-project
  "L" #'go-ginkgo-run-labels
  "l" #'go-ginkgo-run-last
  "w" #'go-ginkgo-watch
  "b" #'go-ginkgo-bootstrap
  "n" #'go-ginkgo-generate
  "d" #'go-ginkgo-toggle-dry-run)
;; Make the keymap usable as a prefix command in its own right (so it can be
;; bound by symbol and shows up in `describe-key'/which-key).
(fset 'go-ginkgo-command-map go-ginkgo-command-map)

(defvar go-ginkgo-mode-map (make-sparse-keymap)
  "Keymap for `go-ginkgo-mode'.
Populated under `go-ginkgo-keymap-prefix' when that option is set.")

(defcustom go-ginkgo-keymap-prefix nil
  "Prefix key for `go-ginkgo-command-map' inside `go-ginkgo-mode'.
A key-sequence string understood by `keymap-set', or nil to bind nothing -- in
which case bind `go-ginkgo-command-map' yourself.  See the Commentary for an
example."
  :type '(choice (const :tag "None" nil) (string :tag "Key sequence"))
  :set (lambda (symbol value)
         (when (and (boundp symbol) (symbol-value symbol))
           (keymap-unset go-ginkgo-mode-map (symbol-value symbol) t))
         (set-default symbol value)
         (when value
           (keymap-set go-ginkgo-mode-map value 'go-ginkgo-command-map))))

;;;###autoload
(define-minor-mode go-ginkgo-mode
  "Minor mode to run Ginkgo specs from the current Go buffer.

When `go-ginkgo-keymap-prefix' is set, the commands are reachable under that
prefix via `go-ginkgo-command-map'.

\\{go-ginkgo-mode-map}"
  :lighter " Ginkgo"
  :keymap go-ginkgo-mode-map)

(provide 'go-ginkgo)
;;; go-ginkgo.el ends here
