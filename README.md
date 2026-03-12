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

## Architecture

See [CLAUDE.md](./CLAUDE.md) for:
- Module structure
- Implementation phases
- NATS subject taxonomy
- Development workflow
- Testing strategy

## License

Proprietary — Ergon Automation Labs
