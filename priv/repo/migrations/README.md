# Migrations

## Structure

```
migrations/
├── README.md
├── portable/                    ← Portable (public) migrations
│   ├── 20260311000001_create_resumes.exs
│   ├── 20260311000002_create_resume_roles.exs
│   ├── ...
│   └── 20260320000008_add_recommendation_fields_to_listings.exs
├── 20260311000001_create_resumes.exs  ← Also in this directory
├── 20260311000002_create_resume_roles.exs
├── ...
└── 20260320000008_add_recommendation_fields_to_listings.exs
```

## Discipline

**Schema-only migrations** (new tables, new columns for generic data):
- Add to `migrations/` (personal version)
- Copy to `migrations/portable/` (public version)

**Personal-data-specific migrations** (seed data, personal resume imports, test data):
- Add to `migrations/` only
- Never sync to `migrations/portable/`

## Jenkins Sync

Jenkins sync jobs (to be configured) will:
1. Clone the private repo
2. Run Ecto migrations from `migrations/portable/` only
3. Exclude `migrations/` (personal-only migrations)
4. Push clean version to public mirror

This ensures portable deployments get a working, complete schema without personal data.

## Current Status

All 8 migrations (as of 2026-03-20) are schema-only and portable. Both directories are in sync.
