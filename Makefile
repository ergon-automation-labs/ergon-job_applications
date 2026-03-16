.PHONY: setup help deps test credo dialyzer coverage check format clean release publish-release setup-hooks setup-db reset-db discover-boards discover-boards-yaml sync-boards sync-boards-dry-run

help:
	@echo "BotArmyJobApplications - Job Applications Bot"
	@echo ""
	@echo "Setup commands:"
	@echo "  make setup           - Set up project (deps.get + git hooks + database)"
	@echo "  make setup-hooks     - Install git hooks for pre-push validation"
	@echo "  make setup-db        - Create and migrate test database (required for testing)"
	@echo "  make reset-db        - Drop and recreate test database (useful for troubleshooting)"
	@echo ""
	@echo "Development commands:"
	@echo "  make test            - Run all tests"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Board discovery commands (job ingestion setup):"
	@echo "  make discover-boards     - Discover active job boards on Greenhouse/Lever"
	@echo "  make discover-boards-yaml - Generate YAML config for discovered boards"
	@echo "  make sync-boards         - Discover boards + auto-update Salt pillar + commit"
	@echo "  make sync-boards-dry-run - Preview board discovery (no changes)"
	@echo ""
	@echo "Release commands (normally automatic via git hook):"
	@echo "  make release         - Build OTP release locally (manual, if needed)"
	@echo "  make publish-release - Build, package, and publish to GitHub (manual, if needed)"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Pre-push hook validates, builds, and publishes automatically"
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

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	MIX_ENV=prod mix release --overwrite
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/job_applications_bot/"
	@echo ""

publish-release: release
	@echo "==============================================="
	@echo "Publishing release to GitHub"
	@echo "==============================================="
	@echo ""

	# Get version from release metadata
	VERSION=$$(cat _build/prod/rel/job_applications_bot/releases/RELEASES | tail -1 | cut -d' ' -f2); \
	echo "Version: $$VERSION"; \
	\
	# Create tarball
	echo "Creating release tarball..."; \
	tar -czf job_applications_bot-$$VERSION.tar.gz -C _build/prod/rel job_applications_bot/; \
	echo "✓ Tarball created: job_applications_bot-$$VERSION.tar.gz"; \
	echo ""; \
	\
	# Create GitHub release
	echo "Creating GitHub release v$$VERSION..."; \
	gh release create v$$VERSION job_applications_bot-$$VERSION.tar.gz \
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

discover-boards-yaml:
	@echo "==============================================="
	@echo "Discovering job boards (YAML format)"
	@echo "==============================================="
	@echo ""
	mix job_applications.discover_boards --output /tmp/ingestion_boards.yaml
	@echo ""
	@cat /tmp/ingestion_boards.yaml
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
