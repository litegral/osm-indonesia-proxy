#!/bin/bash
# usage:
#   ./keys.sh add <key> <client-name> [rate-limit] [allowed-domain]
#   ./keys.sh revoke <key>
#   ./keys.sh list
#   ./keys.sh usage <key>
#   ./keys.sh set-limit <key> <requests-per-minute>
#   ./keys.sh set-origin <key> <domain>
#   ./keys.sh remove-origin <key>

REDIS="docker compose exec redis redis-cli"

case "$1" in
  add)
    KEY=$2
    CLIENT=$3
    LIMIT=${4:-1000}
    DOMAIN=$5
    if [ -z "$KEY" ] || [ -z "$CLIENT" ]; then
      echo "usage: ./keys.sh add <key> <client-name> [rate-limit] [allowed-domain]"
      exit 1
    fi
    $REDIS SET "tile:key:$KEY" "$CLIENT"
    $REDIS SET "tile:limit:$KEY" "$LIMIT"
    if [ -n "$DOMAIN" ]; then
      $REDIS SET "tile:origin:$KEY" "$DOMAIN"
      echo "added key for $CLIENT (limit: $LIMIT req/min, origin: $DOMAIN)"
    else
      echo "added key for $CLIENT (limit: $LIMIT req/min, origin: any)"
    fi
    ;;

  revoke)
    KEY=$2
    if [ -z "$KEY" ]; then
      echo "usage: ./keys.sh revoke <key>"
      exit 1
    fi
    $REDIS DEL "tile:key:$KEY"
    $REDIS DEL "tile:limit:$KEY"
    $REDIS DEL "tile:origin:$KEY"
    echo "revoked key $KEY"
    ;;

  list)
    echo "active keys:"
    for k in $($REDIS KEYS "tile:key:*"); do
      KEY=$(echo $k | sed 's/tile:key://')
      CLIENT=$($REDIS GET $k)
      LIMIT=$($REDIS GET "tile:limit:$KEY")
      ORIGIN=$($REDIS GET "tile:origin:$KEY")
      echo "  $KEY -> $CLIENT (limit: ${LIMIT:-1000} req/min, origin: ${ORIGIN:-any})"
    done
    ;;

  usage)
    KEY=$2
    if [ -z "$KEY" ]; then
      echo "usage: ./keys.sh usage <key>"
      exit 1
    fi
    CLIENT=$($REDIS GET "tile:key:$KEY")
    TOTAL=$($REDIS GET "tile:usage:$KEY:total")
    TODAY=$($REDIS GET "tile:usage:$KEY:day:$(date +%Y-%m-%d)")
    LAST=$($REDIS GET "tile:usage:$KEY:last_seen")
    ORIGIN=$($REDIS GET "tile:origin:$KEY")
    echo "client:    $CLIENT"
    echo "origin:    ${ORIGIN:-any}"
    echo "total:     ${TOTAL:-0} requests"
    echo "today:     ${TODAY:-0} requests"
    echo "last seen: $([ -n "$LAST" ] && date -d @$LAST || echo never)"
    ;;

  set-limit)
    KEY=$2
    LIMIT=$3
    if [ -z "$KEY" ] || [ -z "$LIMIT" ]; then
      echo "usage: ./keys.sh set-limit <key> <requests-per-minute>"
      exit 1
    fi
    $REDIS SET "tile:limit:$KEY" "$LIMIT"
    echo "set limit for $KEY to $LIMIT req/min"
    ;;

  set-origin)
    KEY=$2
    DOMAIN=$3
    if [ -z "$KEY" ] || [ -z "$DOMAIN" ]; then
      echo "usage: ./keys.sh set-origin <key> <domain>"
      exit 1
    fi
    $REDIS SET "tile:origin:$KEY" "$DOMAIN"
    echo "set allowed origin for $KEY to $DOMAIN"
    ;;

  remove-origin)
    KEY=$2
    if [ -z "$KEY" ]; then
      echo "usage: ./keys.sh remove-origin <key>"
      exit 1
    fi
    $REDIS DEL "tile:origin:$KEY"
    echo "removed origin restriction for $KEY"
    ;;

  *)
    echo "commands:"
    echo "  add <key> <client-name> [rate-limit] [domain]   add a new api key"
    echo "  revoke <key>                                     revoke an api key"
    echo "  list                                             list all active keys"
    echo "  usage <key>                                      show usage stats for a key"
    echo "  set-limit <key> <req-per-min>                    update rate limit for a key"
    echo "  set-origin <key> <domain>                        restrict key to a domain"
    echo "  remove-origin <key>                              remove origin restriction"
    ;;
esac
