PYTHON ?= python3
DRIVER = $(PYTHON) tools/build.py

.PHONY: all setup-deps setup-harness build build-common build-client build-server build-readers \
        test test-common test-client test-server test-integration test-api \
        packages-check source-check docs-check version-check examples \
        validate-fast validate clean

all: build

setup-deps:
	$(DRIVER) setup-deps

setup-harness:
	$(DRIVER) setup-harness

build:
	$(DRIVER) build

build-common:
	$(DRIVER) build-common

build-client:
	$(DRIVER) build-client

build-server:
	$(DRIVER) build-server

build-readers:
	$(DRIVER) build-readers

test:
	$(DRIVER) test

test-common:
	$(DRIVER) test-common

test-client:
	$(DRIVER) test-client

test-server:
	$(DRIVER) test-server

test-integration:
	$(DRIVER) test-integration

test-api:
	$(DRIVER) test-api

packages-check:
	$(DRIVER) packages-check

source-check:
	$(DRIVER) source-check

docs-check:
	$(DRIVER) docs-check

version-check:
	$(DRIVER) version-check

examples:
	$(DRIVER) examples

validate-fast:
	$(DRIVER) validate-fast

validate:
	$(DRIVER) validate

define CLIENT_GATE
.PHONY: validate-client-$(1)
validate-client-$(1):
	$(DRIVER) validate:client:$(2)
endef
$(eval $(call CLIENT_GATE,sanity,sanity))
$(eval $(call CLIENT_GATE,interop,interop))
$(eval $(call CLIENT_GATE,harness,harness))
$(eval $(call CLIENT_GATE,sse,sse))
$(eval $(call CLIENT_GATE,proxy,proxy))
$(eval $(call CLIENT_GATE,proxy-real,proxy:real))
$(eval $(call CLIENT_GATE,websocket,websocket))
$(eval $(call CLIENT_GATE,websocket-autobahn,websocket:autobahn))
$(eval $(call CLIENT_GATE,cleartext,cleartext))
$(eval $(call CLIENT_GATE,mtls,mtls))
$(eval $(call CLIENT_GATE,mtls-real,mtls-real))

define SERVER_GATE
.PHONY: validate-server-$(1)
validate-server-$(1):
	$(DRIVER) validate:server:$(2)
endef
$(eval $(call SERVER_GATE,conformance,conformance))
$(eval $(call SERVER_GATE,fast,fast))
$(eval $(call SERVER_GATE,tls-live,tls-live))
$(eval $(call SERVER_GATE,mtls-live,mtls-live))
$(eval $(call SERVER_GATE,websocket,websocket))
$(eval $(call SERVER_GATE,websocket-h2,websocket:h2))
$(eval $(call SERVER_GATE,sse,sse))
$(eval $(call SERVER_GATE,abuse,abuse))

clean:
	$(DRIVER) clean
