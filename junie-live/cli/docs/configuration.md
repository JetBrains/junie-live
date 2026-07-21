# Configuration reference

`junie-live` uses one strict, versioned, presence-aware YAML schema at every
layer. This document is the field-by-field reference, the merge/precedence
rules, and the authentication alternatives with examples. The authoritative
Go types are in `internal/config/schema.go`; the built-in defaults are in
`internal/config/defaults.yaml`.

## Layers and precedence

Lowest to highest (a higher layer wins on a per-field basis):

1. **Embedded defaults** — baked into the binary (`internal/config/defaults.yaml`).
2. **Home config** — `~/.junie-live/config.yaml` (or `<--home>/config.yaml`).
3. **Workspace config** — `<workspace>/.junie-live/config.yaml`.
4. **Explicit `--config <path>`** — applied in the order given on the command line.
5. **Environment interpolation** — `${VAR}` expansion using `--env-file` plus
   the process environment. `<workspace>/.env` is loaded automatically when
   present; `--env-file` selects a different file. This resolves values *inside* each merged
   document; it is not an independent structural layer. The real process
   environment always wins over a dotenv value.
6. **CLI leaf overrides** — `--workspace`, `--home`, `--profile`,
   `--responsibility-area`, `--trace`.

### Merge semantics

- **Objects merge recursively** by field: a higher layer can change
  `backend.state.enabled` without replacing the sibling `backend.backend_url`.
- **Scalars override only when present.** Pointer/optional decoding
  distinguishes *absent* from an explicit `false`, `0`, `""`, or empty
  collection, so a later layer can legitimately disable an inherited boolean or
  clear a value. An absent key never clobbers an inherited value.
- **Maps merge by key** (`web-search.headers`, the opaque `hermes.config` /
  `junie.config`, model `Extra`). Later values win. A YAML `null` removes an
  inherited map key or scalar.
- **Named collections** (`git.repositories`, `slack.channels`) merge by the
  required `name` key: existing items are recursively overlaid in their
  original position and new names append. `enabled: false` on a named item
  disables an inherited item without duplicate-order tricks.
- **Model lists are atomic.** Each `agent-settings.<runtime>.model` /
  `auxiliary_model` list is replaced wholesale by a non-null later list because
  ordering/cardinality is semantic; `[]` clears it. Each runtime and each of
  its two lists merge independently.
- **Fatal errors** (with source file and, where available, YAML path):
  unknown fields, duplicate mapping keys, duplicate/missing collection names,
  conflicting repository paths, ambiguous auth, and unsupported schema versions.

## Environment expansion & secret redaction

Every secret-bearing field supports `${VAR}`, `${VAR:-default}`, and
`${VAR-default}` expansion. Tokens and inline private keys are **redacted** from
diagnostics, the run manifest, and `effective-config.yaml`. That file records
`<redacted:ENV_NAME>` when a value came from a single environment reference, or
`<redacted>` for a literal secret, and is written mode `0600`.

Secret-bearing fields: `git.repositories[].token`,
`git.repositories[].github-app.private-key`, `slack.bot-token`,
`slack.app-token`, `backend.token`, `web-search.token`.

## Top-level fields

| Field | Type | Meaning |
|---|---|---|
| `schema-version` | int | Must equal `1`. Any other value is fatal. |
| `workspace` | path | Primary repository checkout; resolved to an absolute, existing directory. Defaults to the current directory / `--workspace`; launched Hermes processes receive it as both their working directory and `PWD`, including Slack sessions. |
| `home` | path | Private `~/.junie-live` root. Defaults to `~/.junie-live` / `--home`. |
| `profile` | string | Hermes profile name. Default `junie-live`. |
| `responsibility_area` | string | Free text; exported as `JUNIE_LIVE_RESPONSIBILITY_AREA` and gates the first-run initialization marker. |

## `git`

Generalizes Yana's single-repo git into any number of host checkouts, each
with its own auth. Existing checkouts are validated and **never re-cloned**.

| Field | Type | Meaning |
|---|---|---|
| `repositories[]` | list | Keyed by `name`. See below. |
| `clone-missing` | bool | Clone a missing checkout (default from embedded defaults). |
| `fetch` | bool | Fetch an existing checkout. |

Per repository:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | Stable merge key (required). First effective entry is primary. |
| `url` | string | Remote URL. |
| `path` | path | Relative to the workspace root; defaults from the name/URL. Must not traverse (`..`) or escape the workspace, and two repos may not share a path. |
| `branch` | string | Branch to check out. |
| `auth` | enum | `none` \| `git-credential` \| `token` \| `ssh` \| `github-app`. |
| `token` | secret | Bearer credential when `auth: token`. |
| `ssh-key-file` | path | Key file when `auth: ssh` (empty defers to the host SSH agent). |
| `github-app` | object | `app-id`, `installation-id`, and exactly one of `private-key` / `private-key-file`. |
| `enabled` | bool | `false` removes an inherited repository by name. |

### Auth alternatives (examples)

Exactly one strategy is selected per repository; credentials are injected
ephemerally (never written to disk or into a remote URL).

```yaml
# 1) Anonymous (public repo)
git:
  repositories:
    - name: primary
      url: https://github.com/org/public.git
      auth: none

# 2) Host credential helper (use whatever `git` already has configured)
    - name: internal
      url: https://ghe.example/org/app.git
      auth: git-credential

# 3) Bearer token (HTTPS)
    - name: app
      url: https://github.com/org/app.git
      auth: token
      token: ${GITHUB_TOKEN}

# 4) SSH key
    - name: infra
      url: git@github.com:org/infra.git
      auth: ssh
      ssh-key-file: ~/.ssh/id_ed25519      # empty → host SSH agent

# 5) GitHub App (inline OR file private key, never both)
    - name: bot
      url: https://github.com/org/app.git
      auth: github-app
      github-app:
        app-id: ${GITHUB_APP_ID}
        installation-id: ${GITHUB_APP_INSTALLATION_ID}
        private-key-file: ${GITHUB_APP_PRIVATE_KEY_FILE:-}
        # private-key: ${GITHUB_APP_PRIVATE_KEY:-}   # mutually exclusive
```

## `slack`

Rendered into native Hermes Slack Socket Mode configuration (no Yana channel
relay). Tokens travel only through the child environment. Hermes requires a
bot mention in channel messages, matching the Yana sandbox behavior. The
gateway accepts messages from all Slack users.

| Field | Type | Meaning |
|---|---|---|
| `enabled` | bool | Master switch. |
| `mode` | string | First release: `socket`. |
| `bot-token` / `app-token` | secret | Slack credentials. |
| `channels[]` | list | Keyed by `name`; each has `id` and `enabled`. |
| `respond-in-threads` | bool | Thread behavior. |

## `backend`

Opt-in Junie Live backend identity plus three independently-gated features.
Enabled features require a complete identity (`backend_url` + `project_id`) and
`token`.

| Field | Meaning |
|---|---|
| `backend_url`, `project_id`, `token` | Backend identity/auth. |
| `state.enabled` | Restore and checkpoint mutable Hermes state only. Junie is always freshly seeded. |
| `state.checkpoint_interval_seconds` | Periodic snapshot cadence in seconds; `0` means final capture only. |
| `state.fail_if_not_restored` | Make lookup/download/import failure fatal; a backend `404` remains a valid first run. |
| `reporting.enabled` | Live reporting. |
| `commands.enabled`, `commands.poll_interval_seconds` | Inbound command polling. |

When state is operational, the CLI restores the latest snapshot into the new
run's `.hermes` before reconciling generated assets. It then remains in the
foreground, serializes periodic captures, and attempts a bounded final capture
before stopping Hermes. State transfer requires `backend.token`; the token and
signed URLs are never written to the run. Missing tokens and backend failures
are best-effort unless `state.fail_if_not_restored` is enabled.

Every launch has independent homes under `~/.junie-live/runs/<run-id>/`:
`.hermes` for Hermes, `.junie` for fresh Junie state, `logs` for logs, and
`junie-live` for other launch metadata. Hermes gateway stdout and stderr are
shown by the foreground CLI so Socket Mode connection failures are visible.
No `~/.junie-live/state/` tree or profile compatibility link is created.

## `agent-settings`

Typed per-runtime model selection, one primary and optional auxiliary entry per
runtime, rendered to each runtime's native config without overwriting unrelated
user settings.

`ingrazzio/<tool>` Hermes providers are rendered as named providers at
`${INGRAZZIO_URL:-https://ingrazzio-cloud-prod.labs.jb.gg}/tool/<tool>/v1` with
`key_env: JUNIE_API_KEY`, so Hermes reads the token at request time without
persisting it. The bare `ingrazzio` Junie provider uses Junie's native
Ingrazzio transport; the typed model becomes the default in
`JUNIE_HOME/config.json`, while explicit `junie.config` keys win.

```yaml
agent-settings:
  hermess-agent:
    model:
      - id: anthropic/claude-sonnet
        provider: anthropic
        reasoning_effort: high      # opaque extras are preserved verbatim
    auxiliary_model:
      - id: openai/gpt-4.1-mini
        provider: openai
  junie-cli:
    model:
      - id: anthropic/claude-sonnet
        provider: anthropic
```

## `web-search`

Direct (no-proxy) host web search. When enabled, the CLI registers a Hermes
MCP/tool server with the endpoint and non-secret headers; the token travels only
through the child environment.

| Field | Meaning |
|---|---|
| `enabled` | Master switch. |
| `provider` | e.g. `tavily`. |
| `endpoint` | Provider endpoint (`${TAVILY_URL:-https://api.tavily.com}`). |
| `token` | Bearer token (secret). |
| `headers` | Extra non-secret headers (merged by key). |

## `hermes` / `junie`

| Field | Meaning |
|---|---|
| `hermes.command` | The `hermes` executable (default `hermes`). |
| `hermes.api_host` / `api_port` | Loopback API bind. |
| `hermes.dashboard` / `dashboard_host` / `dashboard_port` | Dashboard bind. |
| `hermes.config` | Validated native Hermes leaf overrides (merged by key; wins over rendered keys). |
| `junie.command` | The `junie` executable (default `junie`). |
| `junie.config` | Optional native Junie overlay. |

After a successful launch, the CLI prints the effective Hermes API `/health`
URL and, when enabled, starts
`hermes dashboard --host <host> --port <port> --no-open` and prints its web UI
URL. The API root itself has no browser page. The API bind is exported using
Hermes's native `API_SERVER_*` environment contract; the required
bearer key is generated per run and remains environment-only. The host Hermes
dashboard is a separate process because the host gateway does not launch it.
If the configured API port is already occupied, Junie Live selects an available
port automatically, prints a warning with the selected port, and uses it in the
generated Hermes environment and run metadata.

Before each normal launch, Junie Live globally stops every Hermes process for
the current user. `junie-live stop` performs the same idempotent cleanup without
launching a new instance by calling Hermes' native `dashboard --stop` command.
It also stops processes matching the exact `hermes gateway run` command used by
the launcher. During a normal launch, the foreground CLI observes the gateway
process and termination signals; `junie-live stop` remains available as a
separate global cleanup command.

## `mcp` / `logging`

| Field | Meaning |
|---|---|
| `mcp.config` | Optional path to a native Hermes MCP config overlay. |
| `logging.trace` | CLI-side trace verbosity (also `--trace`). |

## A layered example

`~/.junie-live/config.yaml` (home layer):

```yaml
schema-version: 1
profile: junie-live
slack:
  enabled: true
  bot-token: ${SLACK_BOT_TOKEN}
  app-token: ${SLACK_APP_TOKEN}
  channels:
    - name: engineering
      id: C0123456789
```

`<workspace>/.junie-live/config.yaml` (workspace layer — overlays the same channel and
turns one off, adds a repo, and disables threads without touching Slack creds):

```yaml
slack:
  respond-in-threads: false
  channels:
    - name: engineering
      id: C0123456789
    - name: noisy
      id: C9999999999
      enabled: false          # remove an inherited channel by name
git:
  repositories:
    - name: primary
      url: https://github.com/org/app.git
      auth: token
      token: ${GITHUB_TOKEN}
```

When using `scripts/run.sh`, relative paths passed through `--workspace`,
`--config`, and `--env-file` are resolved from the caller's working directory,
not from the CLI source directory.

`--config ci-overrides.yaml` (highest file layer — clears the auxiliary model
list atomically and disables backend state):

```yaml
agent-settings:
  hermess-agent:
    auxiliary_model: []         # [] clears; a non-null list would replace
backend:
  state:
    enabled: false              # explicit false overrides an inherited true
```
