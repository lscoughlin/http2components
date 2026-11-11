PYTHON ?= python3
.PHONY: all build check clean
all: build
build:
	@if [ "$(BUILD_DEPS)" != "0" ]; then $(MAKE) -C ../.. build-common; fi
	$(PYTHON) ../../tools/build.py build:tlslib
check:
	$(PYTHON) ../../tools/check/repository.py component --component=tlslib
clean:
	$(PYTHON) ../../tools/build.py clean:component:tlslib
