.PHONY: syntax lint test verify

syntax:
	bash -n bin/*.sh lib/*.sh tests/run_tests.sh

lint:
	shellcheck bin/*.sh lib/*.sh tests/run_tests.sh

test:
	./tests/run_tests.sh

verify: syntax lint test
