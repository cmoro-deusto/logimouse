# Run every test: the command line tool (pytest through uv), the plugin's model
# (lua 5.4), and the static plugin check (python3 3.11+, uses the network for the
# API definitions and skips that part without it).
test:
	uv run pytest -q
	cd logimouse && lua tests/shared_test.lua && python3 tests/plugin_check.py

.PHONY: test
