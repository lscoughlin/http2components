PYTHON ?= python3
.PHONY: all build check clean build-readers
all: build
build:
	@if [ "$(BUILD_DEPS)" != "0" ] && [ "client" != "common" ]; then $(MAKE) -C .. build-common; fi
	$(PYTHON) ../tools/build.py component:build:client
check:
	$(PYTHON) ../tools/check/repository.py component --component=client
clean:
	$(PYTHON) ../tools/build.py clean:component:client
build-readers:
	@if [ "$(BUILD_DEPS)" != "0" ]; then $(MAKE) -C .. build-client; fi
	$(PYTHON) ../tools/build.py component:build:readers
