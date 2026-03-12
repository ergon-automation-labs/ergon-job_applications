# CLAUDE.md

Guidance for Claude Code when working with `bot_army_job_applications`.

---

## Purpose

**bot_army_job_applications** is the job application tracking and automation bot.

Handles:
- Job listing discovery and scoring
- Resume as structured data (roles, bullets, skills)
- Artifact generation (tailored cover letters and resumes)
- Application state machine (identified → submitted → phone_screen → offer → etc.)
- Email signal detection (interview invites, rejections, offers)
- Daily digest generation
- GTD Bot integration (action items on key transitions)

---

## File Organization

```
bot_army_job_applications/
├── lib/
│   ├── bot_army_job_applications.ex         # Main module
│   └── bot_army_job_applications/
│       ├── application.ex                    # Application supervisor
│       ├── repo.ex                           # Ecto repository
│       │
│       ├── schemas/
│       │   ├── resume.ex
│       │   ├── role.ex
│       │   ├── bullet.ex
│       │   ├── skill.ex
│       │   ├── listing.ex
│       │   └── application.ex
│       │
│       ├── stores/
│       │   ├── resume_store.ex
│       │   ├── listing_store.ex
│       │   └── application_store.ex
│       │
│       ├── handlers/
│       │   ├── artifact_handler.ex
│       │   ├── application_handler.ex
│       │   └── ... (Phase 2+)
│       │
│       ├── nats/
│       │   ├── consumer.ex
│       │   └── publisher.ex
│       │
│       └── pipeline/
│           ├── application_supervisor.ex
│           └── application_server.ex
│
├── priv/repo/migrations/
│   ├── 20260311000001_create_resumes.exs
│   ├── 20260311000002_create_roles.exs
│   ├── 20260311000003_create_listings.exs
│   └── 20260311000004_create_applications.exs
│
├── test/
│   ├── test_helper.exs
│   └── bot_army_job_applications/
│       ├── schemas/
│       ├── stores/
│       ├── handlers/
│       └── integration/
│
├── config/
│   ├── config.exs
│   └── test.exs
│
├── mix.exs
├── CLAUDE.md
└── README.md
```

---

## Core Dependencies

- **bot_army_core** — NATS envelope decoding, schema validation, common patterns
- **bot_army_runtime** — Runtime utilities (NATS connection, supervisor helpers)
- **ecto_sql** — Database ORM
- **postgrex** — PostgreSQL adapter
- **jason** — JSON encoding/decoding
- **logger_json** — Structured logging

---

## Implementation Phases

### Phase 1 — Manual Pipeline + Artifact Generation

Goal: Paste a JD, get a tailored cover letter and resume. Watch state move on the dashboard.

**Scope**: No email integration, no scrapers. Manual application entry, artifact generation via LLM Proxy.

**Key modules:**
- Resume/Role/Bullet/Skill/Listing/Application schemas (Ecto)
- ResumeStore, ListingStore, ApplicationStore (GenServers + Ecto hybrid)
- ApplicationSupervisor + ApplicationServer (state machine)
- ArtifactWorker (resume composition + cover letter generation via LLM Proxy)
- ApplicationHandler (NATS message routing)
- LiveView dashboard (Kanban with application cards)

### Phase 2 — Email Integration + Job Discovery

Goal: Email watcher detects interview signals. Scrapers find and score listings automatically.

**Additional modules:**
- EmailWatcher (IMAP polling)
- SignalClassifier (LLM-based intent detection)
- IngestionWorker (scraper orchestration)
- DedupFilter (hash-based deduplication)
- ScoringWorker (JD tag extraction + fit scoring)
- TriageWorker (threshold routing)
- DigestWorker (daily summary)

### Phase 3 — Intelligence + Outcome Tracking

Goal: Correlate framing strategy with conversion rates. Track which bullets appear in successful applications.

**Additional modules:**
- OutcomeTracker (log results per application)
- BulletPerformance (which bullets succeeded)
- CompanyEnrichment (funding, headcount, Glassdoor data)
- FeedbackLoop (strategy ↔ conversion correlation)

---

## Development Workflow

### Setup

```bash
# From bot_army_job_applications directory
mix deps.get
mix test
```

### Key Concepts

**Resume as Structured Data:**
- Resume = identity + roles + skills (database, not document)
- Each role has framing profiles (platform, sre, ai_infra, etc.)
- Each bullet has alt_phrasings and tags
- Artifact generation composes tailored output from this structure

**Application State Machine:**
```
identified → drafting → ready_to_submit → submitted → phone_screen → technical → offer → accepted/declined
                                        ├→ rejected
                                        └→ ghosted
```
- Email signals can trigger state changes
- Every transition is logged with metadata (triggered_by, email_id, confidence)
- GTD Bot receives action items on key transitions

**Artifact Generation:**
1. Parse JD → extract tags via LLM Proxy
2. Score each bullet against tag vector
3. Select framing profile based on dominant tags
4. Pick alt phrasings to match JD vocabulary
5. Assemble → emit coverage score
6. Render to PDF/DOCX

---

## NATS Subject Taxonomy

### Phase 1 (Manual Pipeline)
**Subscribes:**
- `job.application.create` — intent to apply (opens ApplicationServer)
- `job.application.command.transition` — user-initiated state change
- `job.application.artifact.request` — request cover letter or resume variant

**Publishes:**
- `job.application.created` — application entered pipeline
- `job.application.state.updated` — state machine transition
- `job.application.artifact.result` — generated artifact ready
- `gtd.inbox.add` — action items (prep for phone screen, review offer, etc.)

### Phase 2 (Email + Discovery)
**Additional Subscribes:**
- `job.listings.ingest` — raw listings from scrapers
- `job.listing.score.request` — trigger scoring
- `job.digest.request` — trigger daily summary

**Additional Publishes:**
- `job.listings.new` — post-dedup, post-filter listing
- `job.listing.score.result` — fit score computed
- `job.application.signal.detected` — unconfirmed email signal
- `job.digest.ready` — daily digest ready

---

## LLM Proxy Integration

| Query Type | Task Key | Model | When Used |
|---|---|---|---|
| JD tag extraction | `jd_analysis` | Sonnet | Per new listing |
| Fit scoring | `classify` | Haiku | Per listing (high volume) |
| Cover letter generation | `cover_letter` | Sonnet | Per application |
| Resume bullet selection | `resume_compose` | Sonnet | Per application |
| Email signal classification | `classify` | Haiku | Per job-related email |
| Daily digest summary | `digest_summary` | Sonnet | Once/day |

**Caching:** JD analysis cached by text hash (24h TTL). Email classification not cached.

---

## Testing

```bash
mix test                    # Run all tests
mix test --cover            # With coverage
mix credo                   # Linting
mix dialyzer                # Static analysis
```

Tests should:
- Use actual PostgreSQL (via Kubernetes NodePort :30004)
- Run against real Ecto schemas
- Test handler validation and NATS publishing
- Mock LLM Proxy calls via Mox
- Verify state transitions and event ordering

---

## Deployment

This bot is deployed via Salt from `bot_army_infra`:

```bash
cd ../bot_army_infra
make deploy-bot BOT=job_applications
```

Deployment requires:
1. Core schemas deployed first (common, job_applications schemas)
2. bot_army_core library deployed
3. PostgreSQL accessible

---

## Related Documentation

- **North Star:** `docs/north_star_docs/JOB_APPLICATION_BOT_NORTH_STAR.md`
- **LLM Proxy:** `docs/north_star_docs/llm-proxy.md`
- **GTD Bot:** `docs/north_star_docs/GTD_BOT_NORTH_STAR.md`
- **Core Library:** `bot_army_core/README.md`

---

## Notes for Implementation

- **Resume data is the source of truth.** Artifacts are composed on demand, not stored as static documents.
- **Email signals are never auto-applied.** Always presented to user for confirmation.
- **State machine is strict.** Only legal transitions are possible. Invalid transitions surface errors.
- **LLM calls are essential.** Artifact generation quality depends on good JD parsing and bullet scoring.
- **GTD integration is critical.** Action items keep job search work visible in GTD pipeline.
