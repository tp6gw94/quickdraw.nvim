TESTS_INIT=tests/minimal_init.lua
TESTS_DIR=tests/

.PHONY: test

test:
	@nvim \
		--headless \
		--noplugin \
		-u ${TESTS_INIT} \
		-c "PlenaryBustedDirectory ${TESTS_DIR} { minimal_init = '${TESTS_INIT}' }"
	@node --test tests/web/save_status_test.mjs tests/web/bindings_test.mjs tests/web/editor_test.mjs tests/web/heads_test.mjs
