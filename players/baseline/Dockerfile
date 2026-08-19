# Build Docker.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/ctf
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NIM_DEFINES=""
# buildDefines feeds artlog meta.json: the full define set this build was
# TOLD to compile with (records intent, not that guarded code exists).
RUN nim c \
  -d:release $NIM_DEFINES \
  -d:useMalloc \
  -d:buildDefines="-d:release $NIM_DEFINES -d:useMalloc" \
  --opt:speed \
  --stackTrace:on \
  --nimcache:/tmp/ctf-nimcache \
  --out:baseline \
  players/baseline/baseline.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/ctf
COPY --from=build /workspace/ctf/baseline /bin/baseline

CMD ["/bin/baseline"]
