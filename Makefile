EMACS ?= emacs
PYTHON ?= python3

.PHONY: test test-elisp test-python compile clean

test: test-elisp test-python

test-elisp:
	$(EMACS) -Q --batch -L . -L tests \
		-l tests/teams4e-tests.el -f ert-run-tests-batch-and-exit

test-python:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile \
		teams4e-config.el teams4e-ui.el teams4e-advanced.el \
		teams4e-evil.el teams4e.el

clean:
	find . -name '*.elc' -delete
	find . -name '*.pyc' -delete
	find . -type d -name '__pycache__' -empty -delete
