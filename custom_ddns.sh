#!/bin/sh

# FreeMyIP DDNS Cert Updater for Asuswrt-Merlin
# Updated 06/03/2025

###############################################################################
# USER VARIABLES – adjust as required
###############################################################################
FREEMYIP_DOMAIN1="DOMAIN1.freemyip.com"
FREEMYIP_TOKEN1="XXXXXXXXXXXXXXXXXXXXXXXX"

FREEMYIP_DOMAIN2="DOMAIN2.freemyip.com"
FREEMYIP_TOKEN2="XXXXXXXXXXXXXXXXXXXXXXXX"

LAST_IP_FILE="/jffs/scripts/last_wan_ip"

WANIP="$1"

Say(){
  # strip ANSI color codes for syslog
  local clean="$(echo "$1" | sed 's/\\\e\[[0-9;]*m//g')"
  printf "%s\n" "$1"
  printf "%s\n" "$clean" | logger -t "[DDNS]"
}

GetWanIp(){
  local detected_ip

  detected_ip="$(nvram get wan0_ipaddr 2>/dev/null)"
  case "$detected_ip" in
    ""|"0.0.0.0")
      detected_ip="$(nvram get wan1_ipaddr 2>/dev/null)"
      ;;
  esac

  case "$detected_ip" in
    ""|"0.0.0.0")
      return 1
      ;;
    *)
      printf "%s\n" "$detected_ip"
      return 0
      ;;
  esac
}

# -- Sanity check / WAN IP fallback --
if [ -z "$WANIP" ]; then
  Say "[Info] No WAN IP passed in. Attempting to detect current WAN IP."
  WANIP="$(GetWanIp)"
fi

if [ -z "$WANIP" ]; then
  Say "[Error] Unable to determine WAN IP."
  exit 1
fi

### 2  Has the IP changed since last run?
if [ -f "$LAST_IP_FILE" ] && [ "$(cat "$LAST_IP_FILE")" = "$WANIP" ]; then
  echo "WAN IP unchanged ($WANIP) - skipping DDNS."
  Say "[Result] DDNS updates OK"
  /sbin/ddns_custom_updated 1
else
  # -- Update DDNS #1 --
  Say "[DDNS] Updating $FREEMYIP_DOMAIN1"
  HTTP1="$(curl -fs -w '%{http_code}' -o /dev/null \
    "https://freemyip.com/update?token=${FREEMYIP_TOKEN1}&domain=${FREEMYIP_DOMAIN1}&myip=${WANIP}")"
  Say "[DDNS] $FREEMYIP_DOMAIN1 ? HTTP $HTTP1"

  # -- Update DDNS #2 --
  Say "[DDNS] Updating $FREEMYIP_DOMAIN2"
  HTTP2="$(curl -fs -w '%{http_code}' -o /dev/null \
    "https://freemyip.com/update?token=${FREEMYIP_TOKEN2}&domain=${FREEMYIP_DOMAIN2}&myip=${WANIP}")"
  Say "[DDNS] $FREEMYIP_DOMAIN2 ? HTTP $HTTP2"

  # -- Final DDNS result --
  if [ "$HTTP1" = "200" ] && [ "$HTTP2" = "200" ]; then
    Say "[Result] DDNS updates OK"
    /sbin/ddns_custom_updated 1
    echo "$WANIP" > "$LAST_IP_FILE"
  else
    Say "[Result] DDNS update FAILED."
    /sbin/ddns_custom_updated 0
  fi
fi

Say "[Starting] custom certificate renewal script."
/bin/sh /jffs/scripts/custom_cert.sh &

Say "[Done] ddns-start complete."
exit 0