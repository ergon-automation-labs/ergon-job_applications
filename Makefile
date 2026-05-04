SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)

.PHONY: test-handlers test-stores test-nats test-integration test-full setup help deps test credo dialyzer coverage check format clean release publish-release setup-hooks setup-db reset-db logs logs-server discover-boards discover-boards-yaml sync-boards sync-boards-dry-run scan scan-listings build build-docker build-native test-docker test-native start stop restart logs-all push-and-publish

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
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"
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
	@MIX_ENV=test mix ecto.create || true
	@MIX_ENV=test mix ecto.migrate
	@echo "✓ Test database created and migrations applied"

reset-db:
	@echo "⚠️  Resetting test database (dropping and recreating)..."
	@MIX_ENV=test mix ecto.drop || true
	@MIX_ENV=test mix ecto.create
	@MIX_ENV=test mix ecto.migrate
	@echo "✓ Test database reset complete"

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

deps:
	mix deps.get

test:
	mix test

test-handlers:
	MIX_ENV=test mix test --only handlers --trace

test-stores:
	MIX_ENV=test mix test --only stores --trace

test-nats:
	MIX_ENV=test mix test --only nats --trace

test-integration:
	mix test --include integration --trace

test-full:
	mix test --include integration --include nats_live --trace

credo:
	mix credo

dialyzer: deps
	mix dialyzer

coverage:
	mix coveralls

check: test credo dialyzer
	@echo "All checks passed!"

format:
	mix format

clean:
	mix clean
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
	mix compile

# Run tests (default: Docker)
test: test-docker

test-docker:
	@echo "Running tests with Docker..."
	docker compose run --rm job_applications mix test

test-handlers:
	MIX_ENV=test mix test --only handlers --trace

test-stores:
	MIX_ENV=test mix test --only stores --trace

test-nats:
	MIX_ENV=test mix test --only nats --trace

test-integration:
	mix test --include integration --trace

test-full:
	mix test --include integration --include nats_live --trace

# Bare-metal tests (requires Elixir, PostgreSQL running locally)
test-native: setup-db
	@echo "Running tests locally..."
	mix test

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

push-and-publish:
	@git push && $(MAKE) publish-release

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
	MIX_ENV=prod mix release
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/bot_army_job_applications/"
	@echo ""

publish-release: release
	@echo "==============================================="
	@echo "Publishing release to GitHub"
	@echo "==============================================="
	@echo ""

	# Get version from release metadata (release name must match mix.exs)
	VERSION=$$(cat _build/prod/rel/bot_army_job_applications/releases/RELEASES | tail -1 | cut -d' ' -f2); \
	echo "Release version: $$VERSION"; \
	\
	# Create tarball
	echo "Creating release tarball..."; \
	tar -czf bot_army_job_applications-$$VERSION.tar.gz -C _build/prod/rel bot_army_job_applications/; \
	echo "✓ Created: bot_army_job_applications-$$VERSION.tar.gz"; \
	echo ""; \
	\
	# Create GitHub release
	echo "Publishing to GitHub releases..."; \
	gh release create v$$VERSION bot_army_job_applications-$$VERSION.tar.gz \
		--title "Release v$$VERSION" \
		--notes "Job Applications Bot Elixir release v$$VERSION. Download and deploy with Jenkins." \
		--draft=false; \
	echo "✓ Release published to GitHub"; \
	echo ""; \
	echo "Next steps:"; \
	echo "1. Jenkins will automatically detect the new release"; \
	echo "2. Trigger deployment in Jenkins UI or wait for auto-deployment"; \
	echo "3. Check deployment status in Jenkins dashboard"; \
	echo ""

discover-boards:
	@echo "==============================================="
	@echo "Discovering job boards (Greenhouse/Lever)"
	@echo "==============================================="
	@echo ""
	mix job_applications.discover_boards
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
	mix job_applications.discover_boards --output /tmp/ingestion_boards.yaml
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
	mix job_applications.sync_boards_to_salt
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
	mix job_applications.sync_boards_to_salt --dry-run
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
