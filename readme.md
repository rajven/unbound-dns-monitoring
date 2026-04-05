# unbound-dns-monitor

Мониторинг DNS-запросов Unbound для управления ipset наборами.

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

## Особенности

- Загрузка RU-адресов из ipdeny.com и GeoLite2
- Автоматическое создание ipset наборов
- Интеграция с Unbound через DNS-лог

## Требования

Debian/Ubuntu с systemd
```
