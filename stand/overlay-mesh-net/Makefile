# =============================================================================
# Стенд: overlay mesh за NAT + имитация DPI. IPv4 + IPv6, всё в netns на одной машине.
#
#   [hostA]--LAN-A--[natA]--WAN-A--+                +--[ctrl]
#                    (cone)        |                |
#                                 [dpi]--br-inet----+--[relay1]
#                    (random)      |                |
#   [hostB]--LAN-B--[natB]--WAN-B--+                +--[relay2]
#
# Адресация (v4 | v6)
#   LAN-A  10.10.1.0/24      | 2001:db8:a1::/64   hostA .2, natA .1
#   WAN-A  192.0.2.0/24      | 2001:db8:a0::/64   natA .2, dpi .1
#   LAN-B  10.10.2.0/24      | 2001:db8:b1::/64   hostB .2, natB .1
#   WAN-B  198.51.100.0/24   | 2001:db8:b0::/64   natB .2, dpi .1
#   INET   203.0.113.0/24    | 2001:db8:100::/64  dpi .1, ctrl .10, relay1 .11, relay2 .12
#   Overlay (потом, поверх стенда): 100.64.0.0/16
#
# IPv6: NAT нет, на natA/natB stateful firewall (новые входящие с WAN в drop).
# ULA здесь не годится: без NPTv6 ctrl не знает обратный маршрут, поэтому 2001:db8::/32.
#
# Параметры:  make up DPI_MODE=whitelist NETEM="delay 50ms 10ms loss 1%"
#             make dpi DPI_MODE=sig|whitelist|nebula|off     (переприменить DPI без пересборки)
#             make mtu WAN_MTU=1400
# =============================================================================

# =============================================================================
# Где мы: на хосте (управляем контейнером) или внутри контейнера (сам стенд)
#   хост:      make docker-up | docker-down | docker-sh | ...; остальные цели
#              (up, test, nebula-up, ...) прозрачно выполняются внутри контейнера
#   контейнер: обычный Makefile стенда (всё ниже, после else)
# =============================================================================
IN_CONTAINER ?= $(or $(wildcard /.dockerenv),$(wildcard /run/.containerenv))

ifeq ($(IN_CONTAINER),)
# ----------------------------- ХОСТ ------------------------------------------
SHELL         := /bin/bash
MAKEFLAGS     += --no-print-directory
.DEFAULT_GOAL := help

COMPOSE    ?= docker compose
SVC        ?= stand
EXEC_FLAGS ?=
DEXEC       = $(COMPOSE) exec $(EXEC_FLAGS) $(SVC)
DEXEC_NTTY  = $(COMPOSE) exec -T $(EXEC_FLAGS) $(SVC)

# переменные из командной строки (DPI_MODE=..., NETEM=..., NEBULA_PORT=...) уходят внутрь
CLIVARS = $(foreach v,$(.VARIABLES),$(if $(filter command line,$(origin $(v))),$(v)))
FWDARGS = $(foreach v,$(CLIVARS),'$(v)=$($(v))')

HOST_GOALS := help docker-up docker-down docker-build docker-sh docker-ps
FWD_GOALS  := $(filter-out $(HOST_GOALS),$(MAKECMDGOALS))

.PHONY: $(HOST_GOALS) $(FWD_GOALS)

$(FWD_GOALS):
	@$(DEXEC_NTTY) make $@ $(FWDARGS)

help:
	@echo "Контейнер (с хоста, root не нужен, если ты в группе docker):"
	@echo "  make docker-up     собрать образ и поднять контейнер"
	@echo "  make docker-down   остановить и удалить контейнер (стенд и nebula сносятся вместе с ним)"
	@echo "  make docker-build  только пересобрать образ"
	@echo "  make docker-sh     bash внутри контейнера"
	@echo "  make docker-ps     состояние контейнера"
	@echo "Любая другая цель (up, test, nebula-up, sh N=..., ...) выполняется внутри контейнера."
	@echo
	@$(DEXEC) make help 2>/dev/null || echo "(контейнер не запущен: make docker-up)"

docker-up:
	$(COMPOSE) up -d --build
docker-down:
	$(COMPOSE) down
docker-build:
	$(COMPOSE) build
docker-sh:
	$(DEXEC) bash
docker-ps:
	$(COMPOSE) ps

else
# ------------------------- КОНТЕЙНЕР (стенд) ---------------------------------
ifneq ($(shell id -u),0)
ifneq ($(MAKECMDGOALS),help)
$(error Запускать через sudo: sudo make up)
endif
endif

SHELL        := /bin/bash
.SHELLFLAGS  := -ec
MAKEFLAGS    += --no-print-directory
.DEFAULT_GOAL := help

# ---- параметры ---------------------------------------------------------------
DPI_MODE ?= sig
NETEM    ?= delay 15ms 3ms loss 0.25%
WAN_MTU  ?= 1500
N        ?= ns_hostA
IF       ?= any

# ---- имена namespace'ов -----------------------------------------------------
HA   := ns_hostA
NA   := ns_natA
HB   := ns_hostB
NB   := ns_natB
DPI  := ns_dpi
CTRL := ns_ctrl
R1   := ns_relay1
R2   := ns_relay2
NS   := $(HA) $(NA) $(HB) $(NB) $(DPI) $(CTRL) $(R1) $(R2)

X := ip netns exec

# ---- макросы -----------------------------------------------------------------
# mklink(ns1,if1,ns2,if2): veth-пара сразу в двух namespace'ах
mklink  = ip link add $(2) netns $(1) type veth peer name $(4) netns $(3)
# setaddr(ns,if,v4/len,v6/len): адреса (v6 без DAD) и up
setaddr = $(X) $(1) ip addr add $(3) dev $(2) && \
          $(X) $(1) ip -6 addr add $(4) dev $(2) nodad && \
          $(X) $(1) ip link set $(2) up
# defgw(ns,v4gw,v6gw)
defgw   = $(X) $(1) ip route add default via $(2) && \
          $(X) $(1) ip -6 route add default via $(3)
# nft(ns,правило)
nft     = $(X) $(1) nft '$(2)'
# проверки: chk ждёт успех, neg ждёт провал
chk = @if $(X) $(2) $(3) >/dev/null 2>&1; then echo "[ OK ]  $(1)"; else echo "[FAIL]  $(1)"; fi
neg = @if $(X) $(2) $(3) >/dev/null 2>&1; then echo "[FAIL]  $(1) (должно быть недоступно)"; else echo "[ OK ]  $(1): заблокировано, как и задумано"; fi

.PHONY: help up down dpi netem netem-off mtu test test-dpi test-dpi-nebula show cap sh deps control-topology control-status awg-up awg-down awg-test awg-status awg-mesh-up awg-mesh-test awg-mesh-status

help:
	@echo "Цели (всё через sudo):"
	@echo "  make up            развернуть стенд (идемпотентно, сначала down)"
	@echo "  make down          снести стенд"
	@echo "  make test          проверка связности + негативные тесты NAT/firewall"
	@echo "  make test-dpi      отправить WG-подобные пакеты и показать счётчики DPI"
	@echo "  make dpi           переприменить DPI (DPI_MODE=sig|whitelist|off)"
	@echo "  make netem         навесить задержку/потери (NETEM=...), netem-off снимает"
	@echo "  make mtu           WAN_MTU=1400 на всех WAN-линках"
	@echo "  make show          адреса, маршруты, правила nft, conntrack"
	@echo "  make cap N=ns_dpi IF=toA   tcpdump в нужном namespace"
	@echo "  make sh N=ns_hostA         шелл внутри namespace"
	@echo "  make nebula-up [NEBULA_TRANSPORT=awg|raw] [AWG_PORT=443]   Nebula внутри AWG (по умолчанию) или напрямую"
	@echo "  make nebula-test   overlay-ping + путь hostA->hostB (direct/relay)"
	@echo "  make nebula-status | nebula-logs NODE=hostA | nebula-down"
	@echo "  make awg-test [AWG_PORT=443]  AmneziaWG hostA -> relay1 через NAT/DPI"
	@echo "  make awg-status | awg-down"
	@echo "  make control-topology  JSON-описание текущей топологии для backend"
	@echo "  make control-status    фактическое состояние стенда в JSON"
	@echo "  make awg-mesh-up | awg-mesh-test | awg-mesh-status   AWG-underlay для Nebula (10.67.0.0/24)"

deps:
	@for c in ip nft tc ping; do command -v $$c >/dev/null || { echo "нет утилиты: $$c"; exit 1; }; done

up: deps down
	@echo "=== [1/8] namespaces ==="
	@for n in $(NS); do ip netns add $$n; $(X) $$n ip link set lo up; done

	@echo "=== [2/8] veth-линки ==="
	@$(call mklink,$(HA),eth0,$(NA),lan)
	@$(call mklink,$(NA),wan,$(DPI),toA)
	@$(call mklink,$(HB),eth0,$(NB),lan)
	@$(call mklink,$(NB),wan,$(DPI),toB)
	@$(call mklink,$(CTRL),eth0,$(DPI),p-ctrl)
	@$(call mklink,$(R1),eth0,$(DPI),p-r1)
	@$(call mklink,$(R2),eth0,$(DPI),p-r2)

	@echo "=== [3/8] бридж inet-зоны в dpi ==="
	@$(X) $(DPI) ip link add br-inet type bridge
	@for p in p-ctrl p-r1 p-r2; do $(X) $(DPI) ip link set $$p master br-inet; $(X) $(DPI) ip link set $$p up; done
	@$(X) $(DPI) ip link set br-inet up

	@echo "=== [4/8] адреса ==="
	@$(call setaddr,$(HA),eth0,10.10.1.2/24,2001:db8:a1::2/64)
	@$(call setaddr,$(NA),lan,10.10.1.1/24,2001:db8:a1::1/64)
	@$(call setaddr,$(NA),wan,192.0.2.2/24,2001:db8:a0::2/64)
	@$(call setaddr,$(DPI),toA,192.0.2.1/24,2001:db8:a0::1/64)
	@$(call setaddr,$(HB),eth0,10.10.2.2/24,2001:db8:b1::2/64)
	@$(call setaddr,$(NB),lan,10.10.2.1/24,2001:db8:b1::1/64)
	@$(call setaddr,$(NB),wan,198.51.100.2/24,2001:db8:b0::2/64)
	@$(call setaddr,$(DPI),toB,198.51.100.1/24,2001:db8:b0::1/64)
	@$(call setaddr,$(DPI),br-inet,203.0.113.1/24,2001:db8:100::1/64)
	@$(call setaddr,$(CTRL),eth0,203.0.113.10/24,2001:db8:100::10/64)
	@$(call setaddr,$(R1),eth0,203.0.113.11/24,2001:db8:100::11/64)
	@$(call setaddr,$(R2),eth0,203.0.113.12/24,2001:db8:100::12/64)

	@echo "=== [5/8] маршруты и forwarding ==="
	@$(call defgw,$(HA),10.10.1.1,2001:db8:a1::1)
	@$(call defgw,$(NA),192.0.2.1,2001:db8:a0::1)
	@$(call defgw,$(HB),10.10.2.1,2001:db8:b1::1)
	@$(call defgw,$(NB),198.51.100.1,2001:db8:b0::1)
	@$(call defgw,$(CTRL),203.0.113.1,2001:db8:100::1)
	@$(call defgw,$(R1),203.0.113.1,2001:db8:100::1)
	@$(call defgw,$(R2),203.0.113.1,2001:db8:100::1)
	@# v6 без NAT: dpi должен знать, что LAN-префиксы лежат за NAT-роутерами
	@$(X) $(DPI) ip -6 route add 2001:db8:a1::/64 via 2001:db8:a0::2
	@$(X) $(DPI) ip -6 route add 2001:db8:b1::/64 via 2001:db8:b0::2
	@for n in $(NA) $(NB) $(DPI); do $(X) $$n sysctl -q -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1; done

	@echo "=== [6/8] NAT (v4) + stateful firewall (v4/v6) на natA/natB ==="
	@# natA: обычный masquerade (порт сохраняется, cone-подобный)
	@$(call nft,$(NA),add table ip nat)
	@$(call nft,$(NA),add chain ip nat postrouting { type nat hook postrouting priority 100; })
	@$(call nft,$(NA),add rule ip nat postrouting oifname "wan" masquerade)
	@# natB: masquerade random (порт случайный на каждое соединение, symmetric-подобный)
	@$(call nft,$(NB),add table ip nat)
	@$(call nft,$(NB),add chain ip nat postrouting { type nat hook postrouting priority 100; })
	@$(call nft,$(NB),add rule ip nat postrouting oifname "wan" masquerade random)
	@for n in $(NA) $(NB); do \
	  $(X) $$n nft add table inet fw; \
	  $(X) $$n nft 'add chain inet fw forward { type filter hook forward priority 0; policy drop; }'; \
	  $(X) $$n nft 'add rule inet fw forward ct state established accept'; \
	  $(X) $$n nft 'add rule inet fw forward ct state related accept'; \
	  $(X) $$n nft 'add rule inet fw forward iifname "lan" accept'; \
	done

	@echo "=== [7/8] DPI + параметры канала ==="
	@$(MAKE) dpi netem mtu

	@echo "=== [8/8] готово. Проверка: sudo make test ==="

down: nebula-down awg-down
	@echo "=== Удаление стенда ==="
	-@for n in $(NS); do ip netns del $$n 2>/dev/null; done; true

# ---- DPI --------------------------------------------------------------------
dpi:
	@$(X) $(DPI) nft delete table inet dpi 2>/dev/null || true
	@$(X) $(DPI) nft add table inet dpi
	@$(X) $(DPI) nft 'add chain inet dpi forward { type filter hook forward priority 0; policy accept; }'
ifeq ($(DPI_MODE),sig)
	@# сигнатуры WireGuard: initiation (156 байт, тип 1) и response (92 байта, тип 2)
	@$(X) $(DPI) nft 'add rule inet dpi forward udp length 156 @th,64,32 0x01000000 counter drop comment "wg-init"'
	@$(X) $(DPI) nft 'add rule inet dpi forward udp length 92 @th,64,32 0x02000000 counter drop comment "wg-resp"'
	@echo "DPI: режим sig (режем WG-хендшейки)"
else ifeq ($(DPI_MODE),nebula)
	@# Nebula header: [ver<<4|type][subtype][reserved 2B][remote_idx 4B][counter 8B]
	@# handshake = ver1/type0/subtype0 -> первые 4 байта payload = 10 00 00 00
	@# UDP-заголовок = 8 байт = 64 бита, поэтому payload начинается с @th,64
	@$(X) $(DPI) nft 'add rule inet dpi forward meta l4proto udp @th,64,32 { 0x10000000, 0x11000000 } counter drop comment "nebula-all"'
	@echo "DPI: режим nebula (режем хендшейки Nebula)"
else ifeq ($(DPI_MODE),whitelist)
	@$(X) $(DPI) nft 'add rule inet dpi forward udp dport != { 53, 443 } udp sport != { 53, 443 } counter drop comment "udp-whitelist"'
	@echo "DPI: режим whitelist (UDP только 53/443)"
else
	@echo "DPI: режим off (фильтрация отключена)"
endif

# ---- параметры канала -------------------------------------------------------
netem:
	@for i in toA toB br-inet; do $(X) $(DPI) tc qdisc replace dev $$i root netem $(NETEM); done
	@echo "netem на dpi (в каждую сторону): $(NETEM)"

netem-off:
	@for i in toA toB br-inet; do $(X) $(DPI) tc qdisc del dev $$i root 2>/dev/null || true; done

mtu:
	@$(X) $(NA)  ip link set wan  mtu $(WAN_MTU)
	@$(X) $(DPI) ip link set toA  mtu $(WAN_MTU)
	@$(X) $(NB)  ip link set wan  mtu $(WAN_MTU)
	@$(X) $(DPI) ip link set toB  mtu $(WAN_MTU)
	@echo "MTU WAN-линков: $(WAN_MTU)"

# ---- тесты ------------------------------------------------------------------
test:
	@echo "=== Связность (v4/v6) ==="
	$(call chk,hostA -> natA v4,$(HA),ping -c1 -W2 10.10.1.1)
	$(call chk,hostA -> natA v6,$(HA),ping -6 -c1 -W2 2001:db8:a1::1)
	$(call chk,hostA -> ctrl   v4,$(HA),ping -c1 -W2 203.0.113.10)
	$(call chk,hostA -> ctrl   v6,$(HA),ping -6 -c1 -W2 2001:db8:100::10)
	$(call chk,hostA -> relay1 v4,$(HA),ping -c1 -W2 203.0.113.11)
	$(call chk,hostA -> relay2 v6,$(HA),ping -6 -c1 -W2 2001:db8:100::12)
	$(call chk,hostB -> ctrl   v4,$(HB),ping -c1 -W2 203.0.113.10)
	$(call chk,hostB -> ctrl   v6,$(HB),ping -6 -c1 -W2 2001:db8:100::10)
	$(call chk,ctrl -> relay1 (L2 bridge),$(CTRL),ping -c1 -W2 203.0.113.11)
	@echo "=== Негативные: NAT/firewall не должны пускать снаружи ==="
	$(call neg,hostB -> hostA v4,$(HB),ping -c1 -W2 10.10.1.2)
	$(call neg,hostB -> hostA v6,$(HB),ping -6 -c1 -W2 2001:db8:a1::2)
	@echo "=== Проверка трансляции: ctrl должен видеть natA, а не hostA ==="
	@$(X) $(HA) ping -c1 -W2 203.0.113.10 >/dev/null 2>&1 || true
	@if command -v conntrack >/dev/null; then $(X) $(NA) conntrack -L 2>/dev/null | head -n 5; else echo "(conntrack-tools не установлен, смотри tcpdump: make cap N=$(CTRL) IF=eth0)"; fi

test-dpi:
	@echo "=== Шлём 3+3 пакета, похожих на WG initiation (UDP len 156, тип 1) ==="
	@$(X) $(HA) python3 -c "import socket as k; p=bytes([1,0,0,0])+bytes(144); [k.socket(f,k.SOCK_DGRAM).sendto(p,(a,51820)) for f,a in ((k.AF_INET,'203.0.113.10'),(k.AF_INET6,'2001:db8:100::10')) for _ in range(3)]"
	@$(X) $(DPI) nft list table inet dpi

test-dpi-nebula:
	@echo "=== 3+3 Nebula-подобных пакета (handshake 0x10 и data 0x11), v4+v6 ==="
	@$(X) $(HA) python3 -c "import socket as k; hs=bytes([16,0,0,0])+bytes(4)+(1).to_bytes(8,'big')+bytes(184); dt=bytes([17,0,0,0])+bytes(4)+(2).to_bytes(8,'big')+bytes(184); [k.socket(f,k.SOCK_DGRAM).sendto(p,(a,4242)) for f,a in ((k.AF_INET,'203.0.113.10'),(k.AF_INET6,'2001:db8:100::10')) for p in (hs,dt) for _ in range(3)]"
	@$(X) $(DPI) nft list table inet dpi

# ---- отладка ----------------------------------------------------------------
show:
	@for n in $(NS); do printf '\n[%s]\n' $$n; $(X) $$n ip -br addr; done
	@printf '\n=== маршруты dpi ===\n'; $(X) $(DPI) ip route; $(X) $(DPI) ip -6 route
	@printf '\n=== nft: nat/firewall ===\n'; $(X) $(NA) nft list ruleset; $(X) $(NB) nft list ruleset
	@printf '\n=== nft: dpi ===\n'; $(X) $(DPI) nft list ruleset
	@printf '\n=== qdisc dpi ===\n'; $(X) $(DPI) tc qdisc show

cap:
	$(X) $(N) tcpdump -ni $(IF)

sh:
	$(X) $(N) bash

# ---- Nebula (nebula.sh) -------------------------------------------------
NEBULA_SH ?= ./nebula.sh
NODE      ?= hostA

.PHONY: nebula-up nebula-down nebula-test nebula-status nebula-logs
nebula-up:
	@$(NEBULA_SH) up
nebula-down:
	-@$(NEBULA_SH) down 2>/dev/null
nebula-test:
	@$(NEBULA_SH) test
nebula-status:
	@$(NEBULA_SH) status
nebula-logs:
	@$(NEBULA_SH) logs $(NODE)

# ---- AmneziaWG: userspace-туннель hostA -> relay1 ----------------------------
AWG_SH   ?= ./awg.sh
AWG_PORT ?= 51820
awg-up:
	@AWG_PORT=$(AWG_PORT) $(AWG_SH) up
awg-down:
	-@$(AWG_SH) down 2>/dev/null
awg-test:
	@AWG_PORT=$(AWG_PORT) $(AWG_SH) up
	@$(AWG_SH) test
awg-status:
	@$(AWG_SH) status
awg-mesh-up:
	@AWG_PORT=$(AWG_PORT) $(AWG_SH) mesh-up
awg-mesh-test:
	@AWG_PORT=$(AWG_PORT) $(AWG_SH) mesh-up
	@$(AWG_SH) mesh-test
awg-mesh-status:
	@$(AWG_SH) mesh-status

# ---- Control contract (read-only JSON interface) ----------------------------
control-topology:
	@python3 ./scripts/control.py topology --json

control-status:
	@python3 ./scripts/control.py status --json

endif