# Fly.io Deployment Guide

> **Audience:** Project maintainers deploying to production
>
> **Budget:** ~$5/month (Fly.io app + Fly Postgres)

## Cost Protection

**⚠️ Fly.io has NO spending limits.** They bill pay-as-you-go.

### How to Prevent Overpaying

1. **Prepaid Billing** (Required for non-profit)
   ```
   Fly.io Dashboard → Billing → Add Credits → $25 minimum
   ```
   - Usage deducted from this balance
   - When credits run out → services stop
   - **This is the ONLY way to hard-cap spending**

2. **Monitor Monthly**
   ```bash
   fly dashboard  # Check current month-to-date
   ```

---

## Deployment Setup

### Prerequisites

```bash
# Install Fly CLI
curl -L https://fly.io/install.sh | sh

# Login
fly auth login
```

### Step 1: Create App

```bash
cd waw_trams
fly launch --no-deploy
```

When prompted:
- App name: `waw-trams` (or your choice)
- Region: `ams` (Amsterdam) — closest to Warsaw
- PostgreSQL: **No** (we'll create it separately with PostGIS)

### Step 2: Create Postgres with PostGIS

```bash
# Create minimal Postgres instance
fly postgres create \
  --name waw-trams-db \
  --region ams \
  --vm-size shared-cpu-1x \
  --initial-cluster-size 1 \
  --volume-size 1

# Attach to app (sets DATABASE_URL automatically)
fly postgres attach waw-trams-db
```

### Step 3: Enable PostGIS

```bash
# Connect to database
fly postgres connect -a waw-trams-db
```

In the psql prompt:
```sql
CREATE EXTENSION postgis;
\q
```

### Step 4: Set Secrets

```bash
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)
```

### Step 5: Deploy

```bash
fly deploy
```

### Step 6: Initialize Data

```bash
# Run migrations (should happen automatically, but just in case)
fly ssh console -C "/app/bin/waw_trams eval 'WawTrams.Release.migrate()'"

# Seed spatial data (stops, intersections, terminals)
fly ssh console -C "/app/bin/waw_trams eval 'WawTrams.Release.seed()'"
```

---

## Cost Breakdown

| Component | Spec | Cost |
|-----------|------|------|
| App | 1x shared-cpu-1x, 256MB | ~$1.94/month |
| Postgres | 1x shared-cpu-1x, 256MB | ~$1.94/month |
| Storage | 1GB volume | ~$0.15/month |
| IPv4 | Shared (default) | Free |
| **Total** | | **~$4/month** |

Free tier covers most of this, so actual cost may be **$0-3/month**.

---

## Useful Commands

```bash
# Check app status
fly status

# View logs
fly logs

# SSH into app
fly ssh console

# Check database
fly postgres connect -a waw-trams-db

# Scale memory if needed (adds ~$2/month)
fly scale memory 512

# Check billing
fly dashboard
```

---

## CI/CD with GitHub Actions

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: superfly/flyctl-actions/setup-flyctl@master
      - run: flyctl deploy --remote-only
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

Get deploy token:
```bash
fly tokens create deploy -x 999999h
```

Add to GitHub: Repository → Settings → Secrets → New → `FLY_API_TOKEN`

---

## Troubleshooting

### App won't start

```bash
# Check logs
fly logs

# Common issue: not enough memory
fly scale memory 512
```

### Database connection failed

```bash
# Verify attachment
fly secrets list | grep DATABASE_URL

# Re-attach if needed
fly postgres attach waw-trams-db
```

### PostGIS not working

```bash
fly postgres connect -a waw-trams-db
# Then: CREATE EXTENSION IF NOT EXISTS postgis;
```

### Slow first request

Normal with `auto_stop_machines = 'suspend'`. First request after idle takes ~1-2s.

For always-on (slightly higher cost), edit `fly.toml`:
```toml
auto_stop_machines = false
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Deploy | `fly deploy` |
| Logs | `fly logs` |
| SSH | `fly ssh console` |
| DB console | `fly postgres connect -a waw-trams-db` |
| Restart | `fly apps restart` |
| Scale memory | `fly scale memory 512` |
| Check cost | `fly dashboard` |
