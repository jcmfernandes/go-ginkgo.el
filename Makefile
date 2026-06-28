# go-ginkgo -- developer Makefile
#
# Common targets:
#   make compile   byte-compile (warnings are errors)
#   make test      run the ERT suite
#   make checkdoc  documentation/style lint
#   make grammar   install the Go tree-sitter grammar into GRAMMAR_DIR
#                  (project-local by default; needed for the tree-sitter
#                  tests; requires git and a C compiler)
#   make clean     remove byte-compiled output
#   make all       compile + checkdoc + test (the CI gate)

# Sensible defaults (see https://tech.davis-hansson.com/p/make/).
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

EMACS ?= emacs
SRC    = go-ginkgo.el
TEST   = test/go-ginkgo-test.el

# Where `make grammar' installs the Go grammar, and where `make test' looks for
# it.  Defaults to a project-local directory so it neither writes to nor depends
# on your ~/.emacs.d.  Override to install/use it elsewhere, e.g.
#   make grammar GRAMMAR_DIR=~/.emacs.d/tree-sitter
GRAMMAR_DIR ?= $(CURDIR)/.tree-sitter

# Additionally point `make test' at a grammar you installed elsewhere, e.g.
#   make test TREESIT_EXTRA=/path/to/tree-sitter
TREESIT_EXTRA ?=
EXTRA_LOAD := --eval "(add-to-list 'treesit-extra-load-path \"$(GRAMMAR_DIR)\")" \
              $(if $(TREESIT_EXTRA),--eval "(add-to-list 'treesit-extra-load-path \"$(TREESIT_EXTRA)\")",)

.PHONY: all compile test checkdoc grammar clean

all: compile checkdoc test

compile:
	$(EMACS) -Q --batch -L . \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRC)

test:
	$(EMACS) -Q --batch -L . $(EXTRA_LOAD) \
	  -l $(TEST) -f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch \
	  --eval "(checkdoc-file \"$(SRC)\")"

grammar:
	$(EMACS) -Q --batch \
	  --eval "(progn \
	    (require 'treesit) \
	    (setq treesit-language-source-alist \
	      '((go \"https://github.com/tree-sitter/tree-sitter-go\"))) \
	    (treesit-install-language-grammar 'go \"$(GRAMMAR_DIR)\"))"

clean:
	rm -f $(SRC:.el=.elc) test/*.elc
