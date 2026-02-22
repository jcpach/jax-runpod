FROM nvcr.io/nvidia/jax:25.10-py3

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    nginx \
    sudo \
    gosu \
    curl \
    git \
    htop \
    tmux \
    vim \
    wget \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd

# ── Create non-root user with sudo ────────────────────────────────────────
ARG USERNAME=jaxuser
ARG USER_UID=1337
ARG USER_GID=1337

RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash --no-log-init ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

# ── SSH config (hardened) ──────────────────────────────────────────────────
RUN sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/'              /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/'    /etc/ssh/sshd_config \
    && sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/'     /etc/ssh/sshd_config \
    && sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/'                   /etc/ssh/sshd_config \
    && sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/'                      /etc/ssh/sshd_config \
    && echo "AllowUsers ${USERNAME}" >> /etc/ssh/sshd_config

# ── Python packages ───────────────────────────────────────────────────────
# IMPORTANT: The base image has JAX, jaxlib, Flax, and Transformer Engine
# installed from source with NVIDIA's XLA optimizations and custom patches.
# Do NOT pip install jax[cuda] or jax-ai-stack — it would overwrite them
# with generic pip wheels and lose performance tuning.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

# ── nginx proxy (required by RunPod's port routing) ───────────────────────
COPY nginx.conf /etc/nginx/nginx.conf
COPY readme.html /usr/share/nginx/html/readme.html

# ── Entrypoint ─────────────────────────────────────────────────────────────
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENV APP_USER=${USERNAME}
WORKDIR /home/${USERNAME}

EXPOSE 22 8888

CMD ["/start.sh"]