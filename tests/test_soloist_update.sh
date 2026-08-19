#!/bin/bash
# Exercises soloist-update's branches without touching Spotify's CDN and
# without needing a real /usr/bin/soloist-fetch (which requires root to
# install and network access to run for real). soloist-update always calls
# soloist-fetch via the fixed absolute path /usr/bin/soloist-fetch, so a
# sed-substituted copy pointing that at a local mock is used instead -- the
# same dependency-injection style as tests/test_soloist_fetch.sh uses for
# soloist-fetch's own BASE_URL.
# shellcheck disable=SC2329,SC2317 # setup_*/helper functions are invoked
# indirectly by name via run_case's "$setup_fn" argument; shellcheck's static
# analysis cannot see that (SC2329 on 0.11.x, SC2317 on 0.10.x).
set -u
FAILURES=0

SCRIPT="$(dirname "$0")/../scripts/soloist-update"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Mock soloist-fetch: records that it was called (via $MOCK_MARKER, which
# survives the real script's "exec /usr/bin/soloist-fetch" because exec
# preserves the environment) and exits 0, as a successful refresh would.
MOCK_FETCH="$WORKDIR/mock-soloist-fetch"
cat > "$MOCK_FETCH" <<'EOF'
#!/bin/sh
touch "$MOCK_MARKER"
exit 0
EOF
chmod +x "$MOCK_FETCH"

UNDER_TEST="$WORKDIR/soloist-update-under-test"
sed "s|/usr/bin/soloist-fetch|${MOCK_FETCH}|g" "$SCRIPT" > "$UNDER_TEST"
chmod +x "$UNDER_TEST"

days_ago() {
  python3 -c "
import datetime, sys
d = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=int(sys.argv[1]))
print(d.strftime('%Y-%m-%d'))
" "$1"
}

# Installs an executable (fake) soloist binary under $CASE_HOME.
install_binary() {
  mkdir -p "$CASE_HOME/.local/bin"
  cat > "$CASE_HOME/.local/bin/soloist" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$CASE_HOME/.local/bin/soloist"
}

# Writes version.json under $CASE_HOME with the given build_date/source.
write_version_json() {
  local build_date="$1" source="$2"
  mkdir -p "$CASE_HOME/.local/share/soloist"
  cat > "$CASE_HOME/.local/share/soloist/version.json" <<EOF
{
  "version": "soloist 1.0.0 build 0 (${build_date//-/}) (test) (linux/test)",
  "build_date": "${build_date}",
  "build_date_source": "${source}",
  "installed_at": "2026-01-01T00:00:00Z",
  "arch": "arm64"
}
EOF
}

# Runs soloist-update under a fresh, isolated $HOME and reports whether it
# exited 0 and whether the mock fetch was invoked.
run_case() {
  local name="$1" expect_update="$2" setup_fn="$3"
  CASE_HOME=$(mktemp -d)
  MOCK_MARKER="$CASE_HOME/.fetch-called"
  export MOCK_MARKER
  "$setup_fn"

  local status
  HOME="$CASE_HOME" "$UNDER_TEST" >"$CASE_HOME/.output" 2>&1
  status=$?

  local called="no"
  [ -f "$MOCK_MARKER" ] && called="yes"

  if [ "$status" -ne 0 ]; then
    echo "FAIL - $name (soloist-update exited $status, expected 0; output follows)"
    sed 's/^/       /' "$CASE_HOME/.output"
    FAILURES=$((FAILURES + 1))
  elif [ "$called" != "$expect_update" ]; then
    echo "FAIL - $name (expected fetch-called=$expect_update, got $called; output follows)"
    sed 's/^/       /' "$CASE_HOME/.output"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok   - $name"
  fi

  rm -rf "$CASE_HOME"
}

# 1. Fresh "parsed" build (well inside the 60-day threshold) -> no update.
setup_fresh_parsed() {
  install_binary
  write_version_json "$(days_ago 5)" "parsed"
}
run_case "fresh parsed build: no update" "no" setup_fresh_parsed

# 2. Stale "parsed" build (past the 60-day threshold) -> update.
setup_stale_parsed() {
  install_binary
  write_version_json "$(days_ago 100)" "parsed"
}
run_case "stale parsed build: update" "yes" setup_stale_parsed

# 3. "fallback" build, 40 days old: fresh by the parsed 60-day threshold but
# stale by the fallback 30-day threshold -> MUST update. This is the case
# that proves build_date_source is actually consulted, not decoration -- a
# "parsed" build of the same age would be left alone (case 1/2 establish the
# 60-day parsed cutoff).
setup_stale_fallback_fresh_by_parsed() {
  install_binary
  write_version_json "$(days_ago 40)" "fallback"
}
run_case "fallback build stale-by-fallback/fresh-by-parsed threshold: update" "yes" setup_stale_fallback_fresh_by_parsed

# 4. No binary at all -> nothing installed, no update.
setup_no_binary() {
  : # $CASE_HOME starts empty; nothing to do.
}
run_case "no binary installed: no update" "no" setup_no_binary

# 5. Binary present but no version.json (an interrupted fetch, or anything
# that clears Soloist's own data dir -- see Finding 2) -> update.
setup_binary_no_version_json() {
  install_binary
}
run_case "binary present, no version.json: update" "yes" setup_binary_no_version_json

# 6. Garbage/unparseable build_date -> update to be safe.
setup_garbage_date() {
  install_binary
  write_version_json "not-a-date" "parsed"
}
run_case "garbage build_date: update" "yes" setup_garbage_date

# 7. Future build_date (clock skew or corrupt version.json) -> update.
setup_future_date() {
  install_binary
  write_version_json "2099-01-01" "parsed"
}
run_case "future build_date: update" "yes" setup_future_date

# 8. Expiry flag present -> update, regardless of version.json's age. Also
# requires an installed binary: start-soloist only ever writes this flag
# after actually running the daemon, so "flag present, no binary" is not a
# reachable state -- and without a binary, soloist-update's binary-is-the-
# source-of-truth check (case 4/5) would otherwise mask this case.
setup_expiry_flag() {
  install_binary
  write_version_json "$(days_ago 5)" "parsed"
  mkdir -p "$CASE_HOME/.local/share/soloist"
  touch "$CASE_HOME/.local/share/soloist/expired"
}
run_case "expiry flag present: update" "yes" setup_expiry_flag

exit $FAILURES
