#!/bin/sh
#
# FreeMyIP Let's Encrypt Cert Updater for Asuswrt-Merlin
# Updated 2025-06-03

###############################################################################
# USER VARIABLES – adjust as required
###############################################################################
FREEMYIP_DOMAIN2="DOMAIN2.freemyip.com"

DESKTOP_IP="192.168.50.X"      # Only run when this host is online
MAX_RETRIES=5                    # How many pings to try
SLEEP_SECS=60                    # Wait time between retries (seconds)

ACME_SH="/usr/sbin/acme.sh"
ACME_HOME="/jffs/.FTGle"
CERT_DIR="/jffs/.FTGcert"
CERT_FILE="${CERT_DIR}/firetopcert.pem"

SRC_DIR="${ACME_HOME}/${FREEMYIP_DOMAIN2}"
ECC_DIR="${ACME_HOME}/${FREEMYIP_DOMAIN2}_ecc"

###############################################################################
# HELPER – log to console *and* syslog, stripping any colours
###############################################################################
Say() {
  local clean="$(echo "$1" | sed 's/\\\e\[[0-9;]*m//g')"
  printf "%s\n" "$1"
  printf "%s\n" "$clean" | logger -t "[LE]"
}

###############################################################################
# GLOBAL LOCK – prevent concurrent runs
# Uses an atomic mkdir, which BusyBox supports.  /tmp is RAM-backed,
# so any stale lock disappears on reboot.
###############################################################################
LOCKDIR="/tmp/le_updater.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  Say "[Lock] Another instance is already running - exiting."
  exit 0
fi
# Ensure the lock is removed no matter how we exit
cleanup_lock() {
  rm -rf "$LOCKDIR"
}
trap cleanup_lock EXIT INT TERM

###############################################################################
# 0a  Skip if cert exists and is newer than 7 days
###############################################################################
if [ -f "$CERT_FILE" ] && \
   [ -n "$(find "$CERT_FILE" -mtime -2 -print)" ]; then
  Say "[LE] Existing cert is less than 2 days old - skipping renewal."
  exit 0
fi

###############################################################################
# Give the network a moment to settle before the desktop-reachability test
###############################################################################

sleep "$SLEEP_SECS"

###############################################################################
# 0  Check if desktop is online; wait-retry loop
###############################################################################
n=1
while [ "$n" -le "$MAX_RETRIES" ]; do
  if ping -c 1 -W 1 "$DESKTOP_IP" >/dev/null 2>&1; then
    Say "[Check] $DESKTOP_IP reachable on attempt $n - proceeding with ACME."
    break
  fi

  Say "[Check] $DESKTOP_IP not reachable (attempt $n/$MAX_RETRIES); waiting $SLEEP_SECS seconds"
  if [ "$n" -lt "$MAX_RETRIES" ]; then
    sleep "$SLEEP_SECS"
  else
    Say "[Aborted] $DESKTOP_IP never became reachable - skipping cert issuance."
    exit 0           # Not an error; nothing to do this time
  fi
  n=$((n + 1))
done

###############################################################################
# 1  Ensure working directories exist
###############################################################################
mkdir -p "$ACME_HOME" "$CERT_DIR"

###############################################################################
# 2  Temporarily open validation ports
###############################################################################
iptables -I FORWARD -p tcp --dport 80   -j ACCEPT
iptables -I INPUT   -p tcp --dport 8888 -j ACCEPT
Say "[Firewall] Opened ports 80/8888 for Let's Encrypt validation"

###############################################################################
# 3  Issue or renew the ECC certificate
###############################################################################
Say "[LE] Issuing/renewing cert for $FREEMYIP_DOMAIN2"

if [ -d "$ECC_DIR" ]; then
  #########################################################################
  # Renewal path
  #########################################################################
  Say "[LE] ECC dir found - attempting renewal"
  $ACME_SH --renew -d "$FREEMYIP_DOMAIN2" \
           --home "$ACME_HOME" \
           --ecc --standalone \
           --httpport 8888 --force
  RET=$?

  if [ "$RET" -ne 0 ] && [ "$RET" -ne 2 ]; then
    Say "[LE] Renewal failed (rc=$RET) - issuing a fresh cert as fallback"
    $ACME_SH --issue -d "$FREEMYIP_DOMAIN2" \
             --home "$ACME_HOME" \
             --ecc --standalone \
             --httpport 8888
    RET=$?
    SOURCE_DIR="$SRC_DIR"
  else
    Say "[LE] Renewal succeeded (or cert still valid)"
    SOURCE_DIR="$ECC_DIR"
  fi
else
  #########################################################################
  # First-time issuance path
  #########################################################################
  Say "[LE] No existing ECC directory - issuing new cert"
  $ACME_SH --issue -d "$FREEMYIP_DOMAIN2" \
           --home "$ACME_HOME" \
           --ecc --standalone \
           --httpport 8888
  RET=$?
  SOURCE_DIR="$SRC_DIR"
fi

###############################################################################
# 4  Close validation ports
###############################################################################
iptables -D FORWARD -p tcp --dport 80   -j ACCEPT
iptables -D INPUT   -p tcp --dport 8888 -j ACCEPT
Say "[Firewall] Closed ports 80/8888 after issuance"

###############################################################################
# 5  Post-processing and export
###############################################################################
if [ "$RET" -ne 0 ] && [ "$RET" -ne 2 ]; then
  Say "[LE][Error] ACME issuance FAILED - Exiting"
  rm -rf "$SRC_DIR"
  exit 1
fi

Say "[LE] ACME issuance succeeded"

# Promote first-time issue to ECC dir
if [ "$SOURCE_DIR" = "$SRC_DIR" ]; then
  rm -rf "$ECC_DIR"
  mv "$SRC_DIR" "$ECC_DIR"
  SOURCE_DIR="$ECC_DIR"
  Say "[LE] Promoted $SRC_DIR ? $ECC_DIR"
fi

# Ensure PEM copy exists alongside CER
cp "${SOURCE_DIR}/fullchain.cer" "${SOURCE_DIR}/fullchain.pem"

# Write custom-named GUI cert/key
cp "${SOURCE_DIR}/fullchain.pem"            "$CERT_DIR/firetopcert.pem"
cp "${SOURCE_DIR}/${FREEMYIP_DOMAIN2}.key"  "$CERT_DIR/firetopkey.pem"
Say "[LE] Exported GUI certs to ${CERT_DIR}"

Say "[Done] LE-start complete."
exit 0
