.PHONY: help dev test compile migrate reset release console

help:
	@echo "Job Applications Bot"
	@echo ""
	@echo "Development:"
	@echo "  make dev        - Start bot in dev mode"
	@echo "  make console    - Open iex console with bot"
	@echo "  make test       - Run tests"
	@echo "  make compile    - Compile code"
	@echo ""
	@echo "Database:"
	@echo "  make migrate    - Run migrations"
	@echo "  make reset      - Reset database (drop/create/migrate)"
	@echo ""
	@echo "Production:"
	@echo "  make release    - Build production release"

dev:
	mix phx.server

console:
	iex -S mix

test:
	mix test

compile:
	mix compile

migrate:
	mix ecto.migrate

reset:
	mix ecto.reset

release:
	mix release

deps:
	mix deps.get

setup: deps reset
	@echo "✓ Bot ready to run: make dev"
