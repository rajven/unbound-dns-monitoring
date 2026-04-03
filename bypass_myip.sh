#!/bin/bash

RU_IPSET="RU_IPS"
DIRECT_IPSET="direct"

DOMAINS=(
api.oneme.ru
oneme.ru
checkip.amazonaws.com
api.ipify.org
ifconfig.me
ipv4-internet.yandex.net
ip.mail.ru
ipinfo.io
checkip.amazonaws.com
icanhazip.com
ident.me
myip.dnsomatic.com
bot.whatismyipaddress.com
myip.ru
ifconfig.co
ip.seeip.org
wtfismyip.com
ipecho.net
myexternalip.com
l2.io
eth0.me
ipaddr.site
api64.ipify.org
v4.ident.me
v6.ident.me
ipv4.icanhazip.com
ipv6.icanhazip.com
cloudflare.com
1.1.1.1
ip.tyk.nu
wgetip.com
showmyip.com
ipof.in
whatismyip.akamai.com
)

for domain in "${DOMAINS[@]}"; do
    echo "Resolving $domain"
    IPS=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    for ip in $IPS; do
        if ! ipset test "$RU_IPSET" "$ip" 2>/dev/null; then
            echo "Adding $ip"
            ipset add "$DIRECT_IPSET" "$ip" -exist comment "$domain"
        else
            echo "Exists $ip"
        fi
    done
done

exit 0
