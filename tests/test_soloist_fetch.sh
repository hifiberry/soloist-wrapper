#!/bin/bash
# Exercises soloist-fetch's failure paths without touching Spotify's CDN.
set -u
FAILURES=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name (expected exit $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
  fi
}

SCRIPT="$(dirname "$0")/../scripts/soloist-fetch"
HOME=$(mktemp -d)
export HOME

# 1. Unsupported architecture
cat > "$HOME/uname" <<'EOF'
#!/bin/sh
echo "sparc64"
EOF
chmod +x "$HOME/uname"
PATH="$HOME:$PATH" "$SCRIPT" >/dev/null 2>&1
check "unsupported architecture exits 2" 2 $?
rm "$HOME/uname"

# 2. Download failure: no route to the CDN at all (curl exit 6, "could not
# resolve host") must map to our exit 3 ("no network"), not the generic
# download-failure code.
sed 's|https://soloist-builds.spotifycdn.com|https://soloist-builds.invalid|' \
  "$SCRIPT" > "$HOME/soloist-fetch-badurl"
chmod +x "$HOME/soloist-fetch-badurl"
"$HOME/soloist-fetch-badurl" >/dev/null 2>&1
check "unreachable host exits 3" 3 $?

# 3. Local environment failure: ~/.local exists as a plain file, so
# "mkdir -p ~/.local/bin" cannot succeed. Must map to exit 5 ("your device"),
# distinct from a broken/unreachable download.
LOCALFAIL_HOME=$(mktemp -d)
touch "$LOCALFAIL_HOME/.local"
HOME="$LOCALFAIL_HOME" "$SCRIPT" >/dev/null 2>&1
check "unwritable ~/.local exits 5" 5 $?
rm -rf "$LOCALFAIL_HOME"

# 4 & 5: serve a real (small, fake) archive over HTTP so the network path
# runs for real without touching Spotify's CDN. Uses an ephemeral port
# (0 -> "let the OS pick one") and polls the server's own log for the port
# it bound instead of a fixed sleep, so this can't race a slow host and
# can't collide with a concurrent test run on a fixed port.
SERVE=$(mktemp -d)
mkdir -p "$SERVE/junk" && echo hello > "$SERVE/junk/readme.txt"
tar -czf "$SERVE/soloist_release_arm64.tar.gz" -C "$SERVE" junk

SERVER_LOG=$(mktemp)
# No subshell here: python3 is started directly (via --directory) so $! is
# reliably the server's own PID, not a subshell PID that may already have
# exited by the time kill/wait run, which is how the old version of this
# test could strand a server process after a test run.
python3 -u -m http.server 0 --directory "$SERVE" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 50); do
  PORT=$(grep -oE 'port [0-9]+' "$SERVER_LOG" | head -1 | grep -oE '[0-9]+')
  [ -n "$PORT" ] && break
  sleep 0.1
done

if [ -z "$PORT" ]; then
  echo "FAIL - archive without soloist exits 4 (test HTTP server never started)"
  echo "FAIL - HTTP error (404) exits 6 (test HTTP server never started)"
  FAILURES=$((FAILURES + 2))
else
  sed -e "s|https://soloist-builds.spotifycdn.com|http://127.0.0.1:${PORT}|" \
      -e "s|--proto '=https' --tlsv1.2||" \
      -e 's|uname -m|echo aarch64|' \
      "$SCRIPT" > "$HOME/soloist-fetch-local"
  chmod +x "$HOME/soloist-fetch-local"

  # 4. Archive without a soloist binary
  "$HOME/soloist-fetch-local" >/dev/null 2>&1
  check "archive without soloist exits 4" 4 $?

  # 5. HTTP error reaching the CDN (curl --fail turns a 404 into curl exit
  # 22) must map to our exit 6 ("download failure"), distinct from exit 3
  # ("no network" -- the request DID reach a server, it was just refused).
  sed -e "s|https://soloist-builds.spotifycdn.com|http://127.0.0.1:${PORT}|" \
      -e "s|--proto '=https' --tlsv1.2||" \
      -e 's|uname -m|echo x86_64|' \
      "$SCRIPT" > "$HOME/soloist-fetch-404"
  chmod +x "$HOME/soloist-fetch-404"
  "$HOME/soloist-fetch-404" >/dev/null 2>&1
  check "HTTP error (404) exits 6" 6 $?
fi

kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
rm -f "$SERVER_LOG"
rm -rf "$SERVE"

exit $FAILURES
