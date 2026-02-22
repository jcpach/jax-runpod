#!/usr/bin/env bash
set -e

APP_USER="${APP_USER:-jaxuser}"
APP_HOME=$(eval echo "~${APP_USER}")

# ── SSH setup (must run as root to start sshd) ────────────────────────────
setup_ssh() {
  if [[ -n "${PUBLIC_KEY:-}" ]]; then
    # Install key into the user's home, not root's
    local ssh_dir="${APP_HOME}/.ssh"
    mkdir -p "$ssh_dir"
    echo "$PUBLIC_KEY" >> "${ssh_dir}/authorized_keys"
    chown -R "${APP_USER}:${APP_USER}" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "${ssh_dir}/authorized_keys"

    # Generate host keys if missing
    mkdir -p /etc/ssh
    [[ -f /etc/ssh/ssh_host_rsa_key ]]     || ssh-keygen -t rsa     -f /etc/ssh/ssh_host_rsa_key     -q -N ''
    [[ -f /etc/ssh/ssh_host_ecdsa_key ]]   || ssh-keygen -t ecdsa   -f /etc/ssh/ssh_host_ecdsa_key   -q -N ''
    [[ -f /etc/ssh/ssh_host_ed25519_key ]] || ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -q -N ''

    mkdir -p /run/sshd
    /usr/sbin/sshd
    echo "SSH started (login as: ${APP_USER})."
  else
    echo "PUBLIC_KEY not set — SSH disabled."
  fi
}

# ── Export env vars so they survive into SSH sessions ──────────────────────
export_env_vars() {
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

# ── JupyterLab (runs as non-root user) ────────────────────────────────────
start_jupyter() {
  if [[ -n "${JUPYTER_PASSWORD:-}" ]]; then
    echo "Starting JupyterLab on :8888 as ${APP_USER}..."
    sudo -u "${APP_USER}" nohup python3 -m jupyter lab \
      --allow-root=False --no-browser \
      --port=8888 --ip=* \
      --FileContentsManager.delete_to_trash=False \
      --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
      --IdentityProvider.token="$JUPYTER_PASSWORD" \
      --ServerApp.allow_origin=* \
      --ServerApp.preferred_dir=/workspace \
      > /tmp/jupyter.log 2>&1 &
    echo "JupyterLab started."
  fi
}

echo "=== Pod starting ==="
setup_ssh
export_env_vars
start_jupyter

echo "=== JAX pod ready (user: ${APP_USER}) ==="
sudo -u "${APP_USER}" python3 -c "import jax; print(f'JAX {jax.__version__} — devices: {jax.devices()}')" 2>/dev/null || true

# Drop privileges — PID 1 continues as non-root
echo "Dropping to ${APP_USER}..."
exec gosu "${APP_USER}" sleep infinity