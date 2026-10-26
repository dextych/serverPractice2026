# Стенд overlay mesh (netns + nftables + Nebula) в одном контейнере.
# Нужен --privileged: netns, sysctl внутри них и tun недоступны в обычном контейнере.
FROM debian:bookworm-slim

ARG NEBULA_VERSION=1.9.7
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash make iproute2 nftables iputils-ping tcpdump conntrack procps python3 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Бинарники Nebula с проверкой sha256 (суммы из SHASUM256.txt релиза v1.9.7).
# При смене NEBULA_VERSION нужно обновить и суммы.
RUN set -eu; \
    arch="${TARGETARCH:-amd64}"; \
    case "$arch" in \
      amd64) sum=b748bd78b81e8a484ec7e35ad1c620807397c978780e8322d2148b87041e6525 ;; \
      arm64) sum=009d98724cb430d911cdc53ea9e16373ff7f3d98ada82ec1c09796e6168cddac ;; \
      *) echo "архитектура $arch не поддержана"; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/nebula.tgz \
      "https://github.com/slackhq/nebula/releases/download/v${NEBULA_VERSION}/nebula-linux-${arch}.tar.gz"; \
    echo "${sum}  /tmp/nebula.tgz" | sha256sum -c -; \
    tar -xzf /tmp/nebula.tgz -C /usr/local/bin nebula nebula-cert; \
    rm /tmp/nebula.tgz; \
    nebula -version

WORKDIR /stand
# Контейнер живёт долго: namespace'ы существуют, пока он запущен.
CMD ["sleep", "infinity"]