# laya 165-CPU-only 专属镜像（权重烘焙 + 多阶段，自包含）
#
# 为什么需要这一版：
#   165 访问外网困难，且 165 拿不到 123 的磁盘路径（/165_model 只是 123 上的 davfs 挂载点，
#   不是 165 本地路径）。所以「权重留 NAS + 使用方软链」对 165 不成立。
#   ⇒ 唯一稳妥形态：权重打进镜像，从 registry 拉下来即可跑，零外部挂载依赖。
#
# 为什么用多阶段而不是 FROM laya-cpu:0.4.31：
#   直接继承老镜像会叠加层，实测 10.3 GB；多阶段只搬最终文件，实测约 3.6 GB。
#
# 构建（在 10.168.3.123；上下文里 models/ = HF 仓库目录 models--convaiinnovations--laya）：
#   docker build -f Dockerfile.embed -t laya-cpu:0.4.31-165 .
ARG PYTHON_IMAGE=python:3.11-slim-trixie

# ---------- stage1：复用已验好的 CPU-only 依赖（只取 venv）----------
FROM laya-cpu:0.4.31 AS deps

# ---------- stage2：干净基座 + venv + 权重 ----------
FROM ${PYTHON_IMAGE}

LABEL org.opencontainers.image.title="Laya CPU-only for 165 (weights embedded, self-contained)" \
      org.opencontainers.image.source="https://github.com/NandhaKishorM/laya" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.description="Weights baked in: english / multilingual / typed-decisions. No external mount."

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    USE_TF=0 \
    USE_TORCH=1 \
    TOKENIZERS_PARALLELISM=false \
    OMP_NUM_THREADS=4 \
    MALLOC_ARENA_MAX=2 \
    LAYA_DEVICE=cpu \
    LAYA_HOST=0.0.0.0 \
    LAYA_PORT=8000 \
    HF_HOME=/models \
    HF_HUB_OFFLINE=1

RUN groupadd --gid 10001 laya \
    && useradd --uid 10001 --gid laya --create-home laya \
    && mkdir -p /models && chown -R laya:laya /models

COPY --from=deps /opt/venv /opt/venv
COPY --from=deps /opt/laya/entrypoint.py /opt/laya/entrypoint.py
COPY --from=deps /usr/share/doc/laya/LICENSE /usr/share/doc/laya/LICENSE

# 标准 HF 缓存布局：blobs/ 实体 + snapshots/<commit>/ 相对软链。
# ⚠️ 必须保留软链与 blobs：hf_hub 2.x 离线校验会拿 trees/<commit>.json 的 blob_id 去 blobs/ 核对；
#    只留 snapshots 实体（无 blobs）会报 LocalEntryNotFoundError（已实测）。
#    Docker 镜像支持软链，故只占 2.3 GB（实体复制会是 4.6 GB）。
# ⚠️ 用 --chown 而不是事后 RUN chown：后者会改写全部文件属主，
#    使这 2.3 GB 在下一层再存一份（实测多出 2.37 GB）。
COPY --chown=laya:laya models/ /models/hub/models--convaiinnovations--laya/

# 构建期自检（只读操作，不产生大层）：三 checkpoint 齐全 + torch/laya 可导入
RUN set -eu; \
    R=/models/hub/models--convaiinnovations--laya; \
    C=$(cat "$R/refs/main"); \
    for f in model.safetensors multilingual/model.safetensors typed-decisions/model.safetensors; do \
        test -s "$R/snapshots/$C/$f" || { echo "缺失 $f"; exit 1; }; \
        echo "  ok $f $(stat -L -c%s "$R/snapshots/$C/$f")"; \
    done; \
    /opt/venv/bin/python -c "import torch,laya; print('torch', torch.__version__)"

USER laya
WORKDIR /home/laya
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
  CMD python -c "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=4).status==200 else 1)"

ENTRYPOINT ["python", "/opt/laya/entrypoint.py"]
CMD ["laya-serve"]
