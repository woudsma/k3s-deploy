# Systemd-enabled Ubuntu that mimics a fresh Hetzner VPS, for testing setup.sh
# end-to-end (K3s is installed via systemd, so the test env needs a real init).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# Packages a fresh Hetzner Ubuntu image already ships with, plus systemd as PID 1.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv \
      curl ca-certificates git openssh-client openssh-server iproute2 sudo \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl enable ssh

# On a real server root already has an authorized_keys (you SSH in with a key).
# setup-deploy.sh reads it, so seed one or the run aborts under `set -e`.
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh \
 && ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -q \
 && cp /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys \
 && chmod 600 /root/.ssh/authorized_keys

# systemd inside a container: clean shutdown signal, boot as init.
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
