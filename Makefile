# Developer tasks for org-auto-scheduler.
#
#   make test                       run every suite
#   make test SELECTOR=oas-suite-13 run suites whose name matches
#   make compile                    byte-compile (warnings listed, not fatal yet)
#   make lint                       checkdoc
#   make bench                      time a preview run on a generated 500-task file
#
# EMACS must be a real Emacs binary (not an emacsclient wrapper), e.g.
#   make test EMACS=/snap/bin/emacs

EMACS ?= emacs

# log4e is the only hard dependency.  Point LOG4E_DIR at it, or let it be found
# in a package.el directory.
LOG4E_DIR ?= $(lastword $(sort $(wildcard $(HOME)/.emacs.d/elpa/log4e-* $(HOME)/.emacs.d/elpa/*/develop/log4e-*)))
EXTRA_LOAD_PATH ?=

SRC = org-auto-scheduler-daemon.el org-auto-scheduler-analytics.el \
      org-auto-scheduler-review.el org-auto-scheduler.el

LOAD_PATH = -L . $(if $(LOG4E_DIR),-L $(LOG4E_DIR)) $(addprefix -L ,$(EXTRA_LOAD_PATH))
BATCH = $(EMACS) -Q --batch $(LOAD_PATH)

.PHONY: test compile lint bench clean

test:
	$(BATCH) -l test/oas-suites-test.el -f oas-test-run-batch

compile: clean
	$(BATCH) -f batch-byte-compile $(SRC)

lint:
	$(BATCH) --eval "(progn (require 'checkdoc) (dolist (f '($(patsubst %,\"%\",$(SRC)))) (checkdoc-file f)))"

bench:
	$(BATCH) -l test/bench.el -f oas-bench-run

clean:
	rm -f *.elc test/*.elc
