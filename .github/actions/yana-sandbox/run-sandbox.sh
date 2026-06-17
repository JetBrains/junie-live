#!/usr/bin/env bash
# Supervised, bounded run loop for the Yana sandbox inside a GitHub Actions job.
#
# Runs `yana --env-file <env> --agent <agent> yana.yaml` in the foreground for a
# total time budget (YANA_RUN_DURATION_SECONDS). If the yana process exits before
# the budget elapses (crash or clean stop), the stack is torn down and the run is
# restarted until the budget is exhausted. Continuous operation across hours is
# achieved by the caller workflow's hourly schedule.
#
# Required environment:
#   YANA_AGENT                 - agent name
#   YANA_ENV_FILE              - path to the generated .env file
#   YANA_RUN_DURATION_SECONDS  - total time budget in seconds
#   YANA_WORKING_DIRECTORY     - dir containing yana.yaml (and .yana/<agent>/)
#   YANA_LOG_DIR               - dir for the per-run yana log files (artifact)

set -euo pipefail

AGENT="${YANA_AGENT:?YANA_AGENT is required}"
ENV_FILE="${YANA_ENV_FILE:?YANA_ENV_FILE is required}"
DURATION="${YANA_RUN_DURATION_SECONDS:-3600}"
WORKDIR="${YANA_WORKING_DIRECTORY:-.}"
BACKOFF_SECONDS="${YANA_RESTART_BACKOFF_SECONDS:-5}"
LOG_DIR="${YANA_LOG_DIR:-${RUNNER_TEMP:-/tmp}/yana-logs}"

mkdir -p "$LOG_DIR"

cd "$WORKDIR"

log() { printf '[yana-sandbox] %s\n' "$*"; }

down() {
  log "Tearing down the sandbox stack..."
  yana --env-file "$ENV_FILE" --agent "$AGENT" yana.yaml down || \
    log "WARN: 'yana ... down' returned non-zero (continuing)."
}

deadline=$(( $(date +%s) + DURATION ))
log "Starting supervised sandbox: agent='${AGENT}', budget=${DURATION}s (deadline epoch ${deadline})."

attempt=0
while :; do
  now=$(date +%s)
  remaining=$(( deadline - now ))
  if [ "$remaining" -le 0 ]; then
    log "Time budget exhausted; stopping."
    break
  fi

  attempt=$(( attempt + 1 ))
  # Per-run yana log file at a known absolute path: passed to the CLI via
  # --log-file. yana also streams to stdout (visible live in the job log), and
  # this file is uploaded as an artifact so users can download the full log.
  log_file="$(printf '%s/yana-run-%03d.log' "$LOG_DIR" "$attempt")"
  log "Run #${attempt}: launching yana for up to ${remaining}s (foreground). Log: ${log_file}"

  # SIGINT mimics Ctrl+C so the CLI runs its clean-stop path on timeout.
  rc=0
  timeout -s INT "${remaining}s" \
    yana --log-file "$log_file" --env-file "$ENV_FILE" --agent "$AGENT" yana.yaml || rc=$?

  now=$(date +%s)
  if [ "$now" -ge "$deadline" ] || [ "$rc" -eq 124 ]; then
    # rc 124 = timeout elapsed (normal end of the budget window).
    log "Run #${attempt} reached the time budget (exit ${rc})."
    break
  fi

  log "Run #${attempt} exited early (exit ${rc}) with $(( deadline - now ))s remaining; restarting."
  down
  sleep "$BACKOFF_SECONDS"
done

down
log "Sandbox supervisor finished cleanly."
exit 0
