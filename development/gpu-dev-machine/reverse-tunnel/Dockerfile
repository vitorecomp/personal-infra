FROM docker.io/library/debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    AUTOSSH_GATETIME=0 \
    AUTOSSH_POLL=30

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      autossh ca-certificates openssh-client procps && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 10001 -s /usr/sbin/nologin tunnel && \
    install -d -m 0700 -o tunnel -g tunnel /data

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER tunnel
WORKDIR /home/tunnel

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
