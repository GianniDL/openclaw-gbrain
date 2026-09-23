#!/usr/bin/env bash
# Entrypoint for openclaw-render-template-gbrain (PGLite engine).
#
# Runs on every container start. The expensive step (gbrain init schema +
# skills seed) is idempotent and short-circuits on reboots via the
# config.json sentinel on the persistent disk. Failures here exit non-zero
# so Render surfaces the problem instead of starting AlphaClaw against a
# half-initialized brain.

set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ---------------------------------------------------------------------------
# 1. Validate required environment.
# ---------------------------------------------------------------------------
require_env() {
  if [ -z "${!1:-}" ]; then
    log "ERROR: $1 is not set. See README.md for required env vars."
    exit 1
  fi
}

require_env OPENAI_API_KEY
require_env ANTHROPIC_API_KEY
require_env ALPHACLAW_ROOT_DIR
require_env GBRAIN_HOME

mkdir -p "$ALPHACLAW_ROOT_DIR"
SKILLS_DIR="${ALPHACLAW_ROOT_DIR}/.openclaw/skills"
mkdir -p "$SKILLS_DIR"
# gbrain treats GBRAIN_HOME as a parent dir and appends '.gbrain' itself.
# Create the resolved configDir so first-run writes never race a missing dir.
mkdir -p "$GBRAIN_HOME/.gbrain"

# ---------------------------------------------------------------------------
# 2. Initialize the GBrain brain (idempotent: safe to re-run).
#    PGLite runs Postgres in-process (WASM via @electric-sql/pglite) against
#    a single file on the persistent disk. pgvector and pg_trgm ship with
#    PGLite as bundled extensions, so no external Postgres or CREATE
#    EXTENSION step is needed.
#
#    Config and the brain file both live under $GBRAIN_HOME/.gbrain on
#    /data, so they persist across deploys.
# ---------------------------------------------------------------------------
if [ ! -f "$GBRAIN_HOME/.gbrain/config.json" ]; then
  log "Running first-time gbrain init (PGLite engine)..."
  gbrain init --pglite --non-interactive
else
  log "gbrain config found at $GBRAIN_HOME/.gbrain/config.json, skipping init."
fi

# ---------------------------------------------------------------------------
# 3. Seed the GBrain skill pack into the AlphaClaw skills directory.
#    Only copy on first boot or when the seed adds new skills (cp -n never
#    overwrites user edits, so updates to existing skills require an explicit
#    operator action). Make brain repo backup connections too.
# ---------------------------------------------------------------------------
if [ -d /app/skills-seed ]; then
  if [ "${GBRAIN_SKILLS_RESEED:-0}" = "1" ]; then
    log "GBRAIN_SKILLS_RESEED=1 — refreshing GBrain skills (overwrites edits)..."
    cp -rf /app/skills-seed/* "$SKILLS_DIR/" || true
  else
    log "Seeding GBrain skills into $SKILLS_DIR..."
    cp -rn /app/skills-seed/* "$SKILLS_DIR/" || true
  fi
fi

if [ -n "${BRAIN_REPO:-}" ]; then
  BRAIN_DIR="${ALPHACLAW_ROOT_DIR}/brain"
  if [ ! -d "$BRAIN_DIR/.git" ]; then
    log "Cloning brain repo into $BRAIN_DIR..."
    git clone "https://${GITHUB_TOKEN}@github.com/${BRAIN_REPO}.git" "$BRAIN_DIR"
  else
    log "Brain repo present; pulling..."
    git -C "$BRAIN_DIR" pull --ff-only || log "WARN: brain pull failed"
  fi
  gbrain sync --repo "$BRAIN_DIR" || log "WARN: gbrain sync failed"
fi

# ---------------------------------------------------------------------------
# 4. Hand off to AlphaClaw.
# ---------------------------------------------------------------------------
log "Starting AlphaClaw..."
exec "$@"
