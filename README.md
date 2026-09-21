# pi-offload

A Claude Code plugin that offloads I/O-heavy work to a **local [pi](https://pi.dev) agent**,
keeping large file contents and boilerplate generation out of Claude's context.

A port of [shunt](https://github.com/sorantis/portal-ai-plugins/tree/add-shunt-claude/plugins/shunt),
with the Portal/AiKA transport replaced by a local `pi` process. No network call, no server-side
modes to create, no payload size ceiling — the message goes in on stdin.

## How it works

Three layers, from hard gate to soft suggestion:

1. **Hooks** block Claude from reading large files and redirect to the bulk-reader skill
2. **Scripts** handle the `pi` invocation and output cleanup
3. **Skills** tell Claude when and how to call the scripts

Claude never assembles a shell pipeline from prose. It calls a script with named arguments.

## Prerequisites

- [`pi`](https://pi.dev) on `PATH`, with at least one working provider
- [`jq`](https://jqlang.org) — `brew install jq` (used by the hooks to parse tool input)

Check what your install offers:

```bash
pi --list-models
```

```text
provider      model                context  max-out  thinking  images
dgx-spark     qwen3.8-flash-next   262.1K   8.2K     no        no
omlx          Qwen3.8-27B-4bit     262.1K   131.1K   no        yes
```

## Install

```bash
claude plugin install /path/to/pi-offload
```

## Configuration

All settings are environment variables — add them to the `env` block in `.claude/settings.json`.
Models use pi's own `provider/id` form.

| Variable | Default | Purpose |
|----------|---------|---------|
| `PI_OFFLOAD_READER_MODEL` | `dgx-spark/qwen3.8-flash-next` | Model for `bulk-read` — long context, fast, cheap |
| `PI_OFFLOAD_WRITER_MODEL` | `omlx/Qwen3.8-27B-4bit` | Model for `code-write` — larger, better output |
| `PI_OFFLOAD_MIN_LINES` | `350` | Line count above which the hooks block and redirect |
| `PI_OFFLOAD_BIN` | `pi` | Path to the pi binary |

```json
{
  "env": {
    "PI_OFFLOAD_READER_MODEL": "dgx-spark/qwen3.8-flash-next",
    "PI_OFFLOAD_WRITER_MODEL": "omlx/Qwen3.8-27B-4bit",
    "PI_OFFLOAD_MIN_LINES": "350"
  }
}
```

The reader handles the whole file corpus, so pick the longest-context model you have. The writer
produces code, so pick the strongest one you are willing to wait for.

## Scripts

### bulk-read

Delegates file reading to the reader model. Files are wrapped in XML tags (`<file path="...">`)
for clear boundaries.

```bash
bulk-read --question "What does this service do?" --paths src/Service.java src/Handler.java
```

### code-write

Delegates boilerplate generation to the writer model. Strips markdown fences from output. Writes
directly to disk via `--target`, otherwise stdout. `--reference` is required — without a file to
match patterns against, the worker generates context-free code that fits nothing in the project.

```bash
code-write --spec "Write tests for UserService" --reference tests/OrderTest.java --target tests/UserTest.java
code-write --spec "Generate a config stub" --reference config/existing.yaml
```

### One shot per call

Every delegation is one ephemeral `pi` run: no tools, no session, no `AGENTS.md`/`CLAUDE.md`
discovery, so the worker answers from the message alone. Nothing carries across calls — ask again
with the same `--paths`. Re-sending the corpus is free where it matters, because it goes to the
local model and never enters Claude's context.

## Hooks

### check-file-size (Read hook)

Blocks full-file `Read` on files over `PI_OFFLOAD_MIN_LINES`. Allows through: targeted reads
(`offset` or `limit` set), files under the threshold, nonexistent files.

### check-bash-read (Bash hook)

Catches `cat`/`head`/`tail`/`less`/`more` on large files. Allows through: piped commands
(`cat file | grep`), redirections (`cat file > out`), non-read commands.

## What doesn't get delegated

- **Debugging** — needs Claude's reasoning, not a summary
- **Editing** — Claude needs exact content in context; use targeted reads (offset/limit)
- **Small files** — delegation overhead exceeds the savings under 350 lines
- **Architectural decisions** — judgment calls stay on Claude

## Self-check

```bash
./test.sh
```

Exercises hook routing and script plumbing against a stubbed `pi` — no model calls, runs in a
second. Run it under `/bin/bash` too (3.2 on macOS, which is what hooks actually execute under).

## Known limitations

- **No enforcement for code-writer** — only the reader has hook enforcement. The writer relies on
  Claude recognising when to use it via the skill description.
- **Local models are slow to start** — a cold MLX load can take minutes on first call. Claude Code's
  own Bash timeout may fire before a large generation finishes; keep specs small, or warm the model.
- **Quality is the local model's** — verify line numbers and exact values from `bulk-read` before
  using them in edits, and review `code-write` output.
