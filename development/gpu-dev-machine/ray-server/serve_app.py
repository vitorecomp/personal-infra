#!/usr/bin/env python3
"""Ray Serve LLM entrypoint deploying full (unquantized) DeepSeek-V4.1-Flash with CPU offload."""

from __future__ import annotations

import os
from typing import Any

import ray
from ray import serve
from ray.serve.llm import LLMConfig, build_openai_app


def _env_bool(name: str, default: bool = True) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def main() -> None:
    model_id = os.environ.get("MODEL_ID", "deepseek-ai/DeepSeek-V4.1-Flash")
    model_source = os.environ.get("MODEL_SOURCE", "deepseek-ai/DeepSeek-V4.1-Flash")
    tensor_parallel_size = int(os.environ.get("TENSOR_PARALLEL_SIZE", "4"))
    cpu_offload_gb = float(os.environ.get("CPU_OFFLOAD_GB", "48"))
    engram_cpu_offload = _env_bool("ENGRAM_CPU_OFFLOAD", True)
    gpu_memory_utilization = float(os.environ.get("GPU_MEMORY_UTILIZATION", "0.92"))
    max_model_len = int(os.environ.get("MAX_MODEL_LEN", "65536"))
    kv_cache_dtype = os.environ.get("KV_CACHE_DTYPE", "fp8")
    max_num_seqs = int(os.environ.get("MAX_NUM_SEQS", "8"))
    serve_host = os.environ.get("RAY_SERVE_HOST", "0.0.0.0")
    serve_port = int(os.environ.get("RAY_SERVE_PORT", "8000"))

    # Full unquantized checkpoint (`deepseek-ai/DeepSeek-V4.1-Flash`): no `quantization` override
    # is passed; weights exceeding GPU VRAM are offloaded to host CPU RAM via `cpu_offload_gb`
    # and `engram_config.cpu_offload`.
    engine_kwargs: dict[str, Any] = {
        "tensor_parallel_size": tensor_parallel_size,
        "cpu_offload_gb": cpu_offload_gb,
        "gpu_memory_utilization": gpu_memory_utilization,
        "max_model_len": max_model_len,
        "max_num_seqs": max_num_seqs,
        "kv_cache_dtype": kv_cache_dtype,
        "tokenizer_mode": "deepseek_v41",
        "tool_call_parser": "deepseek_v41",
        "enable_auto_tool_choice": True,
        "reasoning_parser": "deepseek_v41",
        "engram_config": {
            "cpu_offload": engram_cpu_offload,
            "use_thp": True,
        },
        "trust_remote_code": True,
    }

    ray.init(
        num_gpus=tensor_parallel_size,
        include_dashboard=True,
        dashboard_host="0.0.0.0",
        dashboard_port=8265,
    )
    serve.start(http_options={"host": serve_host, "port": serve_port})

    llm_config = LLMConfig(
        model_loading_config={
            "model_id": model_id,
            "model_source": model_source,
        },
        deployment_config={
            "autoscaling_config": {
                "initial_replicas": 1,
                "min_replicas": 1,
                "max_replicas": 1,
            }
        },
        engine_kwargs=engine_kwargs,
    )

    app = build_openai_app({"llm_configs": [llm_config]})
    serve.run(app, blocking=True)


if __name__ == "__main__":
    main()
