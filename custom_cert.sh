#!/bin/sh
#
# FreeMyIP Let's Encrypt Cert Updater for Asuswrt-Merlin
# Updated 2026-07-29

###############################################################################
# USER VARIABLES – adjust as required
###############################################################################
FREEMYIP_DOMAIN2="DOMAIN2.freemyip.com"
FREEMYIP_TOKEN2="XXXXXXXXXXXXXXXXXXXXXXXX"

# Required exact variable name for the acme.sh dns_freemyip hook
export FREEMYIP_Token="$FREEMYIP_TOKEN2"

SLEEP_SECS=60                    # Wait time between retries (seconds)

ACME_SH="/usr/sbin/acme.sh"
ACME_HOME="/jffs/.FTGle"
CERT_DIR="/jffs/.FTGcert"
CERT_FILE="${CERT_DIR}/firetopcert.pem"

SRC_DIR="${ACME_HOME}/${FREEMYIP_DOMAIN2}"
ECC_DIR="${ACME_HOME}/${FREEMYIP_DOMAIN2}_ecc"
DOMAIN_CONF="${ECC_DIR}/${FREEMYIP_DOMAIN2}.conf"

###############################################################################
# HELPER – log to console and syslog, stripping any colours
###############################################################################
Say() {
  local clean="$(echo "$1" | sed 's/\\\e\[[0-9;]*m//g')"
  printf "%s\n" "$1"
  printf "%s\n" "$clean" | logger -t "[LE]"
}

###############################################################################
# GLOBAL LOCK – prevent concurrent runs
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
# 0a  Skip if cert exists and is newer than 2 days
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
# 1  Ensure working directories exist
###############################################################################
mkdir -p "$ACME_HOME" "$CERT_DIR"

###############################################################################
# 2  Issue or renew the ECC certificate using DNS-01
###############################################################################
Say "[LE] Issuing/renewing cert for $FREEMYIP_DOMAIN2 using DNS-01"

if [ -d "$ECC_DIR" ]; then
  #########################################################################
  # Existing certificate
  #########################################################################

  if [ -f "$DOMAIN_CONF" ] && \
     grep -q "^Le_Webroot='dns_freemyip'" "$DOMAIN_CONF"; then

    #######################################################################
    # Already migrated: normal DNS-01 renewal
    #######################################################################
    Say "[LE] ECC dir found - attempting DNS-01 renewal"

    "$ACME_SH" --renew -d "$FREEMYIP_DOMAIN2" \
              --home "$ACME_HOME" \
              --ecc --force

    RET=$?
  else
    #######################################################################
    # One-time migration from HTTP-01 to DNS-01
    #######################################################################
    Say "[LE] Existing certificate uses HTTP-01 - migrating to DNS-01"

    "$ACME_SH" --issue -d "$FREEMYIP_DOMAIN2" \
              --home "$ACME_HOME" \
              --keylength ec-256 \
              --dns dns_freemyip \
              --force

    RET=$?
  fi

  if [ "$RET" -ne 0 ] && [ "$RET" -ne 2 ]; then
    Say "[LE] Renewal/migration failed (rc=$RET) - issuing a fresh cert as fallback"

    "$ACME_SH" --issue -d "$FREEMYIP_DOMAIN2" \
              --home "$ACME_HOME" \
              --keylength ec-256 \
              --dns dns_freemyip

    RET=$?
    SOURCE_DIR="$ECC_DIR"
  else
    Say "[LE] Renewal/migration succeeded (or cert still valid)"
    SOURCE_DIR="$ECC_DIR"
  fi
else
  #########################################################################
  # First-time issuance
  #########################################################################
  Say "[LE] No existing ECC directory - issuing new cert with DNS-01"

  "$ACME_SH" --issue -d "$FREEMYIP_DOMAIN2" \
            --home "$ACME_HOME" \
            --keylength ec-256 \
            --dns dns_freemyip

  RET=$?
  SOURCE_DIR="$ECC_DIR"
fi

###############################################################################
# 3  Post-processing and export
###############################################################################
if [ "$RET" -ne 0 ] && [ "$RET" -ne 2 ]; then
  Say "[LE][Error] ACME issuance FAILED - exiting"
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