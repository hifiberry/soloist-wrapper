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
export HOME=$(mktemp -d)

# 1. Unsupported architecture
cat > "$HOME/uname" <<'EOF'
#!/bin/sh
echo "sparc64"
EOF
chmod +x "$HOME/uname"
PATH="$HOME:$PATH" "$SCRIPT" >/dev/null 2>&1
check "unsupported architecture exits 2" 2 $?
rm "$HOME/uname"

# 2. Download failure (point at a URL that will not resolve)
sed 's|https://soloist-builds.spotifycdn.com|https://soloist-builds.invalid|' \
  "$SCRIPT" > "$HOME/soloist-fetch-badurl"
chmod +x "$HOME/soloist-fetch-badurl"
"$HOME/soloist-fetch-badurl" >/dev/null 2>&1
check "unreachable host exits 3" 3 $?

# 3. Archive without a soloist binary
SERVE=$(mktemp -d)
mkdir -p "$SERVE/junk" && echo hello > "$SERVE/junk/readme.txt"
tar -czf "$SERVE/soloist_release_arm64.tar.gz" -C "$SERVE" junk
(cd "$SERVE" && python3 -m http.server 18099 >/dev/null 2>&1) &
SERVER_PID=$!
sleep 1
sed -e 's|https://soloist-builds.spotifycdn.com|http://127.0.0.1:18099|' \
    -e "s|--proto '=https' --tlsv1.2||" \
    -e 's|uname -m|echo aarch64|' \
    "$SCRIPT" > "$HOME/soloist-fetch-local"
chmod +x "$HOME/soloist-fetch-local"
"$HOME/soloist-fetch-local" >/dev/null 2>&1
check "archive without soloist exits 4" 4 $?
kill $SERVER_PID 2>/dev/null

exit $FAILURES
