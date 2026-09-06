SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
MIX ?= /Users/abby/.local/share/mise/shims/mix

.PHONY: test-handlers test-stores test-nats test-integration test-full setup help deps test credo dialyzer coverage check format clean release publish-release publish-release-docker setup-hooks setup-db reset-db logs logs-server discover-boards discover-boards-yaml sync-boards sync-boards-dry-run scan scan-listings build build-docker build-native test-docker test-native start stop restart logs-all git-push push-and-publish sync-release-version deploy pre-push-cleanup

help:
	@echo "BotArmyJobApplications - Job Applications Bot"
	@echo ""
	@echo "Portable Distribution (works anywhere with Docker):"
	@echo "  make build           - Docker build (default, recommended)"
	@echo "  make build-native    - Local Elixir/Mix build (requires Elixir 1.14+)"
	@echo "  make test-docker     - Run tests in Docker"
	@echo "  make start           - Start all services (docker compose up -d)"
	@echo "  make stop            - Stop all services"
	@echo "  make logs            - Watch Docker service logs (compose)"
	@echo "  make logs-server     - Tail deployed server log with grc (/var/log/bot_army/job_applications.log)"
	@echo ""
	@echo "Setup commands (personal development):"
	@echo "  make setup           - Set up project (deps.get + git hooks + database)"
	@echo "  make setup-hooks     - Install git hooks for pre-push validation"
	@echo "  make setup-db        - Create and migrate test database (required for testing)"
	@echo "  make reset-db        - Drop and recreate test database (useful for troubleshooting)"
	@echo ""
	@echo "Development commands:"
	@echo "  make test            - Run all tests"
	@echo "  make test-native     - Run tests locally (requires Elixir + PostgreSQL)"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Job discovery & ingestion commands:"
	@echo "  make discover-boards      - Discover active job boards on Greenhouse/Lever"
	@echo "  make discover-boards-yaml - Generate YAML config for discovered boards"
	@echo "  make sync-boards          - Discover boards + auto-update Salt pillar + commit"
	@echo "  make sync-boards-dry-run  - Preview board discovery (no changes)"
	@echo "  make scan-listings        - Scan and ingest jobs from configured boards"
	@echo "  make scan                 - Full discovery + scan (all at once)"
	@echo ""
	@echo "Release commands:"
	@echo "  make release         - Build OTP release locally"
	@echo "  make publish-release - Build, package, and publish to GitHub"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy          - Deploy to production (requires published release)"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"
	@echo "  make deploy          - Deploy to production"
	@echo ""

setup: init deps setup-hooks setup-db
	@echo "✓ Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure .env with your database settings (if needed)"
	@echo "  2. Run: make test"
	@echo "  3. Start developing!"
	@echo ""

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "✓ Git hooks installed (core.hooksPath = git-hooks)"

setup-db:
	@echo "Setting up test database..."
	@MIX_ENV=test $(MIX) ecto.create || true
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database created and migrations applied"

reset-db:
	@echo "⚠️  Resetting test database (dropping and recreating)..."
	@MIX_ENV=test $(MIX) ecto.drop || true
	@MIX_ENV=test $(MIX) ecto.create
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database reset complete"

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

_compile-impl:
	@LOG_FILE="/tmp/compile-applications-$$(date +%s).log"; \
	echo "Compiling applications and logging to $$LOG_FILE..."; \
	$(MIX) compile 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Compilation log: $$LOG_FILE"

deps:
	$(MIX) deps.get

_compile-impl:
	@LOG_FILE="/tmp/compile-applications-$$(date +%s).log"; \
	echo "Compiling applications and logging to $$LOG_FILE..."; \
	$(MIX) compile 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Compilation log: $$LOG_FILE"

test:
	$(MIX) test

test-handlers:
	MIX_ENV=test $(MIX) test --only handlers --trace

test-stores:
	MIX_ENV=test $(MIX) test --only stores --trace

test-nats:
	MIX_ENV=test $(MIX) test --only nats --trace

test-integration:
	$(MIX) test --include integration --trace

test-full:
	$(MIX) test --include integration --include nats_live --trace

credo:
	$(MIX) credo --only warning

dialyzer: deps
	$(MIX) dialyzer

coverage:
	$(MIX) coveralls

check: test credo
	@echo "All checks passed!"

format:
	$(MIX) format

clean:
	$(MIX) clean
	rm -rf _build cover

# ============================================================================
# Portable Distribution Targets (Docker-based, work everywhere)
# ============================================================================

# Default: Docker build (works everywhere, no local Elixir required)
build: build-docker

build-docker:
	@echo "Building Job Applications bot with Docker..."
	docker compose build job_applications

# Bare-metal: local Elixir toolchain (requires Elixir 1.14+)
build-native: deps
	@echo "Building with local Elixir (Mix)..."
	$(MIX) compile

# Run tests (native Mix, same as other bots)
test:
	$(MIX) test

test-docker:
	@echo "Running tests with Docker..."
	docker compose run --rm job_applications mix test

test-native: test

# Docker Compose stack (all services: NATS, Postgres, bot, etc.)
start:
	@echo "Starting Job Applications stack..."
	docker compose up -d
	@echo "Services starting. View logs with: make logs"

stop:
	@echo "Stopping Job Applications stack..."
	docker compose down

restart:
	docker compose restart

pre-push-cleanup:
	@echo "🧹 Cleaning up pre-push artifacts..."
	@if git diff --quiet git-hooks/pre-push; then \
		echo "✓ No hook changes"; \
	else \
		echo "📋 Staging hook changes..."; \
		git add git-hooks/pre-push git-hooks/post-push; \
		git commit -m "chore: sync hooks" || true; \
	fi
	@if git diff --quiet mix.lock; then \
		echo "✓ No lock file changes"; \
	else \
		echo "📋 Staging lock file changes..."; \
		git add mix.lock; \
		git commit -m "chore: lock file updates from pre-push validation" || true; \
	fi
	@echo "✓ Ready to push"

push: test compile credo pre-push-cleanup
	@echo "✅ All validations passed"
	@echo "$$(date +%s)" > .push-validated
	@echo "✓ Proof-of-validation created"
	@$(MAKE) git-push


git-push: pre-push-cleanup
	@BOT_NAME=job_applications; \
	LOG_FILE="/tmp/git-push-$${BOT_NAME}-$$(date +%s).log"; \
	echo "Pushing to origin/main and logging to $$LOG_FILE..."; \
	git push 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Log saved: $$LOG_FILE"

push-and-publish: git-push publish-release

logs:
	docker compose logs -f job_applications

logs-all:
	docker compose logs -f

logs-server:
	@$(SCRIPTS_DIRECTORY)/tail_bot_log.sh

# ============================================================================
# Release & Deployment (personal/internal only)
# ============================================================================

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/bot_army_job_applications
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/bot_army_job_applications/"
	@echo ""

HAS_RESPONDER_CHANGES := $(shell git diff --name-only origin/main 2>/dev/null | grep -qE 'lib/.*/(responders|nats|consumers)/|lib/.*/bridge.*\.ex|lib/.*/event.*\.ex' && echo 1 || echo 0)

sync-release-version:
	@VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "❌ Failed to resolve version from mix.exs"; exit 1; \
	fi; \
	TIMESTAMP=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	echo "$$VERSION" > .release-published; \
	echo "✅ Synced release version: v$$VERSION ($$TIMESTAMP)"

publish-release:
	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "Failed to resolve version from mix.exs"; \
		exit 1; \
	fi; \
	TARBALL=job_applications_bot-$$VERSION.tar.gz; \
	echo "Version: $$VERSION"; \
	echo ""; \
	if [ -f "$$TARBALL" ]; then \
		echo "✓ Tarball already exists locally: $$TARBALL (skipping rebuild)"; \
	else \
		echo "📦 Building release (tarball not found locally)..."; \
		if [ "$(HAS_RESPONDER_CHANGES)" = "1" ] && [ "$(SKIP_INTEGRATION_GATE)" != "1" ]; then \
			echo "🔒 Responder/NATS/bridge changes detected. Integration tests required before publish."; \
			$(MAKE) test-integration || { echo "❌ Integration tests failed. Publish blocked."; exit 1; }; \
			echo "✅ Integration tests passed."; \
		else \
			[ "$(HAS_RESPONDER_CHANGES)" = "1" ] && echo "⚠️  Skipping integration gate (SKIP_INTEGRATION_GATE=1)" || true; \
		fi; \
		$(MAKE) release; \
		echo "Creating release tarball..."; \
		tar -czf "$$TARBALL" -C _build/prod/rel job_applications_bot/; \
		echo "✓ Created: $$TARBALL"; \
	fi; \
	echo ""; \
	echo "Publishing to GitHub releases..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create v$$VERSION "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "Job Applications Bot Elixir release v$$VERSION" \
			--draft=false; \
	fi; \
	echo "✓ Release published to GitHub"; \
	$(MAKE) sync-release-version; \
	echo ""; \
	echo "Requesting deploy via deploy pipeline (deploy.release.requested.<target>)..."; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	REPO_SLUG=$$(git config --get remote.origin.url | sed 's/.*\///; s/\.git$$//'); \
	NATS_SERVERS=$${NATS_SERVERS:-nats://localhost:4222}; \
	DEPLOY_TARGET=$${DEPLOY_TARGET:-air}; \
	if [ "$$DEPLOY_TARGET" = "skip" ]; then \
		echo "(DEPLOY_TARGET=skip - pipeline deploy not requested)"; \
	else \
		REQUEST_ID="pub-$$(date +%s)-$$RANDOM"; \
		ENVELOPE=$$(jq -n \
			--arg eid "$$(uuidgen | tr 'A-Z' 'a-z')" \
			--arg ts "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			--arg node "$$(hostname -s)" \
			--arg payload "$$(jq -n --arg bot "$${BOT_NAME}" --arg repo "$$REPO_SLUG" --arg version "$$VERSION" --arg tag "v$$VERSION" --arg target "$${DEPLOY_TARGET}" --arg rid "$$REQUEST_ID" '{bot: $$bot, repo: $$repo, version: $$version, tag: $$tag, release_tag: $$tag, target: $$target, request_id: $$rid}')" \
			'{event_id: $$eid, event: "deploy.release.requested", schema_version: "1.0", timestamp: $$ts, source: "publish_release", source_node: $$node, triggered_by: "user", payload: ($$payload | fromjson)}'); \
		RESP=$$(nats --server "$$NATS_SERVERS" request "deploy.release.requested.$${DEPLOY_TARGET}" "$$ENVELOPE" --timeout 15s 2>/dev/null) \
			&& echo "✓ Deploy requested via pipeline (ack: $${RESP:0:160})" \
			|| echo "⚠️  Deploy request unanswered (pipeline down?) - deploy manually: cd ../bot_army_infra && make salt-apply-bot BOT=$${BOT_NAME}"; \
	fi; \
	echo ""

discover-boards:
	@echo "==============================================="
	@echo "Discovering job boards (Greenhouse/Lever)"
	@echo "==============================================="
	@echo ""
	$(MIX) job_applications.discover_boards
	@echo ""
	@echo "Next steps:"
	@echo "  If boards were found, sync them to production:"
	@echo "  make sync-boards"
	@echo ""

discover-boards-yaml:
	@echo "==============================================="
	@echo "Discovering job boards (YAML format)"
	@echo "==============================================="
	@echo ""
	$(MIX) job_applications.discover_boards --output /tmp/ingestion_boards.yaml
	@echo ""
	@cat /tmp/ingestion_boards.yaml
	@echo ""
	@echo "To apply these boards to production:"
	@echo "  make sync-boards"
	@echo ""

sync-boards:
	@echo "==============================================="
	@echo "Syncing discovered boards to Salt pillar"
	@echo "==============================================="
	@echo ""
	$(MIX) job_applications.sync_boards_to_salt
	@echo ""
	@echo "Next steps:"
	@echo "  cd ../bot_army_infra"
	@echo "  git push origin main"
	@echo "  make deploy-bot BOT=job_applications"
	@echo ""

sync-boards-dry-run:
	@echo "==============================================="
	@echo "Preview board discovery (no changes)"
	@echo "==============================================="
	@echo ""
	$(MIX) job_applications.sync_boards_to_salt --dry-run
	@echo ""

scan-listings:
	@echo "==============================================="
	@echo "Triggering job listing scan via NATS"
	@echo "==============================================="
	@echo ""
	@echo "Sending scan request to job_applications bot..."
	nats request --server nats://localhost:4222 \
		job.listings.fetch.request \
		'{"event_id":"'$$(uuidgen | tr '[:upper:]' '[:lower:]')'","event":"job.listings.fetch.request","schema_version":"1.0","timestamp":"'$$(date -u +%Y-%m-%dT%H:%M:%SZ)'","source":"manual","source_node":"manual","triggered_by":"user","payload":{}}' \
		--timeout 30s || echo "Scan triggered (running asynchronously)"
	@echo ""
	@echo "✓ Job listing scan triggered"
	@echo "Check logs: tail -50 /var/log/bot_army/job_applications.log"
	@echo ""

list-listings:
	@echo "==============================================="
	@echo "Fetching discovered listings from bot"
	@echo "==============================================="
	@echo ""
	nats request --server nats://localhost:4222 job.listings.list '{}' --timeout 5s | jq '.listings | length as $$count | "Found \($$count) listings:" , (.[] | "\(.company) — \(.role_title)")'
	@echo ""

scan: discover-boards scan-listings
	@echo "==============================================="
	@echo "✓ Job discovery and scan requests submitted"
	@echo "==============================================="
	@echo ""
	@echo "Next steps:"
	@echo "  Monitor scan progress: tail -f /var/log/bot_army/job_applications.log"
	@echo "  View discovered listings: make list-listings"
	@echo ""

deploy:
	@echo "Deploying job_applications to production..."
	@cd ~/code/elixir_bots && make deploy-bot BOT=job_applications








.PHONY: bump-version

bump-version:
	@if [ -z "$(BUMP)" ]; then \
		echo "Usage: make bump-version BUMP=major|minor|patch"; \
		exit 1; \
	fi
	@$(MAKE) -C .. bump-version BOT=$(shell basename $(CURDIR)) BUMP=$(BUMP)

# Shared targets (push, credo, pre-push-cleanup, bump-version, git-push).
# Defined once in bot_army_infra so they cannot drift per repo.
BOT_ARMY_COMMON_MK := $(abspath $(CURDIR)/../bot_army_infra/make/common.mk)
ifeq ($(wildcard $(BOT_ARMY_COMMON_MK)),)
$(warning bot_army_infra not found at $(BOT_ARMY_COMMON_MK) - shared targets unavailable)
else
include $(BOT_ARMY_COMMON_MK)
endif
