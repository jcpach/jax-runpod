#!/usr/bin/env bash
set -euo pipefail

APP_USER="${APP_USER:-jaxuser}"
APP_HOME="$(eval echo "~${APP_USER}")"

# -------------------------------------------------------------------------- #
#                          Function Definitions                              #
# -------------------------------------------------------------------------- #

# Start nginx (required for RunPod's port proxy system)
start_nginx() {
  echo "Starting nginx..."
  service nginx start
}

# Execute hook script if it exists (RunPod convention)
execute_script() {
  local script_path="${1:-}"
  local script_msg="${2:-}"
  if [[ -n "$script_path" && -f "$script_path" ]]; then
    echo "$script_msg"
    bash "$script_path"
  fi
}

# Setup SSH — keys go into APP_USER's home, not root's
setup_ssh() {
  if [[ -n "${PUBLIC_KEY:-}" ]]; then
    echo "Setting up SSH for ${APP_USER}..."
    local ssh_dir="${APP_HOME}/.ssh"
    mkdir -p "$ssh_dir"
    echo "$PUBLIC_KEY" >> "${ssh_dir}/authorized_keys"
    chown -R "${APP_USER}:${APP_USER}" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "${ssh_dir}/authorized_keys"

    # Generate host keys if missing and print fingerprints
    for type in rsa ecdsa ed25519; do
      local keyfile="/etc/ssh/ssh_host_${type}_key"
      if [[ ! -f "$keyfile" ]]; then
        ssh-keygen -t "$type" -f "$keyfile" -q -N ''
      fi
    done

    service ssh start

    echo "SSH host key fingerprints:"
    for key in /etc/ssh/ssh_host_*.pub; do
      ssh-keygen -lf "$key"
    done
    echo "SSH ready — login as: ${APP_USER}"
  else
    echo "PUBLIC_KEY not set — SSH disabled."
  fi
}

# Export env vars so they persist into SSH sessions
# NOTE: This is still "best effort" if env values contain quotes/newlines/etc.
# Consider whitelisting only needed vars if you have complex values.
export_env_vars() {
  echo "Exporting environment variables..."

  # Create env file (exclude HOME and PUBLIC_KEY on purpose)
  printenv \
    | grep -E '^[A-Z_][A-Z0-9_]*=' \
    | grep -v '^PUBLIC_KEY=' \
    | grep -v '^HOME=' \
    | awk -F= '{ val=$0; sub(/^[^=]*=/,"",val); print "export " $1 "=\"" val "\"" }' \
    > /etc/rp_environment || true

  chmod 644 /etc/rp_environment 2>/dev/null || true

  # Ensure login shells (SSH) load it
  cat >/etc/profile.d/rp_environment.sh <<'EOF'
# RunPod exported environment
[ -f /etc/rp_environment ] && . /etc/rp_environment
EOF
  chmod 644 /etc/profile.d/rp_environment.sh

  # Also cover bash login shells that rely on ~/.profile
  local profile="${APP_HOME}/.profile"
  touch "$profile"
  chown "${APP_USER}:${APP_USER}" "$profile"
  grep -q '/etc/rp_environment' "$profile" \
    || echo '[ -f /etc/rp_environment ] && . /etc/rp_environment' >> "$profile"
}

# Start JupyterLab as non-root on port 8889 (nginx proxies 8888 → 8889)
start_jupyter() {
  if [[ -n "${JUPYTER_PASSWORD:-}" ]]; then
    echo "Starting JupyterLab on :8889 as ${APP_USER}..."

    local jupyter_dir="${APP_HOME}"
    [[ -d /workspace ]] && jupyter_dir="/workspace"

    # Create dirs to avoid permission surprises
    mkdir -p \
      "${APP_HOME}/.cache" \
      "${APP_HOME}/.config" \
      "${APP_HOME}/.local/share/jupyter/runtime"
    chown -R "${APP_USER}:${APP_USER}" \
      "${APP_HOME}/.cache" \
      "${APP_HOME}/.config" \
      "${APP_HOME}/.local" || true

    sudo -E -u "${APP_USER}" \
      HOME="${APP_HOME}" \
      XDG_CACHE_HOME="${APP_HOME}/.cache" \
      XDG_CONFIG_HOME="${APP_HOME}/.config" \
      XDG_DATA_HOME="${APP_HOME}/.local/share" \
      JUPYTER_RUNTIME_DIR="${APP_HOME}/.local/share/jupyter/runtime" \
      nohup python3 -m jupyter lab \
        --no-browser \
        --port=8889 --ip=127.0.0.1 \
        --ServerApp.allow_remote_access=True \
        --ServerApp.trust_xheaders=True \
        --FileContentsManager.delete_to_trash=False \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --IdentityProvider.token="$JUPYTER_PASSWORD" \
        --ServerApp.allow_origin=* \
        > /tmp/jupyter.log 2>&1 &

    echo "JupyterLab started (proxied via nginx on :8888)."
  else
    echo "JUPYTER_PASSWORD not set — Jupyter disabled."
  fi
}

# -------------------------------------------------------------------------- #
#                               Main Program                                 #
# -------------------------------------------------------------------------- #

start_nginx

execute_script "/pre_start.sh" "Running pre-start script..."

echo "Pod started."

setup_ssh
export_env_vars
start_jupyter

echo "=== JAX pod ready (user: ${APP_USER}) ==="
sudo -E -u "${APP_USER}" \
  HOME="${APP_HOME}" \
  XDG_CACHE_HOME="${APP_HOME}/.cache" \
  XDG_CONFIG_HOME="${APP_HOME}/.config" \
  XDG_DATA_HOME="${APP_HOME}/.local/share" \
  python3 -c "import jax; print(f'JAX {jax.__version__} — devices: {jax.devices()}')" \
  2>/dev/null || true

execute_script "/post_start.sh" "Running post-start script..."

echo "Start script(s) finished, pod is ready to use."

# Drop privileges — PID 1 continues as non-root
exec gosu "${APP_USER}" sleep infinity