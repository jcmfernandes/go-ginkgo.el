# go-ginkgo -- developer Makefile
#
# Common targets:
#   make compile   byte-compile (warnings are errors)
#   make test      run the ERT suite
#   make checkdoc  documentation/style lint
#   make grammar   install the Go tree-sitter grammar into a project-local
#                  $(EMACS_HOME)/tree-sitter (needed for the tree-sitter
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

# Keep the Go grammar out of your real ~/.emacs.d by installing it under a
# project-local Emacs home: `make grammar' points user-emacs-directory at
# EMACS_HOME, so treesit installs into $(EMACS_HOME)/tree-sitter, and `make
# test' loads it from there.  We redirect via user-emacs-directory rather than
# treesit-install-language-grammar's OUT-DIR argument because OUT-DIR only
# exists on Emacs 30+ (29.x has it as a single-argument function).
# Override EMACS_HOME to install elsewhere, e.g. EMACS_HOME=~/.emacs.d.
EMACS_HOME  ?= $(CURDIR)/.emacs.d
GRAMMAR_DIR := $(EMACS_HOME)/tree-sitter

# Pin the grammar to an ABI-14 tag so it loads on Emacs 29 as well as 30/31.
# tree-sitter-go master is ABI 15, which Emacs 29 (max ABI 14) cannot load, so
# its tree-sitter tests would silently skip.  v0.23.4 is the newest ABI-14 tag.
GRAMMAR_REV ?= v0.23.4

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
	    (setq user-emacs-directory \"$(EMACS_HOME)/\") \
	    (setq treesit-language-source-alist \
	      '((go \"https://github.com/tree-sitter/tree-sitter-go\" \"$(GRAMMAR_REV)\"))) \
	    (treesit-install-language-grammar 'go))"

clean:
	rm -f $(SRC:.el=.elc) test/*.elc
