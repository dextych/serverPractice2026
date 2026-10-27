# Сборка userspace-реализации AmneziaWG и её утилит.
# Используем userspace, чтобы не требовать AmneziaWG kernel module на хосте.
FROM golang:1.25.12-bookworm AS awg-build
ARG AWG_GO_REF=master
ARG AWG_TOOLS_REF=v3.1.20260812
RUN apt-get update && apt-get install -y --no-install-recommends \
    git make gcc libc6-dev python3 \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${AWG_GO_REF}" \
    https://github.com/amnezia-vpn/amneziawg-go.git /src/amneziawg-go \
    && python3 -c 'from pathlib import Path; p = Path("/src/amneziawg-go/main.go"); s = p.read_text(); start = s.index("func warning() {"); end = s.index("\nfunc main() {", start); p.write_text(s[:start] + "func warning() {}" + s[end:])' \
    && make -C /src/amneziawg-go \
    && install -D -m 0755 /src/amneziawg-go/amneziawg-go /out/usr/bin/amneziawg-go
RUN git clone --depth 1 --branch "${AWG_TOOLS_REF}" https://github.com/amnezia-vpn/amneziawg-tools.git /src/amneziawg-tools \
    && make -C /src/amneziawg-tools/src \
    && install -D -m 0755 /src/amneziawg-tools/src/wg /out/usr/bin/awg \
    && install -D -m 0755 /src/amneziawg-tools/src/wg-quick/linux.bash /out/usr/bin/awg-quick \
    && ln -s awg /out/usr/bin/wg \
    && ln -s awg-quick /out/usr/bin/wg-quick

# Стенд overlay mesh (netns + nftables + Nebula + AmneziaWG) в одном контейнере.
# Нужен --privileged: netns, sysctl внутри них и tun недоступны в обычном контейнере.
FROM debian:bookworm-slim
COPY --from=awg-build /out/usr/bin/awg /usr/bin/awg
COPY --from=awg-build /out/usr/bin/awg-quick /usr/bin/awg-quick
COPY --from=awg-build /out/usr/bin/amneziawg-go /usr/bin/amneziawg-go

RUN ln -s /usr/bin/awg /usr/bin/wg \
    && ln -s /usr/bin/awg-quick /usr/bin/wg-quick

ENV WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go

ARG NEBULA_VERSION=1.9.7
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash make iproute2 nftables iptables iputils-ping tcpdump conntrack procps python3 curl ca-certificates \
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