#!/bin/bash

[ -z "$1" ] && exit 0

set_name=$1

/sbin/ipset list "${set_name}" 2>/dev/null | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?'

exit 0

