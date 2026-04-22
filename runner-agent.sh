#!/usr/bin/env bash
# runner-agent.sh — Runs inside GitHub Actions to provide an interview environment.
# Uses the runner account directly (each GH Actions run is an ephemeral VM).
# Installs ttyd + cloudflared, polls IPA backend for scenario commands.
set -euo pipefail

# --- Configuration from environment ---
SESSION_ID="${SESSION_ID:?SESSION_ID is required}"
CALLBACK_URL="${CALLBACK_URL:?CALLBACK_URL is required}"
CALLBACK_TOKEN="${CALLBACK_TOKEN:?CALLBACK_TOKEN is required}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-55}"

WORK_HOME="${HOME}"
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

# --- 1. Prepare workspace ---
log "Preparing workspace..."
mkdir -p "${WORK_HOME}/.local/bin" "${WORK_HOME}/.config" "${WORK_HOME}/challenge"
export PATH="${WORK_HOME}/.local/bin:${WORK_HOME}/.arkade/bin:/usr/local/bin:$PATH"

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

# asciinema + jq
sudo apt-get update -qq && sudo apt-get install -y -qq asciinema jq > /dev/null 2>&1 || true

# arkade (for installing CLI tools like kubectl, terraform, helm, etc.)
curl -sLS https://get.arkade.dev | sudo sh > /dev/null 2>&1 || true

log "Base tools installed."

# --- 2b. K8s cluster state tracking ---
K8S_INSTALLED=false

install_k3s() {
    if [ "${K8S_INSTALLED}" = "true" ]; then
        log "k3s already installed, skipping."
        return 0
    fi

    log "Installing k3s (lightweight Kubernetes)..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --write-kubeconfig-mode=644" sh - 2>&1 || {
        log "ERROR: k3s installation failed"
        return 1
    }

    # Wait for k3s to be ready
    log "Waiting for k3s to be ready..."
    local retries=0
    while [ $retries -lt 60 ]; do
        if sudo k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; then
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done

    if [ $retries -ge 60 ]; then
        log "ERROR: k3s did not become ready in time"
        return 1
    fi

    log "k3s is ready."

    # Set up kubeconfig
    mkdir -p "${WORK_HOME}/.kube"
    sudo cp /etc/rancher/k3s/k3s.yaml "${WORK_HOME}/.kube/config"
    sudo chown "$(id -u):$(id -g)" "${WORK_HOME}/.kube/config"
    export KUBECONFIG="${WORK_HOME}/.kube/config"

    # Add KUBECONFIG to bashrc
    if ! grep -q "KUBECONFIG" "${WORK_HOME}/.bashrc" 2>/dev/null; then
        echo "export KUBECONFIG=\"${WORK_HOME}/.kube/config\"" >> "${WORK_HOME}/.bashrc"
    fi

    # Make kubectl available
    sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl 2>/dev/null || true

    K8S_INSTALLED=true
    log "k3s configured."
}

# --- 3. Start ttyd (web terminal) ---
log "Starting ttyd web terminal..."
TTYD_PORT=7681

# Start asciinema recording in background
asciinema rec "${WORK_HOME}/session-recording.cast" --overwrite -c "sleep infinity" &
ASCIINEMA_PID=$!

# Start ttyd — runs bash directly as the runner user, starting in home dir
ttyd --port ${TTYD_PORT} --writable \
    -t fontSize=17 \
    -t reconnect=3 \
    -t 'theme={"background":"#000000","foreground":"#c7c7c7","cursor":"#00ff00"}' \
    bash -c "cd ${WORK_HOME} && exec bash --login" &
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

    # Check if this scenario needs Kubernetes
    local needs_k8s=$(echo "${cmd_json}" | jq -r '.needs_k8s // false')
    if [ "${needs_k8s}" = "true" ]; then
        install_k3s || {
            api_post "/${SESSION_ID}/command-result" "{\"id\":\"${cmd_id}\",\"status\":\"failed\",\"error\":\"k3s_install_failed\"}"
            return 1
        }

        # Create namespace if specified
        if [ -n "${namespace}" ] && [ "${namespace}" != "null" ]; then
            log "Creating namespace: ${namespace}"
            kubectl create namespace "${namespace}" 2>/dev/null || true
            kubectl config set-context --current --namespace="${namespace}" 2>/dev/null || true
        fi
    fi

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
        mkdir -p "${WORK_HOME}/challenge"
        tar -xzf "${bundle_path}" -C "${WORK_HOME}/challenge/" 2>/dev/null || true
        rm -f "${bundle_path}"
        log "Scenario files extracted."
    fi

    # Run setup commands
    if [ -n "${setup}" ]; then
        log "Running setup commands..."
        while IFS= read -r cmd; do
            [ -z "${cmd}" ] && continue
            log "  > ${cmd}"
            bash -c "${cmd}" 2>&1 || true
        done <<< "${setup}"
    fi

    # Write instructions
    if [ -n "${instructions}" ] && [ "${instructions}" != "null" ] && [ "${instructions}" != "" ]; then
        log "Writing instructions..."
        echo "${instructions}" > "${WORK_HOME}/INSTRUCTIONS.md"
        echo "${instructions}" > "${WORK_HOME}/.interview-instructions"
        # Show instructions on terminal login
        if ! grep -q "interview-instructions" "${WORK_HOME}/.bashrc" 2>/dev/null; then
            echo 'cat ~/.interview-instructions 2>/dev/null' >> "${WORK_HOME}/.bashrc"
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

# Notify backend
api_post "/workflow-complete" '{"status":"completed"}'

# Stop services
kill ${TTYD_PID} 2>/dev/null || true
kill ${CLOUDFLARED_PID} 2>/dev/null || true

log "Session complete. Goodbye."
