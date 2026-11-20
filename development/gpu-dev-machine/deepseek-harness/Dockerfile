FROM docker.io/library/node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DSH_HOME=/dsh-home \
    NODE_ENV=production

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      bash ca-certificates curl git python3 ripgrep socat && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g "@deepseek-ai/dsh@0.2.2-rc.1" "dsh-gateway-provider@1.1.5" && \
    npm cache clean --force && \
    install -d -m 0755 -o node -g node /dsh-home /workspace

COPY cordis.patch.yml.template /etc/deepseek-harness/cordis.patch.yml.template
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER node
WORKDIR /workspace

EXPOSE 3080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
