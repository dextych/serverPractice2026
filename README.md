# Стенд: overlay mesh за NAT с имитацией DPI

Воспроизводимый сетевой стенд на одной машине (Linux network namespaces + veth + nftables), упакованный в Docker-контейнер.
Нужен, чтобы проверять обфускацию транспорта, NAT-traversal и overlay-сеть (Nebula и аналоги) в условиях, близких к реальной фильтрации. Поддерживаются IPv4 и IPv6.

Весь стенд, включая nft-таблицы, veth и namespace'ы, живёт внутри контейнера и не трогает сетевые настройки хоста. Удаляется одной командой: `make docker-down`.

## Содержание

1. [Требования](#требования)
2. [Состав репозитория](#состав-репозитория)
3. [Топология и адресация](#топология-и-адресация)
4. [Быстрый старт](#быстрый-старт)
5. [Команды](#команды)
6. [Параметры](#параметры)
7. [Как работать со стендом](#как-работать-со-стендом)
8. [Nebula поверх стенда](#nebula-поверх-стенда)
9. [AmneziaWG](#amneziawg)
10. [Сценарии экспериментов](#сценарии-экспериментов)
11. [Устройство NAT и DPI](#устройство-nat-и-dpi)
12. [Частые проблемы](#частые-проблемы)
13. [Ограничения](#ограничения)

## Требования

На хосте:

- Linux, Docker и плагин Compose (`docker compose`), `make`.
- Пользователь в группе `docker` (иначе `sudo make docker-up`). `sudo` для остальных целей не нужен: они выполняются внутри контейнера от root.
- Ядро хоста с нужными опциями (контейнер использует ядро хоста, образ их не принесёт): `CONFIG_NET_NS`, `VETH`, `BRIDGE`, `NF_TABLES`, `NFT_NAT`, `NFT_MASQ`, `NF_CONNTRACK`, `NET_SCH_NETEM`, а для Nebula и AmneziaWG ещё `TUN` (и существующий `/dev/net/tun`).
  Для DPI на Suricata дополнительно `NFT_QUEUE`.

Быстрая проверка ядра:

```bash
zcat /proc/config.gz | grep -E 'CONFIG_(NET_NS|VETH|BRIDGE|NF_TABLES|NFT_NAT|NFT_MASQ|NF_CONNTRACK|NET_SCH_NETEM|TUN)[= ]'
ls -l /dev/net/tun
```

Каждая опция должна быть `=y` или `=m` (модуль должен быть загружен или подгружаться сам).

Всё остальное (`iproute2`, `nftables`, `tcpdump`, `conntrack`, `python3`, `sysctl`, Nebula) уже есть в образе. Контейнер запускается с `privileged: true`: без этого в нём нельзя создавать namespace'ы и писать sysctl внутри них. Rootless Docker и rootless Podman не подойдут.

Без Docker (напрямую на хосте, от root): `sudo make IN_CONTAINER=1 up`. Тогда утилиты и Nebula нужно поставить самому.

## Состав репозитория

| Файл | Назначение |
|---|---|
| `Makefile` | на хосте управляет контейнером, внутри контейнера строит и обслуживает стенд |
| `nebula.sh` | поднимает Nebula-overlay поверх стенда (сертификаты, конфиги, запуск, тесты) |
| `awg.sh` | поднимает AmneziaWG между `hostA` и `relay1`, генерирует локальные ключи и проверяет туннель |
| `Dockerfile` | образ: Debian bookworm-slim, утилиты, Nebula 1.9.7 с проверкой sha256 |
| `docker-compose.yml` | сервис `stand` (контейнер `mesh-stand`), `privileged`, репозиторий монтируется в `/stand` |
| `README.md` | этот файл |

Репозиторий монтируется в контейнер, поэтому правки `Makefile` и `nebula.sh` на хосте видны сразу, без пересборки образа. Пересборка нужна только при изменении `Dockerfile`.

## Топология и адресация

```
[hostA]--LAN-A--[natA]--WAN-A--+                  +--[ctrl]
                (cone)         |                  |
                             [dpi]---br-inet------+--[relay1]
                (random)       |                  |
[hostB]--LAN-B--[natB]--WAN-B--+                  +--[relay2]
```

| Зона | IPv4 | IPv6 | Узлы |
|---|---|---|---|
| LAN-A | 10.10.1.0/24 | 2001:db8:a1::/64 | hostA `.2`, natA `.1` |
| WAN-A | 192.0.2.0/24 | 2001:db8:a0::/64 | natA `.2`, dpi `.1` |
| LAN-B | 10.10.2.0/24 | 2001:db8:b1::/64 | hostB `.2`, natB `.1` |
| WAN-B | 198.51.100.0/24 | 2001:db8:b0::/64 | natB `.2`, dpi `.1` |
| INET | 203.0.113.0/24 | 2001:db8:100::/64 | dpi `.1`, ctrl `.10`, relay1 `.11`, relay2 `.12` |
| Overlay | 100.64.0.0/16 | | создаётся командой `make nebula-up`, см. [Nebula поверх стенда](#nebula-поверх-стенда) |

Namespace'ы: `ns_hostA`, `ns_natA`, `ns_hostB`, `ns_natB`, `ns_dpi`, `ns_ctrl`, `ns_relay1`, `ns_relay2`.

Интерфейсы: у хостов, ctrl и relay'ев `eth0`; у NAT'ов `lan` и `wan`; в `ns_dpi` это `toA`, `toB` (к NAT'ам) и бридж `br-inet` (к inet-зоне).

Роли узлов:

| Узел | Роль в стенде | Роль в Nebula |
|---|---|---|
| hostA, hostB | клиенты за NAT | обычные ноды overlay |
| natA | NAT с сохранением порта (cone-подобный) | |
| natB | NAT со случайным портом (symmetric-подобный, «тяжёлый» случай для hole punching) | |
| dpi | транзитный роутер между NAT'ами и «интернетом»: фильтрация (имитация ТСПУ) и параметры канала | |
| ctrl | контроллер | lighthouse |
| relay1, relay2 | relay-узлы и точки выхода | relay |

### IPv6

NAT для IPv6 не используется. На natA и natB работает stateful firewall: исходящие с LAN разрешены, входящие новые с WAN отбрасываются. Используются префиксы `2001:db8::/32` (документационные). ULA здесь не подходит: без NPTv6 у ctrl нет обратного маршрута.

## Быстрый старт

```bash
make docker-up      # собрать образ и поднять контейнер
make up             # развернуть стенд внутри контейнера
make test           # проверить связность и NAT/firewall
make test-dpi       # убедиться, что DPI режет WireGuard-подобные пакеты
make nebula-up      # поднять Nebula-overlay
make nebula-test    # проверить overlay и путь hostA -> hostB (direct/relay)
make awg-test       # проверить AmneziaWG hostA -> relay1 через NAT/DPI
make docker-down    # снести всё вместе с контейнером
```

Ожидаемый результат `make test`: все строки `[ OK ]`, включая негативные («заблокировано, как и задумано»). Любой `[FAIL]` значит ошибку в сборке стенда.

`make up` идемпотентен: перед сборкой он всегда вызывает `down` (который заодно останавливает Nebula).

Как это работает: Makefile сам определяет, где он запущен (по `/.dockerenv` или `/run/.containerenv`).

- На хосте цели `docker-*` управляют контейнером, а любая другая цель (`up`, `test`, `cap`, `nebula-up` и т. д.) прозрачно выполняется внутри контейнера как `docker compose exec stand make <цель>`. Переменные из командной строки (`DPI_MODE=...`, `NETEM=...`, `NEBULA_PORT=...`) пробрасываются внутрь.
- Внутри контейнера работает сам стенд.

## Команды

### Контейнер (выполняются на хосте)

| Команда | Что делает |
|---|---|
| `make docker-up` | собрать образ и (пере)создать контейнер (`compose up -d --build`) |
| `make docker-down` | остановить и удалить контейнер; стенд и Nebula исчезают вместе с ним |
| `make docker-build` | только пересобрать образ |
| `make docker-sh` | `bash` в контейнере (из него можно вызывать `ip netns exec ...` напрямую) |
| `make docker-ps` | состояние контейнера |

### Стенд (на хосте уходят в контейнер, внутри выполняются как есть)

| Команда | Что делает |
|---|---|
| `make help` | список команд (работает без root; на хосте показывает и команды контейнера) |
| `make up` | собрать стенд целиком |
| `make down` | остановить Nebula и удалить все namespace'ы |
| `make test` | связность по v4/v6 + негативные проверки NAT и firewall |
| `make test-dpi` | отправить WG-подобные пакеты и показать счётчики DPI |
| `make test-dpi-nebula` | отправить Nebula-подобные пакеты (handshake `0x10`, data `0x11`) и показать счётчики DPI |
| `make dpi` | переприменить правила DPI (режим из `DPI_MODE`) |
| `make netem` / `make netem-off` | задать / снять задержку и потери |
| `make mtu` | выставить MTU на WAN-линках (`WAN_MTU`) |
| `make show` | адреса, маршруты, правила nft, qdisc |
| `make cap N=<ns> IF=<iface>` | `tcpdump` внутри namespace |
| `make sh N=<ns>` | интерактивный шелл внутри namespace |

### Nebula

| Команда | Что делает |
|---|---|
| `make nebula-up` | сгенерировать сертификаты и конфиги, запустить все ноды (lighthouse, relay'и, хосты) |
| `make nebula-test` | overlay-ping между нодами и определение пути hostA -> hostB (прямой или через relay) |
| `make nebula-status` | интерфейсы `nebula1` во всех namespace'ах |
| `make nebula-logs NODE=hostA` | лог ноды (`lh`, `relay1`, `relay2`, `hostA`, `hostB`) |
| `make nebula-down` | остановить Nebula (стенд остаётся) |
| `make awg-up [AWG_PORT=443]` | поднять AmneziaWG между `hostA` и `relay1` |
| `make awg-test [AWG_PORT=443]` | поднять туннель, проверить ping и вывести состояние |
| `make awg-status` | состояние AWG-интерфейсов и последнего handshake |
| `make awg-down` | остановить AmneziaWG (стенд остаётся) |

## Параметры

Передаются в командной строке: `make up DPI_MODE=whitelist NETEM="delay 50ms 10ms loss 1%"`.

### Стенд

| Параметр | По умолчанию | Описание |
|---|---|---|
| `DPI_MODE` | `sig` | `sig`: режем сигнатуры WireGuard; `nebula`: режем хендшейки и данные Nebula; `whitelist`: пропускаем только UDP с портом 53/443; `off`: DPI выключен |
| `NETEM` | `delay 15ms 3ms loss 0.25%` | параметры `tc netem`; применяются в каждую сторону |
| `WAN_MTU` | `1500` | MTU WAN-линков (natA↔dpi, natB↔dpi) |
| `N` | `ns_hostA` | namespace для `cap` и `sh` |
| `IF` | `any` | интерфейс для `cap` |

Задержка навешивается на `toA`, `toB` и `br-inet` в `ns_dpi`, поэтому RTT примерно вдвое больше значения `delay`.

### Nebula

| Параметр | По умолчанию | Описание |
|---|---|---|
| `NEBULA_PORT` | `4242` | порт lighthouse и relay'ев; под `DPI_MODE=whitelist` ставить `443` |
| `NEBULA_CLIENT_PORT` | `0` | порт hostA и hostB (`0` = случайный) |
| `NEBULA_V6` | `1` | `0` = только IPv4 (позволяет смотреть relay-путь без IPv6) |
| `NEBULA_MTU` | `1300` | MTU интерфейса `nebula1` |
| `NEBULA_LOG` | `info` | уровень логов (`debug` для разбора handshake и relay) |
| `NODE` | `hostA` | нода для `make nebula-logs` |
| `NEBULA_SH` | `./nebula.sh` | путь к скрипту |

### Контейнер

| Параметр | По умолчанию | Описание |
|---|---|---|
| `COMPOSE` | `docker compose` | команда Compose (для старого бинарника: `COMPOSE=docker-compose`) |
| `SVC` | `stand` | имя сервиса в `docker-compose.yml` |
| `EXEC_FLAGS` | пусто | флаги `compose exec`; `-T` отключает TTY (для скриптов и cron) |
| `IN_CONTAINER` | авто | принудительно задать режим: `1` = работать как внутри контейнера, пусто = как на хосте |

## Как работать со стендом

### Запуск команд внутри узла

Все команды ниже выполняются внутри контейнера (`make docker-sh`), поэтому `sudo` не нужен:

```bash
make docker-sh
ip netns exec ns_hostA ping -c3 203.0.113.10
ip netns exec ns_relay1 ss -ulnp
```

То же без входа в контейнер: `make sh N=ns_hostB` (шелл внутри namespace) или `docker compose exec stand ip netns exec ns_hostA ping -c3 203.0.113.10`.

Любой сервис (Nebula, Hysteria2, AmneziaWG) запускается так же: `ip netns exec ns_relay1 <команда>`. Бинарники и конфиги должны быть внутри контейнера; репозиторий доступен там как `/stand`.

### Наблюдение за трафиком

```bash
make cap N=ns_dpi IF=toA        # то, что приходит на dpi со стороны WAN-A (уже после NAT)
make cap N=ns_natA IF=lan       # трафик клиента до NAT
make cap N=ns_natA IF=wan       # он же после NAT
make cap N=ns_ctrl IF=eth0      # что видит контроллер
```

Сравнение `lan` и `wan` на NAT-узле показывает подмену адреса и порта. На ctrl исходный адрес клиента не виден никогда.

Чтобы сохранить pcap для отчёта, пишите в смонтированный репозиторий: `make sh N=ns_dpi`, затем `tcpdump -ni toA -w /stand/dpi-toA.pcap`. Файл появится в репозитории на хосте с владельцем root.

### Таблица трансляций

```bash
make sh N=ns_natA     # затем: conntrack -L
make sh N=ns_natB
```

### Счётчики DPI

```bash
make sh N=ns_dpi      # затем: nft list table inet dpi
```

Счётчик `counter` у каждого правила показывает число отброшенных пакетов. Именно эти цифры идут в отчёт как доказательство работы фильтрации.

### Остановка

`make docker-down` удаляет контейнер, а вместе с ним все namespace'ы и процессы внутри них. Порядок остановки соблюдать не нужно.

Если нужно снести только стенд, оставив контейнер: `make down` (он сам вызывает `nebula-down`, чтобы процессы не повисли в удалённых namespace'ах).

## Nebula поверх стенда

`nebula.sh` разворачивает Nebula-overlay `100.64.0.0/16` поверх стенда и ничего в самом стенде не меняет.

| Нода | Namespace | Адрес в overlay | Роль |
|---|---|---|---|
| `lh` | `ns_ctrl` | 100.64.0.1 | lighthouse |
| `relay1` | `ns_relay1` | 100.64.0.21 | relay |
| `relay2` | `ns_relay2` | 100.64.0.22 | relay |
| `hostA` | `ns_hostA` | 100.64.0.11 | обычная нода за natA |
| `hostB` | `ns_hostB` | 100.64.0.12 | обычная нода за natB |

Порядок запуска: lighthouse, затем relay'и, затем хосты. Хосты знают lighthouse по IPv4 и IPv6 (если `NEBULA_V6=1`) и используют оба relay'я.

```bash
make up DPI_MODE=off
make nebula-up
make nebula-test
make nebula-logs NODE=hostA
```

### Что делает `nebula-test`

1. Пингует по overlay: hostA и hostB до lighthouse, hostA до relay1, hostB до relay2, hostA ↔ hostB.
2. Определяет путь hostA -> hostB. Для этого на `ns_dpi` (интерфейс `toA`) ловятся зашифрованные пакеты размером больше 150 байт между внешними адресами natA и natB. Если такие пакеты есть, соединение прямое. Если нет, трафик идёт через relay. Однобайтовые punch-пакеты в счёт не идут.

### Чего ожидать

- **IPv4.** natB делает `masquerade random`, поэтому hole punching между hostA и hostB, скорее всего, не удастся и трафик пойдёт через relay.
- **IPv6.** NAT нет, а stateful firewall пропускает ответы на исходящее. Если обе стороны одновременно шлют друг другу пакеты, прямое соединение возможно даже при natB. Это нужно проверять, `nebula-test` покажет результат.
- **Только IPv4.** Запуск с `NEBULA_V6=0` показывает чистый relay-путь без IPv6.

### Где лежат файлы

Сертификаты, конфиги, логи и pid-файлы лежат в `/var/tmp/nebula-lab` внутри контейнера. Они переживают `docker compose stop` и `start`, но удаляются вместе с контейнером (`make docker-down`). CA и сертификаты при следующем `nebula-up` создаются заново.

Конфиги генерируются при каждом `nebula-up`, поэтому смена `NEBULA_PORT`, `NEBULA_V6`, `NEBULA_MTU` и других параметров применяется сразу, пересоздавать сертификаты не нужно.

Firewall внутри overlay в конфигах открыт полностью, чтобы не мешать тестам. Для реальных нод так делать нельзя.

### MTU

Накладные расходы Nebula: около 32 байт собственного заголовка и тега плюс UDP и IP (всего около 60 байт по IPv4 и 80 по IPv6). При `WAN_MTU=1400` потолок для `NEBULA_MTU` около 1340 по IPv4 и 1320 по IPv6.

## Nebula поверх AmneziaWG

По умолчанию (`NEBULA_TRANSPORT=awg`) Nebula работает **внутри** AmneziaWG, а не рядом с ним.
`make nebula-up` сам поднимает underlay `10.67.0.0/24`, затем стартует Nebula. Каждая нода биндит
UDP-сокет на свой адрес underlay, поэтому её пакеты физически не могут уйти в `eth0` мимо AWG.
На проводе (на `ns_dpi`) остаётся только AWG на `AWG_PORT`.

```text
overlay Nebula     100.64.0.x        lighthouse / relay / хосты
underlay AWG       10.67.0.x         u-lh, u-r1, u-r2, u-hA, u-hB
сеть стенда        NAT, DPI, netem   видны только UDP/AWG_PORT
```

| Underlay | Пиры |
|----------|------|
| хабы `lh`, `relay1`, `relay2` | полносвязны между собой, слушают `AWG_PORT` |
| клиенты `hostA`, `hostB` | к каждому хабу, `PersistentKeepalive 25` (держит маппинг в NAT) |
| `hostA` <-> `hostB` | **пира нет**: WireGuard не умеет hole punching, а natB его ломает. Overlay между клиентами идёт через Nebula-relay, и этот relay-трафик тоже внутри AWG |

Nebula-ноды анонсируют lighthouse'у только адрес underlay (`local_allow_list`), а хосты ходят
только к хабам (`remote_allow_list`), поэтому к соседу напрямую не лезут.

```bash
make up DPI_MODE=sig
make nebula-up
make nebula-test         # overlay-ping + проверка утечек мимо AWG

# белый список UDP/443: теперь порт важен только для AWG
make dpi DPI_MODE=whitelist
make nebula-up AWG_PORT=443

# DPI режет сигнатуры Nebula: в режиме awg handshake'и снаружи не видны
make dpi DPI_MODE=nebula
make nebula-up
make nebula-test         # проходит; счётчик nebula-all на dpi остаётся 0

# базовая линия для сравнения (старое поведение, Nebula рядом с AWG)
make nebula-up NEBULA_TRANSPORT=raw
```

Что проверяет `nebula-test` в режиме `awg`:

1. overlay-ping между нодами;
2. на `ns_dpi` не должно быть ни одного UDP-пакета, у которого ни sport, ни dport не равны `AWG_PORT`;
3. контрольный счёт: AWG-пакеты на проводе есть (иначе проверка слепая);
4. между внешними адресами natA и natB нет прямого трафика: `hostA -> hostB` идёт только через relay.

Параметры: `NEBULA_TRANSPORT=awg|raw`, `AWG_PORT` (по умолчанию 51820), `AWG_MTU` (по умолчанию 1420).
MTU: `AWG_MTU <= WAN_MTU - 80`, `NEBULA_MTU <= AWG_MTU - 60`. При `WAN_MTU=1400`: `AWG_MTU=1320`, `NEBULA_MTU<=1260`.
Underlay только IPv4, `NEBULA_V6` в режиме `awg` игнорируется. Underlay гасится `make awg-down`
(`make nebula-down` останавливает только Nebula).
`make awg-mesh-test` проверяет сам underlay отдельно от Nebula.

## AmneziaWG

`awg.sh` поднимает реальный туннель AmneziaWG между `ns_hostA` и `ns_relay1`. Пакеты проходят через `ns_natA` и `ns_dpi`, поэтому можно проверить работу обфускации в уже существующей топологии. Образ собирает `amneziawg-go` и соответствующие `awg`/`awg-quick` из официальных репозиториев при `make docker-up`. Если в ядре хоста нет модуля AmneziaWG, `awg-quick` использует userspace fallback; нужен доступ к `/dev/net/tun`. Если модуль есть, `awg-quick` предпочитает его, поэтому он должен поддерживать параметры конфигурации.

```bash
make docker-up
make up DPI_MODE=sig
make awg-test

# Проверка UDP-whitelist: сервер слушает UDP/443
make dpi DPI_MODE=whitelist
make awg-test AWG_PORT=443

make awg-status
make awg-down
```

`awg-test` пересоздаёт туннель, чтобы применить переданный `AWG_PORT`. Ключи и конфиги генерируются в `/var/tmp/awg-lab` внутри контейнера и не коммитятся в репозиторий. Они переживают перезапуск контейнера, пока не удалён сам контейнер. При `DPI_MODE=sig` обычная сигнатура WireGuard должна блокироваться, а AmneziaWG с изменёнными заголовками и padding должен проходить. При `DPI_MODE=whitelist` используй `AWG_PORT=443`.

Это лабораторный тест сигнатур, а не гарантия обхода любого DPI: эвристики и активные пробы могут обнаруживать разные варианты транспорта. Сейчас туннель намеренно ограничен маршрутом `10.66.0.0/24` между `hostA` и `relay1`; он не меняет default route и не является полнотуннельным VPN.

## Сценарии экспериментов

Команды выполняются либо через `make`, либо внутри `make docker-sh` (там `ip netns exec ...` без `sudo`).

### 1. Проверка типа NAT

Цель: убедиться, что natA сохраняет порт, а natB выдаёт случайный.

Терминал 1 (смотрим внешний порт на стороне inet):
```bash
make cap N=ns_dpi IF=br-inet
```

Терминал 2 (с каждого клиента шлём UDP с фиксированного локального порта на два разных адреса):
```bash
make docker-sh
for h in ns_hostA ns_hostB; do
  ip netns exec $h python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('0.0.0.0', 40000))
for d in ('203.0.113.10', '203.0.113.11'):
    s.sendto(b'x', (d, 5000))
"
done
```

Ожидаемо: у hostA через natA внешний порт остаётся `40000` для обоих направлений, у hostB через natB внешние порты разные и не равны `40000`. Подтвердить можно через `conntrack -L` в `ns_natA` и `ns_natB`.

### 2. Проверка DPI

```bash
make dpi DPI_MODE=sig
make test-dpi
```

Счётчики `wg-init` должны вырасти (6 пакетов: 3 по v4, 3 по v6). Затем:

```bash
make dpi DPI_MODE=whitelist
make test-dpi        # теперь режется любой UDP, где ни sport, ни dport не равны 53 или 443
make dpi DPI_MODE=off
```

Цель эксперимента: голый WireGuard режется, обфусцированный транспорт проходит. Обфусцированный трафик не совпадает с сигнатурой `sig` (длина и первые байты другие), а в режиме `whitelist` ему нужно ходить по UDP/443.

### 3. Измерение MTU

Максимальный размер payload без фрагментации: MTU минус 28 байт для IPv4 (20 IP + 8 ICMP) и минус 48 для IPv6 (40 IP + 8 ICMP).

```bash
make docker-sh
# голый путь, MTU 1500: 1472 должно пройти, 1473 нет (IPv4)
ip netns exec ns_hostA ping -c2 -M do -s 1472 203.0.113.10
ip netns exec ns_hostA ping -c2 -M do -s 1473 203.0.113.10
# IPv6: 1452 проходит, 1453 нет
ip netns exec ns_hostA ping -6 -c2 -M do -s 1452 2001:db8:100::10

# занизить MTU WAN-линков и повторить
make mtu WAN_MTU=1400          # с хоста
ip netns exec ns_hostA ping -c2 -M do -s 1372 203.0.113.10
```

Замеры повторяют в трёх конфигурациях: голый путь, с обфускацией, с обфускацией и overlay. Разница между ними показывает накладные расходы каждого слоя.

### 4. Задержка и потери

```bash
make netem NETEM="delay 30ms 5ms loss 0.5%"
make sh N=ns_hostA              # затем: ping -c 50 203.0.113.10  (смотрим avg и mdev)
make netem-off
```

Для измерений в трёх режимах (direct, через relay, через обфускацию) снимайте RTT и jitter на каждом.

### 5. Отказ relay (failover)

```bash
make docker-sh
# имитация падения relay1
ip netns exec ns_relay1 ip link set eth0 down
# или точечно: сбросить весь трафик к relay1 на dpi
ip netns exec ns_dpi nft add rule inet dpi forward ip daddr 203.0.113.11 drop

# вернуть
ip netns exec ns_relay1 ip link set eth0 up
ip netns exec ns_dpi nft flush chain inet dpi forward   # внимание: сотрёт и правила DPI, затем make dpi
make dpi                                                # с хоста, либо внутри контейнера
```

Время восстановления связности фиксируйте непрерывным `ping` с отметками времени: `ping -D`.

### 6. Nebula под разными режимами DPI

Перед каждым запуском `make nebula-down` и `make dpi DPI_MODE=<режим>`.

| Режим | Что запускаем | Ожидаемо |
|---|---|---|
| `off` | `make nebula-up` | базовая линия: туннели поднимаются, `nebula-test` проходит |
| `sig` | `make nebula-up` | Nebula проходит: сигнатура WireGuard к ней не относится |
| `nebula` | `make nebula-up` | хендшейки (`0x10`) режутся, туннели не поднимаются; счётчик `nebula-all` растёт. Это негативный тест |
| `whitelist` | `make nebula-up NEBULA_PORT=443` | lighthouse и relay'и слушают 443 и доступны; прямой путь hostA ↔ hostB невозможен (порт natB случайный), остаётся relay |

Счётчики смотреть так: `make sh N=ns_dpi`, затем `nft list table inet dpi`.

## Устройство NAT и DPI

### NAT (natA, natB)

- `table ip nat`, цепочка `postrouting`, правило `oifname "wan" masquerade`.
- natA: порт сохраняется, если не конфликтует. Получается NAT, при котором hole punching обычно удаётся.
- natB: `masquerade random`, порт выбирается случайно для каждого соединения. Это приближение symmetric NAT, при котором прямое соединение часто невозможно и нужен relay.
- `table inet fw`: `forward` с политикой `drop`. Разрешены established/related и всё, что пришло с интерфейса `lan`. Работает одинаково для v4 и v6.

### DPI (dpi)

- `table inet dpi`, цепочка `forward` (политика `accept`), правила добавляются командой `make dpi`.
- `sig`: WireGuard initiation (UDP-пакет длиной 156, первые 4 байта payload `01 00 00 00`) и response (длина 92, `02 00 00 00`).
- `nebula`: UDP-пакеты, у которых первые 4 байта payload равны `10 00 00 00` (handshake) или `11 00 00 00` (data). Заголовок Nebula: `[версия<<4 | тип][подтип][2 байта reserved][remote index, 4 байта][счётчик, 8 байт]`.
- `whitelist`: `udp dport != { 53, 443 } udp sport != { 53, 443 } drop`. Проверяются оба порта, иначе ответы сервера (sport 443, dport эфемерный) резались бы, и обычный трафик на 443 не работал бы.
- Правила стоят в `forward`, поэтому видят пакеты уже после NAT.
- Таблица `inet` покрывает IPv4 и IPv6 одними правилами.

## Частые проблемы

| Симптом | Причина и решение |
|---|---|
| `Cannot connect to the Docker daemon` | демон не запущен или пользователь не в группе `docker`: `sudo make docker-up` либо добавьте себя в группу |
| `docker: 'compose' is not a docker command` | нет плагина Compose; поставьте его или используйте `COMPOSE=docker-compose` |
| `Error response ... service "stand" is not running` | контейнер не запущен: `make docker-up` |
| `make up` внутри контейнера: `No rule to make target 'up'` | в контейнере пустая рабочая папка: путь монтирования в `docker-compose.yml` не совпадает с `working_dir` (должны быть `./:/stand` и `working_dir: /stand`). Проверка: `docker compose exec stand sh -c 'pwd; ls'` |
| `exec of "sysctl" failed` | образ собран без `procps`; пересоберите: `make docker-up` |
| `mount --make-shared /run/netns failed` или `Operation not permitted` при `ip netns add` | контейнер запущен без `privileged: true` или в rootless-режиме |
| `Operation not supported` / `No such file` при `nft` | в ядре хоста нет нужных опций. См. раздел «Требования» |
| `Cannot find device` при `tc ... netem` | не собрано `NET_SCH_NETEM` в ядре хоста или стенд не поднят |
| `make test` падает сразу после `up` | подождите 1-2 секунды и повторите; проверьте `make show`, что адреса не в `tentative` |
| `make nebula-up`: `Error 127` | не найден `./nebula.sh`: файл должен лежать в репозитории и быть исполняемым (`chmod +x nebula.sh`) |
| Nebula: нет `nebula1` | нет `/dev/net/tun` или `CONFIG_TUN` на хосте; смотрите `make nebula-logs NODE=<нода>` |
| `docker compose exec` ругается на TTY (в скрипте или cron) | добавьте `EXEC_FLAGS=-T` |
| v6-пинг до ctrl не проходит | проверьте `ip -6 route` в `ns_dpi` (должны быть маршруты на `2001:db8:a1::/64` и `2001:db8:b1::/64`) |
| После перезагрузки хоста или `docker compose down` стенда нет | namespace'ы живут внутри контейнера. Достаточно `make docker-up` и `make up` |
| Хост не может достучаться до узлов стенда | Так и задумано: стенд изолирован внутри контейнера. Заходите через `make sh` или `make docker-sh` |

## Ограничения

- Стенд эмулирует лишь сигнатурную фильтрацию (по длине и первым байтам) и белый список портов. Анализ TLS/SNI и поведенческий анализ реального ТСПУ не воспроизводятся. Для них можно подключить Suricata через `nfqueue`.
- Выход в настоящий интернет и работу через Cloudflare стенд не имитирует; такие тесты делаются отдельно на реальном VPS.
- Поведение `masquerade random` лишь приближает symmetric NAT; на реальном оборудовании результаты могут отличаться.
- Контейнер использует ядро хоста: нужные опции ядра и `/dev/net/tun` обязаны быть на хосте.
- Контейнер запускается с `privileged: true`: пользователю, который может им управлять, доступен весь хост. Для лабораторной машины это нормально, для общих систем нет.
- Стенд и Nebula-сертификаты не сохраняются между пересозданиями контейнера и рассчитаны на одну машину.
- Firewall внутри Nebula-overlay открыт полностью, это лабораторный режим.
### Машинный интерфейс управления (control contract v1)

Для интеграции со сторонним backend добавлен read-only JSON-интерфейс. Он
описывает текущую статическую топологию и собирает фактическое состояние
namespace'ов и интерфейсов. Он не создаёт узлы и не меняет сеть.

```bash
make control-topology  # JSON: узлы, связи, подсети и флаги возможностей
make control-status    # JSON: состояние пространств имён, интерфейсы, адреса и nebula1

# Те же команды внутри контейнера:
python3 ./scripts/control.py topology --json
python3 ./scripts/control.py status --json

# Проверка структуры контракта (Python 3, стенд запускать не нужно):
python3 -m unittest discover -s tests -v
```

Полная спецификация формата: [`docs/control-contract.md`](docs/control-contract.md).
Динамическое создание и удаление узлов пока не поддерживаются.
