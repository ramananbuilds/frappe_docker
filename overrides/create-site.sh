#!/bin/bash
# create-site.sh — idempotent first-site creation for the Studio Lite Frappe stack.
#
# Addresses Notion runbook §18 / §27 ("planned, not implemented"): a fresh Coolify
# deploy used to bring up MariaDB + the Frappe runtime but never create a site, so
# the migrator logged "No sites found, skipping migration" and the stack served 404s.
#
# Design constraints (from runbook §27):
#   - idempotent            → safe on every redeploy
#   - non-destructive        → never resets or drops a database
#   - site-existence check   → exits 0 when a site already exists
#   - configurable site name → SITE_NAME env var
#   - admin password via deployment config → ADMIN_PASSWORD env var
#   - never touches the existing production site
#
# Multi-domain support: SITE_ALIASES is a comma-separated list of extra hostnames
# that are symlinked to the site directory. Frappe resolves a request's site by
# DIRECTORY NAME (nginx sets X-Frappe-Site-Name from $host), so an alias needs a
# symlink in sites/ — editing site_config host_name does nothing.
#
# Exit codes: 0 = site exists or was created OK. Non-zero = hard failure, which
# blocks the migrator (service_completed_successfully) and therefore the backend.

set -uo pipefail

SITES_PATH="${SITES_PATH:-sites}"
SITE_NAME="${SITE_NAME:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
SITE_ALIASES="${SITE_ALIASES:-}"
APPS_TO_INSTALL="${APPS_TO_INSTALL:-erpnext hrms crm business_suite_branding}"

log() { echo "[create-site] $*"; }
fail() { echo "[create-site] ERROR: $*" >&2; exit 1; }

# Resolve SITES_PATH to an ABSOLUTE path before it is used for symlink targets.
# A relative "sites" would make every alias a relative symlink, which silently
# breaks when read from a different working directory (nginx workers, docker exec).
SITES_PATH="$(cd "$SITES_PATH" 2>/dev/null && pwd -P)" \
  || fail "SITES_PATH '$SITES_PATH' does not exist"

# ---- 1. Idempotency: does any site already exist? -----------------------------
existing_site() {
  find "$SITES_PATH" -mindepth 2 -maxdepth 2 -name site_config.json 2>/dev/null \
    | head -1 | xargs -r dirname | xargs -r basename
}

# Absolute target: a relative symlink like "sites/<site>" breaks the moment the
# link is read from a different working directory (docker exec, nginx worker).
# Compare the RAW link text against the absolute target — `readlink -f` is useless
# here because it resolves a relative link against the link's own directory and
# would report a broken relative link as already-correct.
ensure_alias() {
  local site="$1" alias="$2"
  local target="$SITES_PATH/$site"
  local current
  current=$(readlink "$SITES_PATH/$alias" 2>/dev/null || echo "")
  if [ -n "$current" ] && [ "$current" = "$target" ]; then
    log "  alias '$alias' already linked"
    return 0
  fi
  ln -sfn "$target" "$SITES_PATH/$alias" \
    && log "  alias '$alias' -> $site (repaired)"
}

if EXISTING=$(existing_site) && [ -n "$EXISTING" ]; then
  log "Site '$EXISTING' already exists — nothing to do."

  # Still reconcile aliases: cheap, idempotent, and self-heals a deleted link.
  if [ -n "$SITE_ALIASES" ]; then
    for alias in $(echo "$SITE_ALIASES" | tr ',' ' '); do
      alias=$(echo "$alias" | xargs)
      [ -z "$alias" ] && continue
      ensure_alias "$EXISTING" "$alias"
    done
  fi
  exit 0
fi

# ---- 2. No site: create one, but only if configured ---------------------------
if [ -z "$SITE_NAME" ]; then
  log "No site found and SITE_NAME is unset — skipping creation (set SITE_NAME to automate this)."
  exit 0
fi

[ -z "$ADMIN_PASSWORD" ] && fail "SITE_NAME is set but ADMIN_PASSWORD is empty."
[ -z "$DB_ROOT_PASSWORD" ] && fail "SITE_NAME is set but DB_ROOT_PASSWORD is empty (MariaDB root password)."

log "No site found. Creating '$SITE_NAME'..."

# DB root password is needed by bench to create the database + app user.
export MYSQL_ROOT_PASSWORD="$DB_ROOT_PASSWORD"

if ! bench new-site "$SITE_NAME" \
      --db-root-password "$DB_ROOT_PASSWORD" \
      --admin-password "$ADMIN_PASSWORD" \
      --mariadb-root-password "$DB_ROOT_PASSWORD" \
      --db-name "${DB_NAME_PREFIX:-_}${SITE_NAME//[^a-zA-Z0-9]/_}" \
      --no-mariadb-socket; then
  fail "bench new-site failed for '$SITE_NAME'. Leaving existing volumes untouched."
fi

log "Site created. Installing apps: $APPS_TO_INSTALL"
for app in $APPS_TO_INSTALL; do
  bench --site "$SITE_NAME" install-app "$app" || fail "install-app $app failed"
done

# ---- 3. Aliases --------------------------------------------------------------
if [ -n "$SITE_ALIASES" ]; then
  for alias in $(echo "$SITE_ALIASES" | tr ',' ' '); do
    alias=$(echo "$alias" | xargs)
    [ -z "$alias" ] && continue
    ensure_alias "$SITE_NAME" "$alias"
  done
fi

log "Done. Site '$SITE_NAME' is ready."
