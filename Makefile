# Jiberish SPEC-01 UI: development commands.
WOW ?= /Applications/World of Warcraft
CLIENTS ?= _retail_ _forever_

.PHONY: check lint test hooks install

check:        ## every Lua check, then the unit tests
	python3 tools/check.py

lint:         ## Lua checks only (pass FILES=... to limit)
	python3 tools/check.py $(or $(FILES),$(shell find JiberishSpec01UI -name '*.lua'))

test:         ## unit tests only
	python3 -m unittest discover -s tests -q

hooks:        ## run the Lua checks on every commit
	git config core.hooksPath tools/hooks

install: check ## copy the addon into each WoW client (checks first)
	@for client in $(CLIENTS); do \
		dest="$(WOW)/$$client/Interface/AddOns/JiberishSpec01UI"; \
		[ -d "$(WOW)/$$client" ] || continue; \
		rsync -a --delete JiberishSpec01UI/ "$$dest/" && echo "installed: $$client"; \
	done
