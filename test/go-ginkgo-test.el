;;; go-ginkgo-test.el --- Tests for go-ginkgo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 João Moreira Fernandes

;; This file is not part of GNU Emacs.

;;; Commentary:
;;
;; ERT suite for go-ginkgo.  Two layers:
;;
;;   - Pure-function and command-assembly tests run everywhere.  Runs are
;;     verified by stubbing `compilation-start' (via `go-ginkgo-test--capture'),
;;     so no ginkgo binary or network is needed.
;;   - Tree-sitter tests (description finding, ancestry, focus) require the Go
;;     grammar.  They `skip-unless' it is available, so the suite stays green on
;;     a machine without it.  In CI run `make grammar' first to install it.
;;
;; Run with:  make test   (or: emacs -Q --batch -L . -l test/go-ginkgo-test.el
;;                          -f ert-run-tests-batch-and-exit)

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'go-ginkgo)

;;;; Helpers

(defmacro go-ginkgo-test--capture (&rest body)
  "Evaluate BODY with `compilation-start' stubbed, returning the captured call.
The result is a plist (:command STRING :dir DIRECTORY :mode SYMBOL).  BODY runs
in a throwaway buffer whose `default-directory' is a stable, fake path so
directory assertions are deterministic."
  (declare (indent 0) (debug t))
  `(let (captured)
     (cl-letf (((symbol-function 'compilation-start)
                (lambda (command &optional mode &rest _)
                  (setq captured (list :command command
                                       :dir default-directory
                                       :mode mode))
                  ;; Return a live buffer the way the real function does.
                  (get-buffer-create "*ginkgo-test*"))))
       (with-temp-buffer
         (setq default-directory "/fake/pkg/")
         ,@body))
     captured))

(defmacro go-ginkgo-test--with-go (code marker &rest body)
  "Run BODY in a `go-ts-mode' buffer holding CODE, point moved just after MARKER.
Skips the test unless the Go tree-sitter grammar is available.  MARKER is a
substring searched from the start of the buffer; point lands at its end."
  (declare (indent 2) (debug t))
  `(progn
     (skip-unless (treesit-language-available-p 'go))
     (require 'go-ts-mode)
     (with-temp-buffer
       (insert ,code)
       (go-ts-mode)
       (goto-char (point-min))
       (search-forward ,marker)
       ,@body)))

(defconst go-ginkgo-test--spec
  "package widget_test

import (
\t. \"github.com/onsi/ginkgo/v2\"
\t. \"github.com/onsi/gomega\"
)

var _ = Describe(\"Widget\", func() {
\tContext(\"when (key) is missing\", func() {
\t\tIt(\"returns an error\", func() {
\t\t\tExpect(true).To(BeTrue()) // INNERMOST
\t\t})
\t})

\tWhen(`raw container`, func() {
\t\tFIt(\"is focused\", func() {
\t\t\tExpect(1).To(Equal(1)) // FOCUSED
\t\t})
\t})

\tcomment := \"It(\\\"not a real spec\\\")\" // DECOY
\t_ = comment
})
"
  "A representative Ginkgo v2 spec used across the tree-sitter tests.")

;;;; RE2 escaping (pure)

(ert-deftest go-ginkgo-test-quote-re2-escapes-metacharacters ()
  (should (equal (go-ginkgo--quote-re2 "handles (key) lookups")
                 "handles \\(key\\) lookups"))
  (should (equal (go-ginkgo--quote-re2 "a.b*c+d?e")
                 "a\\.b\\*c\\+d\\?e"))
  (should (equal (go-ginkgo--quote-re2 "{x}[y]|^$")
                 "\\{x\\}\\[y\\]\\|\\^\\$"))
  (should (equal (go-ginkgo--quote-re2 "back\\slash")
                 "back\\\\slash")))

(ert-deftest go-ginkgo-test-quote-re2-leaves-plain-text-untouched ()
  (should (equal (go-ginkgo--quote-re2 "a plain description")
                 "a plain description"))
  (should (equal (go-ginkgo--quote-re2 "") "")))

;;;; Focus-regexp building (pure, no tree-sitter)

(ert-deftest go-ginkgo-test-focus-regexp-full-path ()
  (let ((go-ginkgo-focus-strategy 'full-path))
    (should (equal (go-ginkgo--focus-regexp '("Widget" "when (key)" "works"))
                   "Widget when \\(key\\) works"))))

(ert-deftest go-ginkgo-test-focus-regexp-innermost ()
  (let ((go-ginkgo-focus-strategy 'innermost))
    (should (equal (go-ginkgo--focus-regexp '("Widget" "Context" "works"))
                   "works"))))

(ert-deftest go-ginkgo-test-focus-regexp-empty-is-nil ()
  (should (null (go-ginkgo--focus-regexp '()))))

;;;; Base-args assembly (option-driven)

(ert-deftest go-ginkgo-test-base-args-serial-default ()
  (let ((go-ginkgo-parallel nil)
        (go-ginkgo-dry-run nil)
        (go-ginkgo-extra-args nil))
    (should (null (go-ginkgo--base-args)))))

(ert-deftest go-ginkgo-test-base-args-parallel-auto ()
  (let ((go-ginkgo-parallel t)
        (go-ginkgo-dry-run nil)
        (go-ginkgo-extra-args nil))
    (should (equal (go-ginkgo--base-args) '("-p")))))

(ert-deftest go-ginkgo-test-base-args-parallel-fixed ()
  (let ((go-ginkgo-parallel 4)
        (go-ginkgo-dry-run nil)
        (go-ginkgo-extra-args nil))
    (should (equal (go-ginkgo--base-args) '("--procs" "4")))))

(ert-deftest go-ginkgo-test-base-args-dry-run-and-extra ()
  (let ((go-ginkgo-parallel nil)
        (go-ginkgo-dry-run t)
        (go-ginkgo-extra-args '("--tags" "integration")))
    (should (equal (go-ginkgo--base-args)
                   '("--dry-run" "--tags" "integration")))))

;;;; Command assembly (stubbed compilation-start)

(ert-deftest go-ginkgo-test-run-package-command ()
  (let ((go-ginkgo-parallel nil) (go-ginkgo-dry-run nil)
        (go-ginkgo-extra-args nil) (go-ginkgo-binary "ginkgo"))
    (let ((cap (go-ginkgo-test--capture (go-ginkgo-run-package))))
      (should (equal (plist-get cap :command) "ginkgo"))
      (should (equal (plist-get cap :dir) "/fake/pkg/"))
      (should (eq (plist-get cap :mode) 'go-ginkgo-compilation-mode)))))

(ert-deftest go-ginkgo-test-run-file-uses-focus-file ()
  (let ((go-ginkgo-parallel nil) (go-ginkgo-dry-run nil)
        (go-ginkgo-extra-args nil) (go-ginkgo-binary "ginkgo"))
    (let ((cap (go-ginkgo-test--capture
                 (set-visited-file-name "/fake/pkg/widget_test.go" t)
                 (go-ginkgo-run-file))))
      (should (equal (plist-get cap :command)
                     "ginkgo --focus-file widget_test.go")))))

(ert-deftest go-ginkgo-test-run-file-without-file-errors ()
  (with-temp-buffer
    (should-error (go-ginkgo-run-file) :type 'user-error)))

(ert-deftest go-ginkgo-test-run-labels-quotes-expression ()
  (let ((go-ginkgo-parallel nil) (go-ginkgo-dry-run nil)
        (go-ginkgo-extra-args nil) (go-ginkgo-binary "ginkgo"))
    (let ((cap (go-ginkgo-test--capture
                 (go-ginkgo-run-labels "smoke && !slow"))))
      ;; The whole expression must reach ginkgo as a single shell argument.
      (should (equal (plist-get cap :command)
                     "ginkgo --label-filter smoke\\ \\&\\&\\ \\!slow")))))

(ert-deftest go-ginkgo-test-run-package-honours-parallel-and-tags ()
  (let ((go-ginkgo-parallel 2) (go-ginkgo-dry-run t)
        (go-ginkgo-extra-args '("--tags" "e2e")) (go-ginkgo-binary "ginkgo"))
    (let ((cap (go-ginkgo-test--capture (go-ginkgo-run-package))))
      (should (equal (plist-get cap :command)
                     "ginkgo --procs 2 --dry-run --tags e2e")))))

(ert-deftest go-ginkgo-test-watch-omits-base-args ()
  (let ((go-ginkgo-parallel t) (go-ginkgo-dry-run t)
        (go-ginkgo-extra-args '("--tags" "e2e")) (go-ginkgo-binary "ginkgo"))
    (let ((cap (go-ginkgo-test--capture (go-ginkgo-watch))))
      ;; watch takes extra-args (build tags) but not parallel/dry-run.
      (should (equal (plist-get cap :command) "ginkgo watch --tags e2e")))))

(ert-deftest go-ginkgo-test-run-last-replays-invocation ()
  (let ((go-ginkgo--last-run nil) (go-ginkgo-binary "ginkgo"))
    (should-error (go-ginkgo-run-last) :type 'user-error)
    (go-ginkgo-test--capture (go-ginkgo--run "/somewhere/" '("--focus" "X")))
    (let ((cap (go-ginkgo-test--capture (go-ginkgo-run-last))))
      (should (equal (plist-get cap :command) "ginkgo --focus X"))
      (should (equal (plist-get cap :dir) "/somewhere/")))))

(ert-deftest go-ginkgo-test-toggle-dry-run ()
  (let ((go-ginkgo-dry-run nil))
    (go-ginkgo-toggle-dry-run)
    (should go-ginkgo-dry-run)
    (go-ginkgo-toggle-dry-run)
    (should-not go-ginkgo-dry-run)))

;;;; Keymap / prefix option

(ert-deftest go-ginkgo-test-command-map-bindings ()
  (should (eq (keymap-lookup go-ginkgo-command-map "s") #'go-ginkgo-run-spec))
  (should (eq (keymap-lookup go-ginkgo-command-map "p") #'go-ginkgo-run-package)))

(ert-deftest go-ginkgo-test-keymap-prefix-binds-and-rebinds ()
  (let ((go-ginkgo-mode-map (make-sparse-keymap))
        (go-ginkgo-keymap-prefix nil))
    ;; Setting the option through customize binds the command map under it.
    (customize-set-variable 'go-ginkgo-keymap-prefix "C-c G")
    (should (eq (keymap-lookup go-ginkgo-mode-map "C-c G")
                'go-ginkgo-command-map))
    ;; Changing it moves the binding and clears the old prefix.
    (customize-set-variable 'go-ginkgo-keymap-prefix "C-c j")
    (should (null (keymap-lookup go-ginkgo-mode-map "C-c G")))
    (should (eq (keymap-lookup go-ginkgo-mode-map "C-c j")
                'go-ginkgo-command-map))))

;;;; Parser guard

(ert-deftest go-ginkgo-test-ensure-parser-requires-go-parser ()
  "`go-ginkgo--ensure-parser' rejects a buffer whose only parser isn't Go."
  ;; Stand in for a buffer that has some tree-sitter parser, just not a Go one
  ;; (e.g. a non-Go major mode).  The stub honours the LANGUAGE filter the way
  ;; the real `treesit-parser-list' does, so a Go query comes back empty.
  (cl-letf (((symbol-function 'treesit-parser-list)
             (lambda (&optional _buffer language &rest _)
               (unless (eq language 'go) (list 'fake-parser)))))
    (should-error (go-ginkgo--ensure-parser) :type 'user-error)))

(ert-deftest go-ginkgo-test-ensure-parser-without-treesit-support ()
  "`go-ginkgo--ensure-parser' errors cleanly when Emacs lacks tree-sitter.
On such a build `treesit-available-p' is nil and the parser primitives are
unusable; the guard must short-circuit to a `user-error' before calling them."
  (cl-letf (((symbol-function 'treesit-available-p) (lambda () nil))
            ((symbol-function 'treesit-parser-list)
             (lambda (&rest _) (error "tree-sitter library not available"))))
    (should-error (go-ginkgo--ensure-parser) :type 'user-error)))

;;;; Tree-sitter: description, ancestry, focus

(ert-deftest go-ginkgo-test-ts-innermost-description ()
  (go-ginkgo-test--with-go go-ginkgo-test--spec "INNERMOST"
    (should (equal (go-ginkgo--ancestry)
                   '("Widget" "when (key) is missing" "returns an error")))))

(ert-deftest go-ginkgo-test-ts-focus-full-path-is-escaped ()
  (go-ginkgo-test--with-go go-ginkgo-test--spec "INNERMOST"
    (let ((go-ginkgo-focus-strategy 'full-path))
      (should (equal (go-ginkgo--focus-regexp (go-ginkgo--ancestry))
                     "Widget when \\(key\\) is missing returns an error")))))

(ert-deftest go-ginkgo-test-ts-focus-innermost-strategy ()
  (go-ginkgo-test--with-go go-ginkgo-test--spec "INNERMOST"
    (let ((go-ginkgo-focus-strategy 'innermost))
      (should (equal (go-ginkgo--focus-regexp (go-ginkgo--ancestry))
                     "returns an error")))))

(ert-deftest go-ginkgo-test-ts-decorator-and-raw-string ()
  (go-ginkgo-test--with-go go-ginkgo-test--spec "FOCUSED"
    ;; FIt (a decorator variant) is recognised, and a raw-string container
    ;; (`backticks`) is unquoted correctly.
    (should (equal (go-ginkgo--ancestry)
                   '("Widget" "raw container" "is focused")))))

(ert-deftest go-ginkgo-test-ts-ignores-text-in-comments ()
  (go-ginkgo-test--with-go go-ginkgo-test--spec "DECOY"
    ;; The literal "It(...)" inside a comment/string must not be treated as a
    ;; spec; only the enclosing real Describe should be found.
    (should (equal (go-ginkgo--ancestry) '("Widget")))))

(ert-deftest go-ginkgo-test-ts-outside-any-spec-is-empty ()
  (go-ginkgo-test--with-go go-ginkgo-test--spec "package"
    (should (null (go-ginkgo--ancestry)))))

(ert-deftest go-ginkgo-test-ts-run-spec-builds-focus-command ()
  (go-ginkgo-test--with-go go-ginkgo-test--spec "INNERMOST"
    (let ((go-ginkgo-parallel nil) (go-ginkgo-dry-run nil)
          (go-ginkgo-extra-args nil) (go-ginkgo-binary "ginkgo")
          (go-ginkgo-focus-strategy 'full-path)
          captured)
      (cl-letf (((symbol-function 'compilation-start)
                 (lambda (command &rest _) (setq captured command)
                   (get-buffer-create "*ginkgo-test*"))))
        (go-ginkgo-run-spec))
      ;; The focus is the escaped full ancestry, passed as one shell argument.
      (let ((focus (go-ginkgo--focus-regexp
                    '("Widget" "when (key) is missing" "returns an error"))))
        (should (equal captured
                       (concat "ginkgo --focus " (shell-quote-argument focus))))))))

(provide 'go-ginkgo-test)
;;; go-ginkgo-test.el ends here
