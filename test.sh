#!/bin/bash
# Self-check: hook routing + script plumbing against a stubbed pi. No model calls.
#
# Hooks run under whatever /bin/bash is, which on macOS is 3.2 — build every
# JSON payload into a variable before use rather than nesting quotes inside
# command substitution, which 3.2 mangles silently.
cd "$(dirname "$0")" || exit 1
fails=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

seq 1 500 > "$tmp/big.txt"
seq 1 10  > "$tmp/small.txt"

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fails=$((fails+1)); fi
}

hook() { # hook-name json -> decision
  local out
  out=$(printf '%s' "$2" | "hooks/$1") || { echo "hook-error"; return; }
  printf '%s' "$out" | jq -r '.decision // "no-decision"'
}

# --- Read hook ---
j=$(printf '{"tool_input":{"file_path":"%s"}}' "$tmp/big.txt")
check "read: big file blocked" block "$(hook check-file-size "$j")"

j=$(printf '{"tool_input":{"file_path":"%s"}}' "$tmp/small.txt")
check "read: small file allowed" allow "$(hook check-file-size "$j")"

j=$(printf '{"tool_input":{"file_path":"%s","offset":1}}' "$tmp/big.txt")
check "read: offset allowed" allow "$(hook check-file-size "$j")"

j='{"tool_input":{"file_path":"/nope/x.txt"}}'
check "read: missing file allowed" allow "$(hook check-file-size "$j")"

j=$(printf '{"tool_input":{"file_path":"%s"}}' "$tmp/big.txt")
check "read: threshold raised allows" allow "$(PI_OFFLOAD_MIN_LINES=999 hook check-file-size "$j")"
check "read: threshold lowered blocks" block "$(PI_OFFLOAD_MIN_LINES=5 hook check-file-size "$j")"

# --- Bash hook ---
j=$(printf '{"tool_input":{"command":"cat %s"}}' "$tmp/big.txt")
check "bash: cat big blocked" block "$(hook check-bash-read "$j")"

j=$(printf '{"tool_input":{"command":"cat -n %s"}}' "$tmp/big.txt")
check "bash: cat -n big blocked" block "$(hook check-bash-read "$j")"

j=$(printf '{"tool_input":{"command":"cat %s | grep 4"}}' "$tmp/big.txt")
check "bash: piped allowed" allow "$(hook check-bash-read "$j")"

j=$(printf '{"tool_input":{"command":"cat %s > /tmp/out"}}' "$tmp/big.txt")
check "bash: redirect allowed" allow "$(hook check-bash-read "$j")"

j=$(printf '{"tool_input":{"command":"cat %s"}}' "$tmp/small.txt")
check "bash: cat small allowed" allow "$(hook check-bash-read "$j")"

j='{"tool_input":{"command":"git status"}}'
check "bash: non-read allowed" allow "$(hook check-bash-read "$j")"

# --- Scripts against a stubbed pi ---
cat > "$tmp/pi" <<'STUB'
#!/bin/bash
# Echoes back the model it was asked for and the byte count it received.
model=""
while [ $# -gt 0 ]; do case "$1" in --model) model="$2"; shift 2 ;; *) shift ;; esac; done
bytes=$(wc -c | tr -d ' ')
echo "STUB model=$model bytes=$bytes"
STUB
chmod +x "$tmp/pi"
export PI_OFFLOAD_BIN="$tmp/pi"

rc() { "$@" >/dev/null 2>&1; echo $?; }

check "bulk-read: missing --question fails" 1 "$(rc scripts/bulk-read --paths "$tmp/small.txt")"
check "bulk-read: missing --paths fails"    1 "$(rc scripts/bulk-read --question q)"
check "bulk-read: bad path fails"           1 "$(rc scripts/bulk-read --question q --paths /nope.txt)"
check "code-write: missing --spec fails"      1 "$(rc scripts/code-write --reference "$tmp/small.txt")"
check "code-write: missing --reference fails" 1 "$(rc scripts/code-write --spec s)"
check "code-write: bad reference fails"       1 "$(rc scripts/code-write --spec s --reference /nope.txt)"
check "preflight: missing pi fails"           1 "$(PI_OFFLOAD_BIN=/nope/pi rc scripts/bulk-read --question q --paths "$tmp/small.txt")"

out=$(PI_OFFLOAD_READER_MODEL=r/1 scripts/bulk-read --question q --paths "$tmp/small.txt" 2>/dev/null)
check "bulk-read: uses reader model" "STUB model=r/1" "$(printf '%s' "$out" | cut -d' ' -f1-2)"

out=$(PI_OFFLOAD_WRITER_MODEL=w/1 scripts/code-write --spec s --reference "$tmp/small.txt" 2>/dev/null)
check "code-write: uses writer model" "STUB model=w/1" "$(printf '%s' "$out" | cut -d' ' -f1-2)"

scripts/code-write --spec s --reference "$tmp/small.txt" --target "$tmp/out.txt" >/dev/null 2>&1
check "code-write: writes target" 1 "$(wc -l < "$tmp/out.txt" | tr -d ' ')"

echo
[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
