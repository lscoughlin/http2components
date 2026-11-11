PYTHON ?= python3
.PHONY: all build check clean
all: build
build:
	@if [ "$(BUILD_DEPS)" != "0" ]; then $(MAKE) -C ../.. build-common; fi
	$(PYTHON) ../../tools/build.py build:openssl
check:
	$(PYTHON) ../../tools/check/repository.py component --component=openssl
clean:
	$(PYTHON) ../../tools/build.py clean:component:openssl
