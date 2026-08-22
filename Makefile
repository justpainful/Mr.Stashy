SHELL := /bin/bash

SCHEME ?= MrStashy
DESTINATION ?=

.PHONY: bootstrap generate assets lint build test ui-test ipa release-check

bootstrap:
	bash scripts/bootstrap.sh

generate: bootstrap

assets:
	bash scripts/verify_assets.sh

lint:
	bash scripts/lint.sh

build: generate assets
	bash scripts/build.sh "$(SCHEME)" "$(DESTINATION)"

test: generate assets
	bash scripts/test.sh "$(SCHEME)" "$(DESTINATION)"

ui-test: generate assets
	bash scripts/ui_test.sh "$(SCHEME)" "$(DESTINATION)"

ipa: generate assets
	bash scripts/package_ipa.sh "$(SCHEME)"

release-check: assets test ui-test ipa
	RELEASE_GUARD_SKIP_TESTS=1 bash scripts/release_guard.sh
