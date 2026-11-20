FROM docker.io/library/python:3.12-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir "litellm[proxy]==1.109.1"

WORKDIR /app
COPY config.yaml /app/config.yaml

EXPOSE 4000

ENTRYPOINT ["litellm", "--config", "/app/config.yaml", "--host", "0.0.0.0", "--port", "4000"]
