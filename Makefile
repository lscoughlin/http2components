PYTHON ?= python3
.PHONY: all setup-deps setup-harness build build-common build-client build-server build-readers \
        build-openssl build-tlslib test test-common test-client test-server test-integration test-api \
        test-tls-contract test-tls-openssl test-tls-tlslib test-tls-integration \
        packages-check source-check docs-check version-check examples \
        validate-fast validate clean

all: build
setup-deps:
	$(PYTHON) tools/build.py setup-deps
setup-harness:
	$(PYTHON) tools/build.py setup-harness

build: build-common build-client build-server build-openssl build-tlslib
build-common:
	$(MAKE) -C common build BUILD_DEPS=0
build-client: build-common
	$(MAKE) -C client build BUILD_DEPS=0
build-server: build-common
	$(MAKE) -C server build BUILD_DEPS=0
build-readers: build-common build-client
	$(MAKE) -C client build-readers BUILD_DEPS=0
build-openssl: build-common
	$(MAKE) -C tls/openssl build BUILD_DEPS=0
build-tlslib: build-common
	$(MAKE) -C tls/tlslib build BUILD_DEPS=0

test-tls-contract test-tls-openssl test-tls-tlslib test-tls-integration:
	$(PYTHON) tools/build.py $(subst -,:,$@)

test test-common test-client test-server test-integration test-api packages-check source-check docs-check version-check examples validate-fast validate:
	$(PYTHON) tools/build.py $(subst -,:,$@)

clean:
	$(PYTHON) tools/build.py clean

# Existing validation aliases remain available. These targets are explicit;
# they are not dependencies of the ordinary build.
define CLIENT_GATE
.PHONY: validate-client-$(1)
validate-client-$(1):
	$(PYTHON) tools/build.py validate:client:$(2)
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
$(eval $(call CLIENT_GATE,mtls-real,mtls:real))

define SERVER_GATE
.PHONY: validate-server-$(1)
validate-server-$(1):
	$(PYTHON) tools/build.py validate:server:$(2)
endef
$(eval $(call SERVER_GATE,conformance,conformance))
$(eval $(call SERVER_GATE,fast,fast))
$(eval $(call SERVER_GATE,tls-live,tls:live))
$(eval $(call SERVER_GATE,mtls-live,mtls:live))
$(eval $(call SERVER_GATE,websocket,websocket))
$(eval $(call SERVER_GATE,websocket-h2,websocket:h2))
$(eval $(call SERVER_GATE,sse,sse))
$(eval $(call SERVER_GATE,abuse,abuse))
