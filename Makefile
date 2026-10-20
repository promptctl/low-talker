# `make app` is the one command that turns project.yml into a launchable app bundle.
SHELL := /bin/bash
DERIVED_DATA := DerivedData
# The one configuration project.yml defines: every bundle, the development build included,
# is built as a release. Passed to xcodebuild and spelled into the products path below.
CONFIGURATION := Release
PRODUCTS := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)
# The certificate every bundle is signed with, when it is not project.yml's development
# identity. Empty, xcodebuild signs with the identity project.yml sets; scripts/sign-release
# names the Developer ID certificate here, and that name, the store the bundle carries and
# a DerivedData of its own are all it changes. [LAW:one-type-per-behavior] A release and a
# development build are one recipe run with two values, never two recipes.
SIGNING_IDENTITY :=
# Which of the two builds: `offline`, whose app holds exactly the sandbox's entitlements and
# so cannot reach the network, or `network`, whose app may also accept connections, for the
# server it hosts. That one entitlement is all that separates them, and they are one product
# under one identifier, so installing either replaces the other; the package's name is how a
# person tells them apart, and scripts/make-pkg reads it off the app it packs.
# [LAW:one-type-per-behavior] Two builds are one recipe run with two values.
# VARIANTS is every variant, in the order scripts/sign-release builds and notarizes them.
# [LAW:one-source-of-truth]
VARIANTS := offline network
VARIANT := offline
ACCEPTS_CONNECTIONS_offline := NO
ACCEPTS_CONNECTIONS_network := YES
ACCEPTS_CONNECTIONS := $(or $(and $(filter $(VARIANT),$(VARIANTS)),$(ACCEPTS_CONNECTIONS_$(VARIANT))),$(error VARIANT is '$(VARIANT)', and it is one of $(VARIANTS)))

# A store holding the model, for the bundle to carry.
#
# Every bundle carries its model, the development build included. It is not an optimisation:
# `AppDelegate.loadEngine` has no other way to reach one, so a bundle built without a store
# here launches and says it carries no model rather than reaching the network. A build-time
# copy is the only door, which is what keeps a running app off the network entirely.
# [LAW:types-are-the-program] [LAW:no-silent-failure]
#
# scripts/sign-release overrides this with a store it fetched itself, pinned to the release
# it is signing; a plain `make app` fills the one below from this Mac's own store.
CARRIED_MODEL_STORE := $(abspath $(DERIVED_DATA)/model-store)
BUNDLED_MODEL_STORE := $(CARRIED_MODEL_STORE)

# Where `make app` takes the model from, which is where `model-tool download` puts it.
# A local copy, never a fetch: the tool is what talks to Hugging Face, on purpose and by
# name, and `make app` only ever copies out of what it left behind. [LAW:one-way-deps]
MODEL_SOURCE := $(HOME)/Library/Application Support/low-talker/hub

# The scheme that builds the app, and the bundles it leaves behind.
# [LAW:one-source-of-truth] project.yml names these; they are written once here and every
# target below reads them, so a renamed product breaks in one place.
#
# The app is built beside its input method, which the scheme builds with it and the package
# installs apart from it.
SCHEME := LowTalker
APP := $(PRODUCTS)/LowTalker.app
INPUT_METHOD := $(PRODUCTS)/LowTalker Input Method.app
XCODE_RESOLVED_DIR := LowTalker.xcodeproj/project.xcworkspace/xcshareddata/swiftpm

.PHONY: app package install run variants test model-tool sbom check-sbom check-licenses clean signing-identity gate-replay gate-replay-baseline gate-replay-measure gate-classifier

# Regeneration is unconditional: xcodegen is idempotent and sub-second, and a
# timestamp rule cannot see removed sources or in-place rewrites of the project.
#
# [LAW:one-source-of-truth] Package.resolved decides the app's package versions, as it does
# `swift build`'s and the SBOM's. The project xcodegen writes has no resolved file, so
# xcodebuild would pick versions of its own in a fresh derived-data folder; the root one is
# copied in and xcodebuild resolves nothing else, stopping on a package it does not pin.
#
# Package targets, such as the bundle carrying LowTalkerCore's resources, never read
# project.yml's settings and sign automatically, which refuses a named Developer ID identity.
# Manual signing set here reaches them too.
#
# The source revision is read once and handed to the one xcodebuild call, which hands a
# command-line setting to every target, so the app and its input method carry the same one
# and the app sends words only to an input method of its own build.
define build_app
	xcodegen generate
	mkdir -p $(XCODE_RESOLVED_DIR)
	cp Package.resolved $(XCODE_RESOLVED_DIR)/Package.resolved
	revision=$$(scripts/source-revision) && \
	xcodebuild -project LowTalker.xcodeproj -scheme $(SCHEME) -configuration $(CONFIGURATION) \
		-onlyUsePackageVersionsFromResolvedFile \
		-derivedDataPath $(DERIVED_DATA) BUNDLED_MODEL_STORE="$(BUNDLED_MODEL_STORE)" \
		ACCEPTS_CONNECTIONS=$(ACCEPTS_CONNECTIONS) CODE_SIGN_STYLE=Manual SOURCE_REVISION="$$revision" \
		$(if $(SIGNING_IDENTITY),CODE_SIGN_IDENTITY="$(SIGNING_IDENTITY)") build
endef

# The store the bundle carries, copied out of $(MODEL_SOURCE). Two stores and not one,
# the way `model-tool pack` works: a store filled from Hugging Face also holds the hub client's
# own metadata, and a copy out of it takes only the files the manifests list, so the bundle
# carries exactly what an install certifies. [LAW:one-source-of-truth]
#
# The build is on the store it carries, so the store is its prerequisite by
# name: whichever store BUNDLED_MODEL_STORE names is the one filled before the build, and
# `BUNDLED_MODEL_STORE=` names none, which is how CI builds a bundle with no model.
# scripts/sign-release fills this same rule from the store it fetched, by passing
# MODEL_SOURCE. [LAW:dataflow-not-control-flow]
#
# Idempotent and cheap on the second run: `model-tool download --from` is an install, and an
# install of a model already whole copies nothing. It is a directory rather than a file, so
# it is phony and asks the tool rather than asking make to compare timestamps on 632 MB.
.PHONY: $(CARRIED_MODEL_STORE)
$(CARRIED_MODEL_STORE):
	@test -d "$(MODEL_SOURCE)" || { \
		echo "no model store at $(MODEL_SOURCE)."; \
		echo "Run 'make model-tool' and then '$(MODEL_TOOL) download' once; it is the only thing here that reaches the network."; \
		exit 1; \
	}
	$(MAKE) --no-print-directory model-tool >/dev/null
	"$(MODEL_TOOL)" download --models-dir "$@" --from "$(MODEL_SOURCE)"

app: $(BUNDLED_MODEL_STORE) $(if $(SIGNING_IDENTITY),,signing-identity)
	$(build_app)
	@echo "$(APP)"

# The installer package: the app into /Applications and its input method into
# /Library/Input Methods. A package is the only way either is installed, a development
# build included, since the text input system lists an input method only from the standard
# folders and the app puts nothing there itself. scripts/sign-release builds this same
# target under the Developer ID identity. [LAW:one-type-per-behavior]
MAKE_PKG = scripts/make-pkg "$(APP)" "$(INPUT_METHOD)" "$(PRODUCTS)"

package: app
	$(MAKE_PKG)

# This build installed from its package, the way a person installs a release: the package
# replaces what stood there, stops what ran from it, and starts the app again. The package
# is the one make-pkg names, since it names it after what the app carries.
install: app
	pkg=$$($(MAKE_PKG)) && sudo installer -pkg "$$pkg" -target /

run: install
	open "/Applications/LowTalker.app"

variants:
	@echo $(VARIANTS)

# Generating first is what lets `InputMethodPlistTests` read the plist xcodegen writes
# without generating it itself: a test that rewrote LowTalker.xcodeproj and App/Generated
# would be doing it underneath any build already running in this tree.
# [LAW:effects-at-boundaries] Unconditional and idempotent, for the reason given above
# `build_app`, and it is the same command.
test: signing-identity
	xcodegen generate
	swift test
	$(MAKE) check-licenses

# The model store, for the build: the default model's name, the commits `main` names for it,
# and fetching, checking and packing it. Nothing in it loads a model, so it needs no signing
# identity; the ad-hoc signature the link leaves is enough. Prints its path.
MODEL_TOOL := .build/debug/model-tool
model-tool:
	swift build --product model-tool
	@echo "$(MODEL_TOOL)"

# The speech gate replayed over the bench, with transients inserted, talk mixed under it and
# rooms of every level, reported against master's gate. `gate-replay-baseline` records the
# tree's rows as that baseline: on master, or as a gate change's last commit, so the committed
# baseline is always master's gate. [LAW:one-source-of-truth] Both run the one measurement.
# The ESC-50 clips it inserts are fetched into $(GATE_REPLAY), never committed.
GATE_REPLAY := .build/gate-replay
GATE_REPLAY_BASELINE := scripts/gate-replay/baseline.tsv

gate-replay: gate-replay-measure
	scripts/gate-replay/report $(GATE_REPLAY_BASELINE) $(GATE_REPLAY)/measured.tsv

gate-replay-baseline: gate-replay-measure
	cp $(GATE_REPLAY)/measured.tsv $(GATE_REPLAY_BASELINE)

gate-replay-measure:
	scripts/gate-replay/fetch-esc50 $(GATE_REPLAY)/esc50
	rm -f $(GATE_REPLAY)/measured.tsv
	GATE_REPLAY_OUT="$(abspath $(GATE_REPLAY))/measured.tsv" GATE_REPLAY_ESC50="$(abspath $(GATE_REPLAY))/esc50" \
		swift test --filter GateReplayTests

# The gate classifier trained again: its audio fetched into $(GATE_CLASSIFIER), never committed,
# and a candidate written beside it. Training runs differ, so this never writes the bundled
# Sources/LowTalkerCore/Models/GateClassifier.mlpackage: shipping a candidate is copying it there,
# with its threshold in GateClassifier.swift and its digest and manifest's licenses in
# sbom/rules.json, which `make sbom` holds the bundled model to.
GATE_CLASSIFIER := .build/gate-classifier

gate-classifier:
	scripts/gate-classifier/fetch-data $(GATE_CLASSIFIER)
	scripts/gate-classifier/train $(GATE_CLASSIFIER) $(GATE_CLASSIFIER)/trained.mlpackage

# What a release ships and under what license, as CycloneDX, read off the resolved
# build: Package.resolved, the checkouts `swift build` resolves under .build, and the
# default model. The model tool is built because the model's name is read from it, not
# copied, and building it is what resolves the checkouts on a clean clone. When this Mac's
# store holds the model, the rules for its two repos are held to what that install wrote.
# scripts/sbom stops and names any component sbom/rules.json cannot license.
# [LAW:no-silent-failure]
sbom: model-tool
	@set -eu; store="$(MODEL_SOURCE)"; [ -d "$$store" ] || store=""; \
	scripts/sbom "$(MODEL_TOOL)" sbom/lowtalker.cdx.json $${store:+"$$store"}

# The committed SBOM is the one the build writes, or `make test` fails: a committed file
# that can drift from Package.resolved is a maintained list wearing a generated one's name.
# Against HEAD, not the index: a regenerated file that is staged and not committed is
# still a stale commit.
check-sbom: sbom
	@git cat-file -e HEAD:sbom/lowtalker.cdx.json \
		|| { echo "check-sbom: sbom/lowtalker.cdx.json is not committed" >&2; exit 1; }
	@git diff HEAD --exit-code --stat -- sbom/lowtalker.cdx.json \
		|| { echo "check-sbom: the committed sbom/lowtalker.cdx.json is not what the build writes; commit the regenerated file" >&2; exit 1; }

# Refuses a pull request that ships a component under a license we have not accepted, or
# one whose license nobody identified. It reads the committed SBOM, which `check-sbom` has
# just held to the build, so a dependency cannot reach the tree without passing it. The
# gate's own tests run first: a gate that passes everything looks exactly like a clean tree.
# The notices are written as the app build writes them, so an SBOM they cannot be made from
# fails here, on the pull request, and not in the next release's build.
check-licenses: check-sbom
	python3 -B -m unittest discover -s scripts/tests
	scripts/check-licenses sbom/lowtalker.cdx.json
	scripts/notices sbom/lowtalker.cdx.json .build/notices.txt

# The dev identity, made ready before anything signs with it: `make app` when it signs with
# project.yml's identity, and `make test`, whose insertion tests sign a probe with it. Every
# run leaves it usable, so it runs every time rather than once per Mac.
# [LAW:dataflow-not-control-flow] Builds in other worktrees run it at the same moment, so it
# holds a per-user lock, which the kernel drops if the holder dies, or two would both make one.
signing-identity:
	lockf -k "$$(getconf DARWIN_USER_TEMP_DIR)lowtalker-signing-identity.lock" \
		scripts/make-signing-identity "$$(scripts/signing-identity)"

clean:
	rm -rf LowTalker.xcodeproj $(DERIVED_DATA) .build
