# Base image includes CUDA, FlashInfer, and vLLM v0.33.0 with native DeepSeek-V4.1-Flash support.
# Fully-qualified registry path is required for unqualified Podman builds.
FROM docker.io/vllm/vllm-openai:v0.33.0

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/mnt/data/huggingface \
    VLLM_ENGINE_READY_TIMEOUT_S=7200 \
    VLLM_USE_V2_MODEL_RUNNER=1

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends curl procps && \
    rm -rf /var/lib/apt/lists/*

# Install Ray Serve LLM while keeping the base image's vLLM build pinned.
RUN pip install --no-cache-dir "ray[serve,llm]==2.60.0" "vllm==0.33.0"

WORKDIR /app
COPY serve_app.py /app/serve_app.py

EXPOSE 8000 8265

ENTRYPOINT ["python3", "/app/serve_app.py"]
