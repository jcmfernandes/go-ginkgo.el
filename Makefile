# go-ginkgo -- developer Makefile
#
# Common targets:
#   make compile   byte-compile (warnings are errors)
#   make test      run the ERT suite
#   make checkdoc  documentation/style lint
#   make grammar   install the Go tree-sitter grammar (needed for the
#                  tree-sitter tests; requires git and a C compiler)
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

# Allow CI / local runs to point at an existing grammar directory, e.g.
#   make test TREESIT_EXTRA=/path/to/tree-sitter
TREESIT_EXTRA ?=
EXTRA_LOAD := $(if $(TREESIT_EXTRA),--eval "(add-to-list 'treesit-extra-load-path \"$(TREESIT_EXTRA)\")",)

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
	    (treesit-install-language-grammar 'go))"

clean:
	rm -f $(SRC:.el=.elc) test/*.elc
