# Company Configuration for Job Board Discovery

Companies are defined in `companies.yaml` and can be edited without recompiling the bot.

## Format

```yaml
category_name:
  Company Display Name: {slug: url-slug, platform: greenhouse|lever}
```

## Adding a Company

1. **Find the company's job board**
   - Greenhouse: Look for `https://boards.greenhouse.io/[slug]/`
   - Lever: Look for `https://jobs.lever.co/[slug]`

2. **Edit `companies.yaml`**
   ```yaml
   ai:
     OpenAI: {slug: openai, platform: greenhouse}
     Stability AI: {slug: stability, platform: lever}
   ```

3. **Test the discovery**
   ```bash
   make discover-boards --categories ai
   ```

4. **Sync to production** (if configured)
   ```bash
   make sync-boards
   ```

## Removing a Company

Simply delete the line or comment it out:

```yaml
ai:
  Anthropic: {slug: anthropic, platform: greenhouse}
  # OpenAI: {slug: openai, platform: greenhouse}  # Removed
  Hugging Face: {slug: huggingface, platform: greenhouse}
```

## Categories

The default categories are:

- **ai** - AI/ML companies (Anthropic, Hugging Face, etc.)
- **devtools** - Developer tools (Vercel, Netlify, etc.)
- **infra** - Infrastructure companies (Cloudflare, HashiCorp, etc.)

You can add new categories as needed:

```yaml
security:
  Wiz: {slug: wiz, platform: greenhouse}
  CrowdStrike: {slug: crowdstrike, platform: greenhouse}
```

## Discovering by Category

```bash
# Discover all companies
make discover-boards

# Discover specific categories
make discover-boards --categories ai,devtools

# See YAML output
make discover-boards-yaml
```

## Verify a Company's URL

Before adding a company, verify the board exists:

**Greenhouse**:
```bash
curl https://boards-api.greenhouse.io/v1/boards/anthropic/jobs?content=false | jq .
```

**Lever**:
```bash
curl https://api.lever.co/v0/postings/anthropic?mode=json | jq .
```

If it returns job data, the company exists and can be added!

## Example: Adding a New Category

```yaml
quantum:
  IBM: {slug: ibm, platform: greenhouse}
  IonQ: {slug: ionq, platform: greenhouse}
  Rigetti: {slug: rigetti, platform: greenhouse}
```

Then run:
```bash
make discover-boards --categories quantum
```
