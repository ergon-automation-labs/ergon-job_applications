# Job Applications Bot

A bot that manages the full lifecycle of job applications — from listing discovery through artifact generation, pipeline state tracking, and email signal detection.

## Quick Start

```bash
mix deps.get
mix test
```

## Overview

The Job Applications Bot handles:

- **Resume as Structured Data** — roles, bullets, skills, framing profiles
- **Artifact Generation** — tailored cover letters and resumes via LLM Proxy
- **Application State Machine** — identified → submitted → phone_screen → offer → accepted/declined
- **Email Signal Detection** — interview invites, rejections, offers (Phase 2)
- **Job Listing Discovery & Scoring** — automatic scraping and fit scoring (Phase 2)
- **Daily Digest** — pipeline summary via LLM (Phase 2)
- **GTD Bot Integration** — action items on key transitions

## Implementation Phases

### Phase 1: Manual Pipeline + Artifact Generation
- Resume, Listing, Application schemas
- Artifact generation (cover letters, tailored resumes)
- State machine with ApplicationServer
- LiveView Kanban dashboard
- GTD Bot integration

### Phase 2: Email Integration + Job Discovery
- Email watcher + signal detection
- Job listing scrapers
- Automatic scoring
- Daily digest

### Phase 3: Intelligence + Outcome Tracking
- Strategy ↔ conversion correlation
- Bullet performance tracking
- Company enrichment

## Documentation

- **North Star:** [JOB_APPLICATION_BOT_NORTH_STAR.md](../docs/north_star_docs/JOB_APPLICATION_BOT_NORTH_STAR.md)
- **Developer Guide:** [CLAUDE.md](./CLAUDE.md)
- **LLM Proxy:** [llm-proxy.md](../docs/north_star_docs/llm-proxy.md)

## Board Discovery & Ingestion Setup

The bot automatically discovers active job boards on **Greenhouse** and **Lever**, tests them against the public APIs, and updates the Salt pillar configuration for production deployment.

### What It Does

- **Discovers** 23+ companies across AI/ML, DevTools, and Infrastructure categories
- **Tests** Greenhouse and Lever public APIs (no auth required)
- **Generates** YAML configuration ready for Salt deployment
- **Updates** Salt pillar at `bot_army_infra/salt/pillar/job_applications.sls`
- **Auto-commits** changes with board count in git message

### Quick Commands

```bash
# Preview discovered boards (no changes)
make sync-boards-dry-run

# Discover boards and show as YAML
make discover-boards-yaml

# Auto-discover, update Salt pillar, and commit
make sync-boards

# Run discovery with specific categories
mix job_applications.discover_boards --categories ai,devtools
```

### Setup Workflow

1. **Discover & Preview**
   ```bash
   cd /Users/abby/code/elixir_bots/bot_army_job_applications
   make sync-boards-dry-run
   # Review output — shows which boards are active and job counts
   ```

2. **Update Salt Pillar**
   ```bash
   make sync-boards
   # Updates ../bot_army_infra/salt/pillar/job_applications.sls
   # Creates git commit with board count
   ```

3. **Deploy to Production**
   ```bash
   cd ../bot_army_infra
   git push origin main
   # Jenkins automatically triggers deployment

   make deploy-bot BOT=job_applications
   # Or wait for Jenkins to auto-deploy
   ```

4. **Verify in Production**
   ```bash
   # Check NATS can reach the bot
   nats request --server nats://localhost:4222 job.application.list '{}' --timeout 3s
   # Expect: {"ok":true,"applications":[...]}
   ```

### Supported Companies

**AI/ML** (7): Anthropic, Hugging Face, Scale AI, Together AI, Replicate, CoreWeave, Lightning AI

**DevTools** (8): Cursor, Replit, JetBrains, Vercel, Netlify, Astro, Prisma, Svelte

**Infrastructure** (8): Cloudflare, HashiCorp, Fly.io, Mux, Supabase, PlanetScale, Railway, Wiz

### How to Add Companies

Edit `lib/mix/tasks/discover_boards.ex` and `lib/mix/tasks/sync_boards_to_salt.ex`:

1. Add a `{name, slug, platform}` tuple to the `@companies` map (e.g., `{"MyCompany", "myco", "greenhouse"}`)
2. Run `make sync-boards-dry-run` to verify the board is active
3. Run `make sync-boards` to update Salt pillar

**Note:** Slug is the Greenhouse board token or Lever site name (usually lowercase company name).

## Architecture

See [CLAUDE.md](./CLAUDE.md) for:
- Module structure
- Implementation phases
- NATS subject taxonomy
- Development workflow
- Testing strategy

## License

Proprietary — Ergon Automation Labs
