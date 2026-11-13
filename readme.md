# unbound-dns-monitor

Мониторинг DNS-запросов Unbound для управления ipset наборами и таблицей маршрутизации

## Как это работает

1. Unbound пишет клиентские запросы в `/var/log/unbound/unbound.log`
   (`log-queries: yes`, конфиг из комплекта `etc/unbound/`).
2. Демон `unbound-dns-monitor.pl` (File::Tail) разбирает лог, находит A/HTTPS
   запросы к доменам из `UNBOUND_PATTERNS` и рекурсивно резолвит их IPv4
   (следует за CNAME и IPv4-hint внутри HTTPS-записей) через `DNS_RESOLVER`.
3. Найденные IP добавляются в ipset: для наборов `hash:ip` — напрямую, для
   наборов маршрутизации — через `ipset-hook.sh` (см. «Режим добавления записей»).
   В комментарий записи пишется домен-источник.
4. Повторный запрос того же домена в течение `mute_time` (3600 с) пропускается;
   внутренние кэши демона чистятся раз в час, так что память не растёт бесконечно.
5. При остановке демона (SIGTERM/SIGINT) наборы сохраняются в `/etc/ipset.d/*.conf`,
   при старте восстанавливаются из этих файлов; при загрузке сервера их атомарно
   поднимает `ipset-utils.sh` через override `netfilter-persistent`.
6. Маркировку трафика делают правила iptables из `etc/iptables/rules.v4`: в
   mangle PREROUTING трафик LAN к адресам из `RU_IPS`, `direct` и `route_youtube`
   получает метку `0x64`, по которой он уходит напрямую, минуя VPN.

## Установка

```bash
git clone https://github.com/rajven/unbound-dns-monitoring
cd unbound-dns-monitoring
sudo ./install.sh
```

`install.sh` ставит пакеты (`libfile-tail-perl`, `libnet-patricia-perl`,
`libnet-dns-perl`, `libnet-idn-encode-perl`, `ipset`, `unbound`, `wget`,
`rsync`, `netfilter-persistent`), копирует скрипты и конфигурацию, генерирует
ключи `unbound-control-setup`, создаёт `/var/log/unbound/unbound.log` и
включает сервисы. Файлы cron из `etc/cron.d/` копируются только если таких
файлов ещё нет — существующие не перезаписываются.

## Обновление

```bash
git pull
sudo ./update.sh
sudo systemctl restart unbound unbound-dns-monitor.service
```

`update.sh` перезаписывает скрипты, systemd-юниты и файлы библиотеки, но
ваш `/etc/unbound-dns-monitor/unbound-dns-monitor.cfg` не трогает: рядом
кладётся копия `*.cfg.new` и показывается diff. Новые переменные конфигурации
добавляются в существующий файл автоматически (после маркеров секций),
дубликаты не создаются.

## Запуск

```bash
systemctl start unbound
systemctl start unbound-dns-monitor.service
```

## Проверка

```bash
# Просмотр ipset наборов
ipset list RU_IPS | head

# Логи Unbound
journalctl -u unbound -f

# Логи мониторинга (строки "Processing log line" — шум уровня INFO)
journalctl -u unbound-dns-monitor -f | grep -v 'Processing log line'

# Что демон добавил недавно
ipset list telegram | tail
```

## Файлы в системе

| Путь | Что это |
|------|---------|
| `/usr/local/bin/unbound-dns-monitor.pl` | демон мониторинга |
| `/usr/local/bin/ipset-hook.sh` | хук для наборов `hash:net` и маршрутов |
| `/usr/local/bin/init_ru_ipset.sh` | сборка/обновление `RU_IPS` из ipdeny.com и GeoLite2 |
| `/usr/local/bin/bypass_myip.sh` | IP «my IP»-сервисов из `DETECT_IP_DOMAINS` → набор `direct` |
| `/usr/local/bin/ipset-utils.sh` | атомарный restore/swap наборов из `/etc/ipset.d/*.conf` при загрузке |
| `/usr/local/bin/save_ipsets.sh` | ручное сохранение и веб-экспорт наборов |
| `/usr/local/bin/wg-monitor.sh` | проверка живости WG/AWG-туннеля и его маршрутов (cron) |
| `/usr/local/bin/awg-routes.sh`, `openvpn-routes.sh` | up/down-хуки туннелей (маршруты и правила из `wg0.routes`/`tun0.routes`) |
| `/usr/local/bin/yudns.pl` | выгрузка DNS-запросов YouTube из journalctl в кэш youtubeUnblock |
| `/usr/local/lib/dns-monitor-lib.sh` | общая библиотека |
| `/etc/unbound-dns-monitor/unbound-dns-monitor.cfg` | вся конфигурация |
| `/etc/unbound-dns-monitor/wg0.routes`, `tun0.routes` | шаблоны правил маршрутизации для туннелей |
| `/etc/ipset.d/*.conf` | сохранённые состояния наборов |
| `/etc/cron.d/wg-monitor` | проверка туннеля раз в 3 минуты |
| `/etc/cron.d/yudns`, `/etc/cron.d/cinema` | закомментированные примеры периодических задач |
| `/var/log/unbound/unbound.log` | лог Unbound, из которого читает демон (обнуляется при старте демона) |
| `/var/www/html/ipsets` | каталог веб-экспорта (при включённых флагах `ENABLE_WEB_*`) |

## Компоненты systemd и интеграции

Юнит `unbound-dns-monitor.service`: перед стартом демона выполняются
`init_ru_ipset.sh` (обновление RU-адресов) и `bypass_myip.sh`, лог обнуляется;
`Restart=on-failure` с паузой 10 с, `MemoryMax=256M`, включён systemd-хардненинг
(`ProtectSystem=strict`, ограничение capabilities до `CAP_NET_ADMIN`/`CAP_NET_RAW`).
Debug-лог демона включается `LOG_LEVEL="DEBUG"` в конфиге.

Дополнительно из комплекта:

- **OpenVPN-сервер**: `etc/openvpn/server/acl/user_acl` при `client-connect`
  пушит клиентам маршруты из наборов `direct` и `route_soc` (через sudo-скрипт
  `show_ipset.sh`, право выдано пользователю `nobody` в `etc/sudoers.d/nobody`).
- **youtubeUnblock**: набор `route_youtube` работает с ним в связке; опциональный
  `yudns.pl` (cron `etc/cron.d/yudns`, по умолчанию закомментирован) копит
  IP YouTube-запросов в кэш `/var/spool/youtubeUnblock-dns.cache`.

## Конфигурация

Редактируйте `/etc/unbound-dns-monitor/unbound-dns-monitor.cfg`

### Режим добавления записей в ipset (route_vpn и route_youtube)

Записи в наборы типа `hash:net` добавляет `/usr/local/bin/ipset-hook.sh`:
набор маршрутизации в VPN из `ROUTE_VPN_IPSETS` (по умолчанию `route_vpn`)
и набор обхода YouTube из `ROUTE_YOUTUBE_IPSET` (по умолчанию `route_youtube`).
Режимы настраиваются независимо:

| Переменная | Набор |
|------------|-------|
| `ROUTE_VPN_ADD_MODE` | `route_vpn` + системные маршруты при `CREATE_VPN_ROUTES="yes"` |
| `ROUTE_YOUTUBE_ADD_MODE` | `route_youtube` (обход YouTube) |

| Значение | Что попадает в ipset |
|----------|----------------------|
| `NET24`  | сеть `/24`, вычисленная из IP-адреса (историческое поведение, меньше записей) |
| `IP`     | сам IP-адрес как есть (точечная маршрутизация одного хоста) |

```bash
ROUTE_VPN_ADD_MODE="NET24"
ROUTE_YOUTUBE_ADD_MODE="NET24"
```

Неизвестное (или пустое) значение приводит к предупреждению в лог и работе в
режиме `NET24`. Проверка после смены режима:

```bash
sudo /usr/local/bin/ipset-hook.sh vpn 203.0.113.77 example.com
ipset list route_vpn | grep 203.0.113

sudo /usr/local/bin/ipset-hook.sh youtube 203.0.113.77 example.com
ipset list route_youtube | grep 203.0.113
```

### Действия по доменам (UNBOUND_PATTERNS)

Формат — `"шаблон=действие"`. Ключ трактуется как доменный суффикс: совпадает
сам домен и все его поддомены (кириллица конвертируется в punycode, поэтому
`"рф=direct"` работает). Действие — имя набора из `UNBOUND_IPSETS`, и
обработка зависит от имени:

| Действие | Что происходит |
|----------|----------------|
| `direct` | IP добавляется в набор `direct` (трафик напрямую, метка `0x64`) |
| `youtube` | при `YOUTUBE_DIRECT="yes"` IP добавляется в `route_youtube` — **только если** маршрут до адреса выходит через WAN-интерфейс, а не через туннель |
| прочие (`telegram`, `whatsapp`, ...) | IP (или его `/24`) добавляется в `route_vpn`; при `CREATE_VPN_ROUTES="yes"` дополнительно создаётся системный маршрут через шлюз соответствующего VPN-интерфейса |

Интерфейс для «прочих» определяется по `VPN_NAMES` (например, `[vpn]="wg0"`),
а если имя набора там не указано — берётся первый интерфейс из `ROUTE_VPN_IPSETS`.

### Основные переменные

| Группа | Переменные |
|--------|-----------|
| Наборы | `RU_IPSET`, `DIRECT_IPSET`, `UNBOUND_IPSETS` (какие наборы создавать и их типы), `IPSET_EXCEPTIONS` (приватные/служебные сети, которые никогда не добавляются) |
| Маршрутизация | `ROUTE_VPN_IPSETS`, `ROUTE_TABLES`, `VPN_NAMES`, `VPN_DNS_UPLINKS` (DNS за туннелем — обязателен), `CREATE_VPN_ROUTES`, `VPN_DNS` |
| Резолвер | `DNS_RESOLVER` — через кого демон резолвит домены |
| Загрузка RU-зоны | `IPDENY_URL`, `GEOLITE_URL`, `ENABLE_IPDENY`, `ENABLE_GEOLITE`, `WGET_OPTS` |
| Хук и экспорт | `IPSET_HOOK`, `IPSET_HOOK_ENABLED`, `IPSET_CONF_DIR`, `WEB_OUTPUT_DIR`, `ENABLE_WEB_EXPORT`, `ENABLE_WEB_TXT_EXPORT`, `ENABLE_WEB_MIKROTIK_EXPORT`, `ENABLE_WEB_RU_IPSET_EXPORT` |
| Прочее | `LOG_LEVEL` (`DEBUG`/`INFO`/`WARN`/`ERROR`), `IPSET_HASHSIZE`, `IPSET_MAXELEM`, `TEMP_DIR`, `DETECT_IP_DOMAINS`, пути команд (`IP_CMD`, `IPSET_CMD`, `AWK_CMD`, `DIG_CMD`, `WGET_CMD`) |

## Траблшутинг

| Симптом | Что проверить |
|---------|---------------|
| Демон не видит запросы | есть ли `/var/log/unbound/unbound.log`, пишет ли его unbound (`log-queries: yes`); лог обнуляется при каждом старте демона — это нормально |
| Домен добавлен в `UNBOUND_PATTERNS`, но ничего не происходит | перезапустить демон; домен мог быть обработан менее часа назад (`mute_time`); резолвится ли домен через `DNS_RESOLVER`; не попадает ли IP в `IPSET_EXCEPTIONS`; IP уже в наборе |
| Ошибка в логе `Invalid IP address` или комментарий пропал | в хук пришёл некорректный IP или комментарий с недопустимыми символами — это защитное поведение, смотреть `journalctl -u unbound-dns-monitor` |
| Наборы пропали после перезагрузки | работает ли `netfilter-persistent` и override с `ipset-utils.sh start`; есть ли файлы в `/etc/ipset.d/` |
| Маршрут в VPN не создаётся | имя таблицы из `ROUTE_TABLES` должно существовать в `/etc/iproute2/rt_tables` (в комплекте пример: `100 awg`); задан ли шлюз в `VPN_DNS_UPLINKS` |
| Демон периодически перезапускается | смотрите ошибки в журнале; срабатывание `MemoryMax=256M` видно в `journalctl` (`oom-kill`) |

## Известные ограничения

- Обрабатываются только IPv4 A/HTTPS-записи; IPv6 не мониторится.
- Повторная обработка домена возможна не чаще раза в час (`mute_time`).
- Разбор лога привязан к формату строк unbound (`info: <ip> <домен>. <A|HTTPS> IN`);
  при смене формата/версии unbound нужно скорректировать регулярное выражение.
- `WGET_OPTS` содержит `--no-check-certificate` для загрузки ru.zone и GeoLite2 —
  известное ослабление TLS-проверки, оставлено намеренно.
- Демон работает от root с `CAP_NET_ADMIN`/`CAP_NET_RAW` (нужны для ipset и маршрутов).

## Особенности

- Загрузка RU-адресов из ipdeny.com и GeoLite2
- Автоматическое создание ipset наборов
- Интеграция с Unbound через DNS-лог

## Требования

Debian/Ubuntu с systemd; ядро с поддержкой ipset; доступ в интернет для
загрузки RU-зоны (ipdeny.com, jsdelivr). Perl-модули ставятся `install.sh`
автоматически.
