PYTHON ?= python3
.PHONY: all build check clean
all: build
build:
	@if [ "$(BUILD_DEPS)" != "0" ] && [ "server" != "common" ]; then $(MAKE) -C .. build-common; fi
	$(PYTHON) ../tools/build.py component:build:server
check:
	$(PYTHON) ../tools/check/repository.py component --component=server
clean:
	$(PYTHON) ../tools/build.py clean:component:server
