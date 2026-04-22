# IPA Runner

Public repository for running IPA (Interview Panel Assistant) interview sessions via GitHub Actions.

This repo contains only the workflow and runner agent script. Scenario content is served privately from the IPA backend.

## How it works

1. The IPA web app triggers a `workflow_dispatch` event on this repo
2. GitHub Actions spins up an Ubuntu runner
3. The runner agent installs tools (ttyd, cloudflared), creates a candidate user, and starts a web terminal
4. A cloudflared tunnel exposes the terminal to the candidate via a public URL
5. The agent polls the IPA backend for scenario commands and applies them dynamically
6. When the session ends, artifacts (terminal recording, bash history, challenge files) are uploaded

## Files

- `.github/workflows/interview-session.yml` — The workflow definition
- `runner-agent.sh` — The agent script that runs inside the workflow
