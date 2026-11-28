# Streams the GPU VM's journal to the log host over SSH (see entrypoint.sh).
# Ubuntu 24.04 like the GPU host, so journalctl reads the host's journal file format.
FROM docker.io/library/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends ca-certificates openssh-client procps systemd && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
