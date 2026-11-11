PYTHON ?= python3
.PHONY: all build check clean
all: build
build:
	@if [ "$(BUILD_DEPS)" != "0" ] && [ "common" != "common" ]; then $(MAKE) -C .. build-common; fi
	$(PYTHON) ../tools/build.py component:build:common
check:
	$(PYTHON) ../tools/check/repository.py component --component=common
clean:
	$(PYTHON) ../tools/build.py clean:component:common
