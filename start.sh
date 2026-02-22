#!/usr/bin/env bash
set -e

APP_USER="${APP_USER:-jaxuser}"
APP_HOME=$(eval echo "~${APP_USER}")

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
  local script_path=$1
  local script_msg=$2
  if [[ -f "${script_path}" ]]; then
    echo "${script_msg}"
    bash "${script_path}"
  fi
}

# Setup SSH — keys go into jaxuser's home, not root's
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
export_env_vars() {
  echo "Exporting environment variables..."
  printenv \
    | grep -E '^[A-Z_][A-Z0-9_]*=' \
    | grep -v '^PUBLIC_KEY=' \
    | awk -F= '{ val=$0; sub(/^[^=]*=/,"",val); print "export " $1 "=\"" val "\"" }' \
    > /etc/rp_environment || true

  if [[ -f /etc/rp_environment ]]; then
    chmod 644 /etc/rp_environment
    local bashrc="${APP_HOME}/.bashrc"
    touch "$bashrc"
    chown "${APP_USER}:${APP_USER}" "$bashrc"
    grep -q 'source /etc/rp_environment' "$bashrc" \
      || echo 'source /etc/rp_environment' >> "$bashrc"
  fi
}

# Start JupyterLab as non-root on port 8889 (nginx proxies 8888 → 8889)
start_jupyter() {
  if [[ -n "${JUPYTER_PASSWORD:-}" ]]; then
    echo "Starting JupyterLab on :8889 as ${APP_USER}..."
    sudo -u "${APP_USER}" nohup python3 -m jupyter lab \
      --no-browser \
      --port=8889 --ip=127.0.0.1 \
      --FileContentsManager.delete_to_trash=False \
      --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
      --IdentityProvider.token="$JUPYTER_PASSWORD" \
      --ServerApp.allow_origin=* \
      --ServerApp.preferred_dir=/workspace \
      > /tmp/jupyter.log 2>&1 &
    echo "JupyterLab started (proxied via nginx on :8888)."
  fi
}

# -------------------------------------------------------------------------- #
#                               Main Program                                 #
# -------------------------------------------------------------------------- #

start_nginx

execute_script "/pre_start.sh" "Running pre-start script..."

echo "Pod started."

setup_ssh
start_jupyter
export_env_vars

echo "=== JAX pod ready (user: ${APP_USER}) ==="
sudo -u "${APP_USER}" python3 -c "import jax; print(f'JAX {jax.__version__} — devices: {jax.devices()}')" 2>/dev/null || true

execute_script "/post_start.sh" "Running post-start script..."

echo "Start script(s) finished, pod is ready to use."

# Drop privileges — PID 1 continues as non-root
exec gosu "${APP_USER}" sleep infinity