# Yana Sandbox — Composite GitHub Action

Run the full [Yana](https://github.com/JetBrains/junie-live) sandbox (proxies + agent
container) inside a GitHub Actions job. The action installs the published `yana`
CLI, logs in to GHCR, injects your secrets into a temporary `.env` file, and runs
the sandbox for a bounded, self-restarting window.

```yaml
# Mint a short-lived, repo-scoped installation token from the Yana App
# (its private key stays in the Actions secret store, never in the sandbox).
- id: app-token
  uses: actions/create-github-app-token@v1
  with:
    app-id: ${{ secrets.YANA_APP_ID }}
    private-key: ${{ secrets.YANA_APP_PRIVATE_KEY }}

- uses: jetbrains/junie-live/.github/actions/yana-sandbox@main
  with:
    agent: junie-test
    run-duration-seconds: "18000"  # up to 5h (GitHub job cap is ~6h)
    openrouter-api-key: ${{ secrets.OPENROUTER_API_KEY }}
    # Only the ~1h installation token enters the sandbox — not the App key.
    git-token: ${{ steps.app-token.outputs.token }}
    github-mcp-token: ${{ steps.app-token.outputs.token }}
    yana-token-secret: ${{ secrets.YANA_TOKEN_SECRET }}
    slack-bot-token: ${{ secrets.BOT_USER_ACCESS_TOKEN }}
    slack-app-token: ${{ secrets.SLACK_APP_TOKEN }}
    ghcr-token: ${{ secrets.GHCR_TOKEN }}
```

## How it works

1. **Install CLI** — installs the `yana` CLI (via the repo `install.sh`, or a
   pinned release asset when `yana-version` is set), using the job's
   `github.token` to fetch the release.
2. **GHCR login** — logs in to `ghcr.io` with `ghcr-token` so the private
   `ghcr.io/jetbrains/yana/*` images can be pulled.
3. **Generate `.env`** — writes only the non-empty secret inputs (plus any
   `extra-secrets` KEY=VALUE lines) to a `chmod 600` temp file (keys match
   `.env.example`). Secrets land only in this proxy-facing file; the agent
   container keeps zero credentials.
4. **Supervised run** — `run-sandbox.sh` runs
   `yana --env-file <env> --agent <agent> yana.yaml` in the foreground under
   `timeout -s INT <budget>`. If `yana` exits early it tears the stack down and
   restarts until `run-duration-seconds` elapses, then does a final `down`.

Continuous operation across hours comes from the **caller workflow's schedule**
(see `examples/junie-agent/yana-sandbox.yml`): each cron tick launches a fresh
sandbox; the internal supervisor recovers from crashes within the run. A single
run can be up to **5 hours** (`run-duration-seconds: "18000"`) — GitHub caps a
job at ~6h, so a 5h budget plus install/teardown headroom (`timeout-minutes: 330`)
stays under the limit. The example schedule runs every 5 hours to match.

## Logs

The CLI accepts a `--log-file <path>` flag that writes its full session log —
docker output plus the streamed status events — to a chosen absolute path. The
action uses this automatically: each `yana` invocation is launched with
`--log-file <runner-temp>/yana-logs/yana-run-NNN.log` (one file per supervisor
attempt). The same output also streams to **stdout**, so it is visible **live**
in the running job's log. After the run (and even on failure, via `always()`),
the log directory is uploaded as the **`yana-logs`** job artifact, so users can
**download** the complete logs from the workflow run page. The log location is
not configurable on the action (only on the CLI's `--log-file`); the action just
surfaces it to the user.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `agent` | yes | — | Agent name; selects `.yana/<agent>/agent.yaml` in the caller repo. |
| `yana-version` | no | `latest` | yana CLI release tag, or `latest`. |
| `working-directory` | no | `.` | Directory containing the caller's `yana.yaml`. |
| `run-duration-seconds` | no | `3600` | Per-run time budget; restarted on early exit until elapsed. |
| `openrouter-api-key` | no | `""` | `OPENROUTER_API_KEY`. |
| `openai-api-key` | no | `""` | `OPENAI_API_KEY`. |
| `anthropic-api-key` | no | `""` | `ANTHROPIC_API_KEY`. |
| `git-token` | no | `""` | `GIT_TOKEN` — preferred: a short-lived installation token from `actions/create-github-app-token` (see below). |
| `github-app-id` | no | `""` | `GITHUB_APP_ID` (legacy fallback; prefer `git-token`). |
| `github-app-private-key` | no | `""` | `GITHUB_APP_PRIVATE_KEY`, base64 PEM (legacy fallback — forwards the org-wide key into the sandbox; prefer `git-token`). |
| `github-app-installation-id` | no | `""` | `GITHUB_APP_INSTALLATION_ID` (legacy fallback; prefer `git-token`). |
| `yana-token-secret` | no | `""` | `YANA_TOKEN_SECRET` (agent↔proxy auth). |
| `slack-bot-token` | no | `""` | `BOT_USER_ACCESS_TOKEN` (Slack `xoxb-` bot token). |
| `slack-app-token` | no | `""` | `SLACK_APP_TOKEN` (Slack `xapp-` app-level token with `connections:write`). |
| `github-mcp-token` | no | `""` | `GITHUB_MCP_TOKEN`. |
| `extra-secrets` | no | `""` | Newline-separated `KEY=VALUE` pairs for arbitrary per-service/MCP/channel secrets the action does not name (see below). |
| `ghcr-token` | no | `""` | Token with `read:packages` for private images. |

## Arbitrary service secrets (`extra-secrets`)

The named inputs above cover the fixed infra secrets, but Yana's configs
(`yana.yaml`, `agent.yaml`, `mcp.json`) consume an **open `${VAR}` namespace** —
a new MCP server or channel can need any secret (e.g. `${NOTION_TOKEN}`,
`${JIRA_TOKEN}`). Rather than adding a typed input + cutting a release for each
one, pass them through the open `extra-secrets` input as newline-separated
`KEY=VALUE` pairs:

```yaml
- uses: jetbrains/junie-live/.github/actions/yana-sandbox@main
  with:
    agent: junie-test
    openrouter-api-key: ${{ secrets.OPENROUTER_API_KEY }}
    extra-secrets: |
      GITHUB_MCP_TOKEN=${{ secrets.GITHUB_MCP_TOKEN }}
      NOTION_TOKEN=${{ secrets.NOTION_TOKEN }}
      JIRA_TOKEN=${{ secrets.JIRA_TOKEN }}
```

Each non-empty line is validated (`^[A-Za-z_][A-Za-z0-9_]*=`), masked in logs
with `::add-mask::`, and appended to the **same** `chmod 600` proxy-facing
`.env` as the named inputs — so secrets still land only in the proxies and the
sandbox stays secretless and egress-gated. Blank lines and `#`-comments are
ignored; malformed lines and lines with empty values are skipped. Reference each
key in your committed `yana.yaml` / `agent.yaml` / `mcp.json` as `${KEY}`. This
makes "add a secret" a one-line caller change (add a repo secret + one
`KEY=...` line) with zero action/release churn.

## Repo identity (config-only)

The repository the sandbox operates on is defined **exclusively** in the caller's
committed config — the action does not configure it and cannot override it. Set
it in your `yana.yaml` (or `.yana/<agent>/agent.yaml`):

```yaml
git:
  repo_url: "https://github.com/your-org/your-repo.git"
  branch: "main"
```

This keeps a single canonical source of truth for the repo, avoiding the
duplicate-clone problem that arose when the action injected a differently-cased
GitHub-context URL alongside the hand-written one.

## Git credentials (use a short-lived App token)

Do **not** forward the GitHub App **private key** into the sandbox — it is an
org-wide shared secret that can mint tokens for every installation of the App.
Instead, because the Yana App is installed in the calling repo, mint a
**short-lived, repo-scoped installation token** on the runner with the official
[`actions/create-github-app-token`](https://github.com/actions/create-github-app-token)
and pass only that token in as `git-token` (and `github-mcp-token`):

```yaml
- id: app-token
  uses: actions/create-github-app-token@v1
  with:
    app-id: ${{ secrets.YANA_APP_ID }}
    private-key: ${{ secrets.YANA_APP_PRIVATE_KEY }}

- uses: jetbrains/junie-live/.github/actions/yana-sandbox@main
  with:
    agent: junie-test
    git-token: ${{ steps.app-token.outputs.token }}
    github-mcp-token: ${{ steps.app-token.outputs.token }}
    # ...other inputs...
```

The token is scoped to the installation and expires in ~1h. A fresh token is
minted on every scheduled run. The CLI's existing `GIT_TOKEN` code path consumes
it unchanged, so the `git.token` branch of `validate.go` is satisfied and the
`github-app-*` inputs are not needed. **For runs longer than the ~1h token
lifetime** (e.g. the 5-hour `run-duration-seconds: "18000"` budget) git
operations stop working once the token expires; use the `github-app-*` **legacy
fallback** inputs (the App-credentials path auto-refreshes the token in-sandbox)
if you need git access for the full window — at the cost of forwarding the
private key into the sandbox.

For same-repo-only access you can instead pass the workflow's built-in
`${{ github.token }}` (with `permissions: { contents: write }`) as `git-token`;
use the App token when you need the **Yana App identity** on commits/PRs or
**cross-repo** access.

## Caller responsibilities

- Commit your own `yana.yaml` (LLM provider; `git.repo_url`/`branch` set
  explicitly) and `.yana/<agent>/` (`agent.yaml` + `mcp.json`) in the calling
  repo, mirroring local usage. The action does **not** template config or
  configure the repository — it only injects secrets and selects the agent.
- Provide a `ghcr-token` with `read:packages` on the `jetbrains` org while the
  images are private.

## Notes / limitations

- Runs on `ubuntu-latest`, where Docker with `NET_ADMIN` is available for the
  egress-gateway.
- Each scheduled run starts fresh; cross-run state persistence is the agent's
  existing opt-in mechanism, not provided by this action.
- GitHub jobs are capped at ~6h and scheduled crons can be delayed under load;
  a 5-hour budget (`timeout-minutes: 330`) plus an every-5-hours schedule keeps
  each job within the limit.
- A short-lived App installation token (`git-token`) lasts ~1h; for the full 5h
  window use the `github-app-*` fallback (auto-refreshes) if git access must
  outlive the token.
