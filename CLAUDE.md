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
│   ├── README.md                          # Migration structure guide
│   ├── portable/                          # Portable (public) migrations synced to mirrors
│   │   ├── 20260311000001_create_resumes.exs
│   │   ├── 20260311000002_create_resume_roles.exs
│   │   ├── ... (all schema-only migrations)
│   │   └── 20260320000008_add_recommendation_fields_to_listings.exs
│   ├── 20260311000001_create_resumes.exs  # Also in migrations/ (personal version)
│   ├── 20260311000002_create_resume_roles.exs
│   ├── ... (all 8 existing migrations)
│   └── 20260320000008_add_recommendation_fields_to_listings.exs
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

## Portable Distribution — Migration Strategy

This repo is synced to a public mirror (`portable_job_applications`) for self-hosted users. Migrations are split to enable clean sync:

### Migration Discipline

**Schema-only migrations** (new tables, generic columns):
- Add to `priv/repo/migrations/`
- Copy to `priv/repo/migrations/portable/`
- Gets synced to public mirror

**Personal-data migrations** (seed data, personal fixtures):
- Add to `priv/repo/migrations/` only
- Never copied to `portable/`
- Jenkins sync filters these out

**Example:**
- Adding a new column to `resumes`: add to both `migrations/` and `migrations/portable/`
- Seeding test resumes for personal pipeline: `migrations/` only

### Jenkins Sync Process (Future)

On commit to `main`:
1. Clone private repo
2. Strip `priv/repo/migrations/` (keep portable only)
3. Run tests
4. Push to `portable_job_applications` mirror
5. Build Docker image and push to ghcr.io

Portable users run migrations from `migrations/portable/` automatically in Release.migrate() task.

---

## Database Configuration

The bot connects to **postgres-vector** on Kubernetes NodePort **30003**. Configuration is centralized and automatic — Salt/launchd set all required environment variables.

**Details**:

### 1. Salt Pillar (bot_army_infra)

Set in `pillar/common.sls` for all bots:
```yaml
deployment:
  database:
    host: localhost
    port: 30003        # postgres-vector NodePort
    user: postgres
```

### 2. Runtime Environment

Bot reads at startup from (in order):
1. `BOT_ARMY_JOB_APPLICATIONS_DB_NAME` environment variable (bot-specific override)
2. `DATABASE_NAME` environment variable (common)
3. Fallback default: `"ergon_job_applications"`

**Set by Salt/launchd** in `/etc/bot_army/job_applications.env`:
```bash
DATABASE_HOST=localhost
DATABASE_PORT=30003
DATABASE_USER=postgres
DATABASE_PASSWORD=postgres        # From air-secrets.sls
DATABASE_NAME=ergon_job_applications
```

**Configured in** `config/runtime.exs` (priority: bot-specific > common > default):
```elixir
config :bot_army_job_applications, BotArmyJobApplications.Repo,
  database: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_NAME") ||
            System.get_env("DATABASE_NAME") ||
            "ergon_job_applications",
  hostname: System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_HOST") ||
            System.get_env("DATABASE_HOST") ||
            "localhost",
  port: String.to_integer(System.get_env("BOT_ARMY_JOB_APPLICATIONS_DB_PORT") ||
            System.get_env("DATABASE_PORT") ||
            "30003"),
```

### Database Schema

The bot uses Ecto migrations (portable + personal):
- **Portable migrations** (`priv/repo/migrations/portable/`): Schema-only, synced to public mirror
- **Personal migrations** (`priv/repo/migrations/`): Full set for private deployment

**Tables**:
- `resumes` — Resume identity, roles, skills
- `resume_roles` — Work history
- `resume_bullets` — Achievement bullets
- `resume_skills` — Technical skills
- `job_listings` — Job board listings
- `job_applications` — Application state machine
- `email_signals` — Email-detected interview signals

See `priv/repo/migrations/README.md` for migration strategy.

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

### Board Discovery & Ingestion Configuration

The bot uses a two-phase approach to keep job boards up to date:

**Phase 1A: Discover Boards (Local)**
- Run `make discover-boards` to test Greenhouse and Lever public APIs
- Returns list of active boards with job counts
- No database changes, no deployment needed
- Useful for understanding what boards are available

**Phase 1B: Sync Boards to Production (Update Salt Pillar)**
- Run `make sync-boards` to discover boards AND update Salt pillar
- Generates YAML configuration: `bot_army_infra/salt/pillar/job_applications.sls`
- Auto-commits changes with board count in message
- Requires: `bot_army_infra` sibling directory exists and is a git repo
- Next step: `cd ../bot_army_infra && git push origin main`
- Jenkins automatically deploys when push completes

**Available Make Targets:**
| Command | What It Does |
|---------|-------------|
| `make discover-boards` | List active boards + job counts (no changes) |
| `make discover-boards-yaml` | Same as above, output to /tmp/ingestion_boards.yaml |
| `make sync-boards-dry-run` | Preview what would be written to Salt pillar (no changes) |
| `make sync-boards` | Discover boards + update Salt pillar + auto-commit |

**Companies Tested:** 23 across AI/ML, DevTools, Infrastructure categories (hardcoded in `@companies` map)

**Implementation:** `lib/mix/tasks/discover_boards.ex` and `lib/mix/tasks/sync_boards_to_salt.ex`
- Uses Erlang `:inets` and `:httpc` (available in Mix environment)
- Tests Greenhouse: `https://boards-api.greenhouse.io/v1/boards/{token}/jobs`
- Tests Lever: `https://api.lever.co/v0/postings/{site}`
- 5-second timeout per board, continues on error

**Adding New Companies:**
1. Add tuple to `@companies` map: `{"CompanyName", "slug", "greenhouse" | "lever"}`
2. Test with `make discover-boards-yaml` to verify board exists
3. Run `make sync-boards` to push to production
4. Salt pillar auto-syncs to all minions

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
- **Typed LLM completion subjects:**
  - `events.llm.completion.job_applications.jd_analysis` → ArtifactHandler (extract JD tags)
  - `events.llm.completion.job_applications.cover_letter` → ArtifactHandler (generate cover letter)

**Pattern:**
```
events.llm.completion.{bot_name}.{request_type}
```
- `bot_name`: envelope `source` with `"bot_army_"` prefix stripped
- `request_type`: `source_metadata["source_domain"]` from the request

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

### TUI Management (Request/Reply)
**Subscribes (Request/Reply):**
- `job.resume.list` — list all resumes (request/reply)
- `job.resume.get` — get single resume by ID (request/reply)
- `job.resume.create` — create new resume from TUI (request/reply)
- `job.resume.update` — update existing resume from TUI (request/reply)
- `job.resume.delete` — delete resume (request/reply)

**Request Payloads:**

#### job.resume.list (empty request)
```json
{}
```
**Response:**
```json
{
  "ok": true,
  "resumes": [
    {
      "id": "uuid",
      "identity": {"name": "...", "summary": "..."},
      "created_at": "ISO8601"
    }
  ]
}
```

#### job.resume.get
```json
{"resume_id": "uuid"}
```
**Response:**
```json
{
  "ok": true,
  "resume": {
    "id": "uuid",
    "identity": {"name": "...", "summary": "..."},
    "roles": [
      {
        "id": "uuid",
        "title": "...",
        "company": "...",
        "start_date": "YYYY-MM",
        "end_date": "YYYY-MM",
        "bullets": [{"text": "..."}]
      }
    ],
    "skills": [
      {
        "id": "uuid",
        "name": "...",
        "proficiency": "expert|advanced|intermediate|beginner",
        "years": 3
      }
    ]
  }
}
```

#### job.resume.create
```json
{
  "identity": {"name": "...", "summary": "..."},
  "roles": [
    {
      "title": "...",
      "company": "...",
      "start_date": "YYYY-MM",
      "end_date": "YYYY-MM",
      "bullets": ["text1", "text2"]
    }
  ],
  "skills": [
    {
      "name": "...",
      "proficiency": "expert|advanced|intermediate|beginner",
      "years": 3
    }
  ]
}
```
**Response:**
```json
{"ok": true, "resume_id": "uuid"}
```

#### job.resume.update
```json
{
  "resume_id": "uuid",
  "identity": {"name": "...", "summary": "..."},
  "roles": [
    {
      "title": "...",
      "company": "...",
      "start_date": "YYYY-MM",
      "end_date": "YYYY-MM",
      "bullets": ["text1", "text2"]
    }
  ],
  "skills": [
    {
      "name": "...",
      "proficiency": "expert|advanced|intermediate|beginner",
      "years": 3
    }
  ]
}
```
**Response:**
```json
{"ok": true}
```

#### job.resume.delete
```json
{"resume_id": "uuid"}
```
**Response:**
```json
{"ok": true}
```

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
