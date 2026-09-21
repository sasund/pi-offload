#!/bin/bash
# Shared plumbing for the pi-offload delegation scripts.
#
# Every delegation is one ephemeral, tool-less pi run: the message goes in on
# stdin, the answer comes out on stdout. Nothing is stored, so each call stands
# alone. Re-sending a file corpus is free where it matters — it goes to the
# local worker model and never enters Claude's context.
#
# Models are configured per role, in pi's own "provider/id" form. List what
# your pi install offers with `pi --list-models`.

PI_BIN="${PI_OFFLOAD_BIN:-pi}"
PI_READER_MODEL="${PI_OFFLOAD_READER_MODEL:-dgx-spark/qwen3.8-flash-next}"
PI_WRITER_MODEL="${PI_OFFLOAD_WRITER_MODEL:-omlx/Qwen3.8-27B-4bit}"

pi_preflight() {
  command -v "$PI_BIN" >/dev/null 2>&1 && return 0
  echo "Error: '$PI_BIN' not found on PATH." >&2
  echo "  Install pi (https://pi.dev), or set PI_OFFLOAD_BIN to its path." >&2
  return 1
}

# Runs one ephemeral turn and prints the answer.
#   $1 model (provider/id)
#   $2 system prompt
#   $3 file holding the message
#
# The worker runs with no tools and no context-file discovery: it answers from
# the message alone, so it can't wander the repo or inherit CLAUDE.md.
pi_invoke() {
  local model="$1" system="$2" message_file="$3"
  local stderr_file answer rc err

  stderr_file=$(mktemp)
  answer=$("$PI_BIN" -p -nt -nc -ns --no-session \
    --model "$model" --system-prompt "$system" < "$message_file" 2>"$stderr_file")
  rc=$?
  err=$(cat "$stderr_file"; rm -f "$stderr_file")

  if [ "$rc" -ne 0 ]; then
    echo "Error: pi failed (exit $rc) for model '$model'." >&2
    [ -n "$err" ] && printf '%s\n' "$err" >&2
    echo "  Check the model is available: $PI_BIN --list-models" >&2
    return 1
  fi

  if [ -z "$answer" ]; then
    echo "Error: pi returned an empty answer for model '$model'." >&2
    [ -n "$err" ] && printf '%s\n' "$err" >&2
    return 1
  fi

  printf '%s\n' "$answer"
}

# mktemp with cleanup on script exit. Usage: pi_tmpfile <varname>
PI_TMPFILES=()
pi_tmpfile() {
  local f
  f=$(mktemp) || return 1
  PI_TMPFILES+=("$f")
  trap 'rm -f "${PI_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}
