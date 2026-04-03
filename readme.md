```markdown
# Обработка российских IP-адресов с помощью ipset + Unbound

Скрипты и конфигурация для автоматической загрузки списков IP-сетей РФ (ipdeny.com + GeoLite2) в ipset `RU_IPS`.
Для определения ru-сайтов на не RU-адресах используется обработка логов DNS-запросов unbound через `unbound-dns-monitor`.

## Особенности загрузки RU-адресов

- **Два источника**: сначала ipdeny.com (CIDR), затем GeoLite2 (диапазоны IP‑IP) — недостающие адреса добавляются автоматически.

## Требования

- Debian / Ubuntu (или любой systemd-дистрибутив)

## Установка

### 1. Установите необходимые пакеты

```bash
apt update
apt install -y libfile-tail-perl libnet-patricia-perl libnet-dns-perl \
               ipset unbound wget rsync netfilter-persistent
```

> **Примечание**: `netfilter-persistent` — правильное название для Debian/Ubuntu. Если пакет не найден, используйте `iptables-persistent`.

### 2. Подготовьте структуру каталогов и логов

```bash
mkdir -p /var/log/unbound
touch /var/log/unbound/unbound.log
chmod 770 /var/log/unbound
chown unbound:unbound -R /var/log/unbound
```

### 3. Скопируйте сервисы и скрипты из репозитория

```bash
cp -f systemd/unbound-dns-monitor.service /etc/systemd/system/
cp -f init.d/ipset /etc/init.d/ 2>/dev/null || true

mkdir -p /etc/systemd/system/netfilter-persistent.service.d
cp -f systemd/netfilter-persistent.service.d/override.conf /etc/systemd/system/netfilter-persistent.service.d/

rsync -av unbound/ /etc/unbound/

cp -f apparmor.d/local/usr.sbin.unbound /etc/apparmor.d/local/
apparmor_parser -r /etc/apparmor.d/usr.sbin.unbound

cp -f ru.sh /usr/local/bin/
chmod +x /usr/local/bin/ru.sh

cp -f bypass_myip.sh /usr/local/bin/
chmod +x /usr/local/bin/bypass_myip.sh

cp -f unbound-dns-monitor.pl /usr/local/bin/
chmod +x /usr/local/bin/unbound-dns-monitor.pl
```

### 4. Настройка dummy-интерфейса (опционально)

Нужен, если вы хотите, чтобы Unbound слушал на фиксированном локальном IP (например, `10.1.2.1`) независимо от физических интерфейсов.

```bash
echo dummy > /etc/modules-load.d/dummy.conf
modprobe dummy

mkdir -p /etc/network/interfaces.d
cat <<'EOF' > /etc/network/interfaces.d/dummy0
auto dummy0
allow-hotplug dummy0

iface dummy0 inet manual
  pre-up /sbin/ip link add dummy0 type dummy
  post-up ip addr add 10.1.2.1/32 dev dummy0
  post-down /sbin/ip link delete dummy0
EOF
```

### 5. Генерация ключей для `unbound-control`

```bash
unbound-control-setup
```

### 6. Включение сервисов

```bash
systemctl enable unbound
systemctl enable unbound-dns-monitor.service
```

> **Запуск**: после перезагрузки всё поднимется автоматически. Для немедленного старта выполните `systemctl start unbound unbound-dns-monitor.service` вручную.

## Проверка

- Посмотреть набор ipset: `ipset list RU_IPS | head`
- Логи Unbound: `journalctl -u unbound -f`
- Логи мониторинга DNS: `journalctl -u unbound-dns-monitor -f`
