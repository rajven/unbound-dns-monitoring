# unbound-dns-monitor

Мониторинг DNS-запросов Unbound для управления ipset наборами и таблицей маршрутизации

## Установка

```bash
git clone https://github.com/rajven/unbound-dns-monitoring
cd unbound-dns-monitor
sudo ./install.sh
```

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

# Логи мониторинга
journalctl -u unbound-dns-monitor -f
```

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

## Особенности

- Загрузка RU-адресов из ipdeny.com и GeoLite2
- Автоматическое создание ipset наборов
- Интеграция с Unbound через DNS-лог

## Требования

Debian/Ubuntu с systemd
