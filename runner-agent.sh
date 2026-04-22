#!/usr/bin/env bash
# runner-agent.sh — Runs inside GitHub Actions to provide an interview environment.
# Installs ttyd + cloudflared, creates a candidate user, polls IPA backend for
# scenario commands, and reports status back.
set -euo pipefail

# --- Configuration from environment ---
SESSION_ID="${SESSION_ID:?SESSION_ID is required}"
CALLBACK_URL="${CALLBACK_URL:?CALLBACK_URL is required}"
CALLBACK_TOKEN="${CALLBACK_TOKEN:?CALLBACK_TOKEN is required}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-55}"

CANDIDATE_USER="candidate"
CANDIDATE_HOME="/home/${CANDIDATE_USER}"
POLL_INTERVAL=5
HEARTBEAT_INTERVAL=30

log() { echo "[runner-agent] $(date '+%H:%M:%S') $*"; }

# --- Helper: API call to IPA backend ---
api_post() {
    local endpoint="$1"
    local data="${2:-{}}"
    curl -sf -X POST \
        -H "Content-Type: application/json" \
        -H "X-Callback-Token: ${CALLBACK_TOKEN}" \
        -d "${data}" \
        "${CALLBACK_URL}${endpoint}" 2>/dev/null || true
}

api_get() {
    local endpoint="$1"
    curl -sf -H "X-Callback-Token: ${CALLBACK_TOKEN}" \
        "${CALLBACK_URL}${endpoint}" 2>/dev/null || echo "[]"
}

# --- 1. Create candidate user ---
log "Creating candidate user..."
sudo useradd -m -s /bin/bash "${CANDIDATE_USER}" 2>/dev/null || true
sudo mkdir -p "${CANDIDATE_HOME}/.local/bin"
sudo chown -R "${CANDIDATE_USER}:${CANDIDATE_USER}" "${CANDIDATE_HOME}"

# Add candidate's local bin to PATH
echo 'export PATH="$HOME/.local/bin:$PATH"' | sudo tee -a "${CANDIDATE_HOME}/.bashrc" > /dev/null

# --- 2. Install base tools ---
log "Installing base tools (ttyd, cloudflared, asciinema)..."

# ttyd
TTYD_VERSION="1.7.7"
sudo wget -q "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    -O /usr/local/bin/ttyd
sudo chmod +x /usr/local/bin/ttyd

# cloudflared
sudo wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
    -O /usr/local/bin/cloudflared
sudo chmod +x /usr/local/bin/cloudflared

# asciinema
sudo apt-get update -qq && sudo apt-get install -y -qq asciinema > /dev/null 2>&1 || true

# arkade (for installing CLI tools like kubectl, terraform, helm, etc.)
curl -sLS https://get.arkade.dev | sudo sh > /dev/null 2>&1 || true

log "Base tools installed."

# --- 3. Start ttyd (web terminal) ---
log "Starting ttyd web terminal..."
TTYD_PORT=7681

sudo -u "${CANDIDATE_USER}" -i -- asciinema rec \
    "${CANDIDATE_HOME}/session-recording.cast" \
    --overwrite -c "sleep infinity" &
ASCIINEMA_PID=$!

ttyd --port ${TTYD_PORT} --writable \
    -t fontSize=17 \
    -t reconnect=3 \
    -t 'theme={"background":"#000000","foreground":"#c7c7c7","cursor":"#00ff00"}' \
    sudo -u "${CANDIDATE_USER}" -i &
TTYD_PID=$!

sleep 2
log "ttyd running on port ${TTYD_PORT}."

# --- 4. Start cloudflared tunnel ---
log "Starting cloudflared tunnel..."
TUNNEL_LOG="/tmp/cloudflared.log"
cloudflared tunnel --url "http://localhost:${TTYD_PORT}" \
    --no-autoupdate > "${TUNNEL_LOG}" 2>&1 &
CLOUDFLARED_PID=$!

# Wait for tunnel URL
TUNNEL_URL=""
for i in $(seq 1 60); do
    TUNNEL_URL=$(grep -oP 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "${TUNNEL_LOG}" 2>/dev/null | head -1 || true)
    if [ -n "${TUNNEL_URL}" ]; then
        break
    fi
    sleep 1
done

if [ -z "${TUNNEL_URL}" ]; then
    log "ERROR: Failed to get tunnel URL after 60 seconds"
    api_post "/workflow-complete" '{"status":"failed","error":"tunnel_timeout"}'
    exit 1
fi

log "Tunnel ready: ${TUNNEL_URL}"

# --- 5. Report tunnel URL to IPA backend ---
api_post "/session-ready" "{\"tunnel_url\":\"${TUNNEL_URL}\"}"
log "Reported tunnel URL to IPA backend."

# --- 6. Main loop: poll for commands + heartbeat ---
calculate_deadline() {
    echo $(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
}
DEADLINE=$(calculate_deadline)
LAST_HEARTBEAT=0

apply_scenario() {
    local cmd_json="$1"
    local cmd_id scenario_name packages pre_install setup instructions namespace

    cmd_id=$(echo "${cmd_json}" | jq -r '.id')
    scenario_name=$(echo "${cmd_json}" | jq -r '.scenario_name')
    packages=$(echo "${cmd_json}" | jq -r '.packages // [] | .[]' 2>/dev/null)
    pre_install=$(echo "${cmd_json}" | jq -r '.pre_install // [] | .[]' 2>/dev/null)
    setup=$(echo "${cmd_json}" | jq -r '.setup // [] | .[]' 2>/dev/null)
    instructions=$(echo "${cmd_json}" | jq -r '.instructions // ""')
    namespace=$(echo "${cmd_json}" | jq -r '.namespace // ""')

    log "Applying scenario: ${scenario_name} (${cmd_id})"

    # Install apt packages
    if [ -n "${packages}" ]; then
        log "Installing packages: ${packages}"
        echo "${packages}" | xargs sudo apt-get install -y -qq > /dev/null 2>&1 || true
    fi

    # Install CLI tools via arkade
    if [ -n "${pre_install}" ]; then
        for tool in ${pre_install}; do
            log "Installing tool: ${tool}"
            sudo arkade get "${tool}" --quiet 2>/dev/null || true
            # Move to a PATH location
            if [ -f "/root/.arkade/bin/${tool}" ]; then
                sudo cp "/root/.arkade/bin/${tool}" "/usr/local/bin/${tool}"
                sudo chmod +x "/usr/local/bin/${tool}"
            fi
        done
    fi

    # Download and extract scenario files bundle
    log "Downloading scenario files..."
    local bundle_path="/tmp/scenario-${scenario_name}.tar.gz"
    curl -sf -H "X-Callback-Token: ${CALLBACK_TOKEN}" \
        -o "${bundle_path}" \
        "${CALLBACK_URL}/${SESSION_ID}/scenario/${scenario_name}/bundle" 2>/dev/null || true

    if [ -f "${bundle_path}" ] && [ -s "${bundle_path}" ]; then
        sudo mkdir -p "${CANDIDATE_HOME}/challenge"
        sudo tar -xzf "${bundle_path}" -C "${CANDIDATE_HOME}/challenge/" 2>/dev/null || true
        sudo chown -R "${CANDIDATE_USER}:${CANDIDATE_USER}" "${CANDIDATE_HOME}/challenge/"
        rm -f "${bundle_path}"
        log "Scenario files extracted."
    fi

    # Run setup commands as candidate user
    if [ -n "${setup}" ]; then
        log "Running setup commands..."
        while IFS= read -r cmd; do
            [ -z "${cmd}" ] && continue
            log "  > ${cmd}"
            sudo -u "${CANDIDATE_USER}" -i bash -c "${cmd}" 2>&1 || true
        done <<< "${setup}"
    fi

    # Write instructions
    if [ -n "${instructions}" ] && [ "${instructions}" != "null" ] && [ "${instructions}" != "" ]; then
        log "Writing instructions..."
        echo "${instructions}" | sudo tee "${CANDIDATE_HOME}/INSTRUCTIONS.md" > /dev/null
        sudo chown "${CANDIDATE_USER}:${CANDIDATE_USER}" "${CANDIDATE_HOME}/INSTRUCTIONS.md"
        # Also display in terminal via motd-like approach
        echo "${instructions}" | sudo tee "${CANDIDATE_HOME}/.interview-instructions" > /dev/null
        sudo chown "${CANDIDATE_USER}:${CANDIDATE_USER}" "${CANDIDATE_HOME}/.interview-instructions"
        # Add to bashrc to show on login
        if ! grep -q "interview-instructions" "${CANDIDATE_HOME}/.bashrc" 2>/dev/null; then
            echo 'cat ~/.interview-instructions 2>/dev/null' | sudo tee -a "${CANDIDATE_HOME}/.bashrc" > /dev/null
        fi
    fi

    # Report success
    api_post "/${SESSION_ID}/command-result" "{\"id\":\"${cmd_id}\",\"status\":\"applied\"}"
    log "Scenario ${scenario_name} applied successfully."
}

log "Entering main loop (timeout: ${TIMEOUT_MINUTES} minutes)..."

while true; do
    NOW=$(date +%s)

    # Check deadline
    if [ "${NOW}" -ge "${DEADLINE}" ]; then
        log "Session timeout reached. Shutting down."
        break
    fi

    # Heartbeat (every 30 seconds)
    if [ $(( NOW - LAST_HEARTBEAT )) -ge ${HEARTBEAT_INTERVAL} ]; then
        HEARTBEAT_RESPONSE=$(api_post "/${SESSION_ID}/heartbeat" '{}')
        ACTION=$(echo "${HEARTBEAT_RESPONSE}" | jq -r '.action // "continue"' 2>/dev/null || echo "continue")
        if [ "${ACTION}" = "stop" ]; then
            log "Received stop signal from backend. Shutting down."
            break
        fi
        LAST_HEARTBEAT=${NOW}
    fi

    # Poll for pending commands
    COMMANDS=$(api_get "/${SESSION_ID}/commands")
    CMD_COUNT=$(echo "${COMMANDS}" | jq 'length' 2>/dev/null || echo "0")

    if [ "${CMD_COUNT}" -gt 0 ] && [ "${CMD_COUNT}" != "null" ]; then
        log "Received ${CMD_COUNT} pending command(s)."
        for i in $(seq 0 $(( CMD_COUNT - 1 ))); do
            CMD=$(echo "${COMMANDS}" | jq ".[$i]")
            apply_scenario "${CMD}" || {
                CMD_ID=$(echo "${CMD}" | jq -r '.id')
                api_post "/${SESSION_ID}/command-result" "{\"id\":\"${CMD_ID}\",\"status\":\"failed\",\"error\":\"apply_failed\"}"
            }
        done
    fi

    sleep ${POLL_INTERVAL}
done

# --- 7. Cleanup ---
log "Session ending. Collecting artifacts..."

# Stop asciinema recording gracefully
kill ${ASCIINEMA_PID} 2>/dev/null || true
sleep 2

# Copy bash history for artifact upload
sudo cp "${CANDIDATE_HOME}/.bash_history" "${CANDIDATE_HOME}/.bash_history.bak" 2>/dev/null || true

# Notify backend
api_post "/workflow-complete" '{"status":"completed"}'

# Stop services
kill ${TTYD_PID} 2>/dev/null || true
kill ${CLOUDFLARED_PID} 2>/dev/null || true

log "Session complete. Goodbye."
