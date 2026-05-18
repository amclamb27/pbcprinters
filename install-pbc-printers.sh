#!/bin/bash
# ==============================================================================
# PBC Intern Printer Setup — macOS
# ==============================================================================
# Layer27 Technology Services
# Installs Providence Baptist Church printers on personal Macs that are NOT
# enrolled in NinjaOne MDM (summer interns, contractors, guests).
#
# Uses the generic PostScript driver shipped with CUPS — no Toshiba PPD
# package or driver download required. Idempotent — safe to re-run.
#
# Usage:
#   sudo bash install-pbc-printers.sh                  # install all 6 printers
#   sudo bash install-pbc-printers.sh remove           # remove all 6 printers
#
# Or one-liner (recommended):
#   curl -fsSL https://raw.githubusercontent.com/<ORG>/<REPO>/main/mac/install-pbc-printers.sh | sudo bash
# ==============================================================================

set -e

LOG="/tmp/pbc-printer-install.log"
ACTION="${1:-install}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') -- $*" | tee -a "$LOG"
}

log "=== PBC printer ${ACTION} starting ==="

if [[ $EUID -ne 0 ]]; then
    echo ""
    echo "ERROR: This script must be run with sudo." >&2
    echo "Try again:  sudo bash $0" >&2
    echo ""
    exit 1
fi

# ----- Printer definitions ----------------------------------------------------
# Keep in sync with the Windows script and IT Glue.
PRINTERS=(
    "Toshiba_B547_Admin|10.5.1.17|Toshiba B547 (Admin)"
    "Toshiba_A214|10.40.3.13|Toshiba A214 (Ministry)"
    "Toshiba_A510_Ministry|10.5.1.19|Toshiba A510 (Ministry)"
    "Toshiba_A616|10.40.3.12|Toshiba A616 (WC/Tech)"
    "Toshiba_B135|10.1.1.51|Toshiba B135 (Admin)"
    "Toshiba_C181|10.40.3.15|Toshiba C181 (WC/Tech)"
)

# ----- Locate a usable generic PostScript PPD ---------------------------------
find_generic_ppd() {
    # CUPS ships a generic PostScript driver — exact path varies by macOS version.
    local candidates=(
        "drv:///sample.drv/generic.ppd"                       # CUPS internal (preferred)
        "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/PrintCore.framework/Versions/A/Resources/Generic.ppd"
        "/Library/Printers/PPDs/Contents/Resources/Generic.ppd"
        "/usr/share/cups/model/sample.drv/generic.ppd"
    )
    for c in "${candidates[@]}"; do
        if [[ "$c" == drv://* ]]; then
            # Internal driver — verify via lpinfo
            if /usr/sbin/lpinfo -m 2>/dev/null | grep -q "sample.drv/generic.ppd"; then
                echo "$c"; return 0
            fi
        elif [[ -f "$c" ]]; then
            echo "$c"; return 0
        fi
    done
    return 1
}

# ----- Install action ---------------------------------------------------------
install_all() {
    local PPD
    PPD=$(find_generic_ppd) || {
        log "ERROR: Could not locate a generic PostScript PPD on this Mac."
        exit 2
    }
    log "Using PPD: $PPD"

    local installed=0 skipped=0 failed=0
    for entry in "${PRINTERS[@]}"; do
        IFS='|' read -r name ip display <<< "$entry"

        if lpstat -p "$name" >/dev/null 2>&1; then
            log "SKIP — '$display' already installed"
            ((skipped++))
            continue
        fi

        local args=( -p "$name" -E -o printer-is-shared=false
                     -v "lpd://${ip}" -D "$display" -L "Providence Baptist Church" )
        if [[ "$PPD" == drv://* ]]; then
            args+=( -m "$PPD" )
        else
            args+=( -P "$PPD" )
        fi

        if /usr/sbin/lpadmin "${args[@]}" 2>>"$LOG"; then
            log "ADDED — $display ($ip)"
            ((installed++))
        else
            log "FAIL  — $display ($ip) — see $LOG"
            ((failed++))
        fi
    done

    echo ""
    log "Summary: $installed added, $skipped already present, $failed failed"
    echo ""
    if [[ $failed -eq 0 ]]; then
        echo "✔ All Providence Baptist Church printers are now available."
        echo "  Open any document → File → Print → choose a printer from the list."
        echo ""
        echo "  Log: $LOG"
    else
        echo "Some printers failed to install. See $LOG for details."
        exit 1
    fi
}

# ----- Remove action ----------------------------------------------------------
remove_all() {
    local removed=0
    for entry in "${PRINTERS[@]}"; do
        IFS='|' read -r name ip display <<< "$entry"
        if lpstat -p "$name" >/dev/null 2>&1; then
            /usr/sbin/lpadmin -x "$name" && log "REMOVED — $display" && ((removed++))
        fi
    done
    # Clean up any legacy queues from previous deployments
    for legacy in Xerox_B547_Admin Xerox_A214 Xerox_A510_Ministry Xerox_A616 Xerox_B135 Xerox_C181; do
        if lpstat -p "$legacy" >/dev/null 2>&1; then
            /usr/sbin/lpadmin -x "$legacy" && log "REMOVED legacy — $legacy"
        fi
    done
    echo ""
    log "Removal complete — $removed printer(s) removed."
}

case "$ACTION" in
    install) install_all ;;
    remove)  remove_all ;;
    *)
        echo "Usage: sudo bash $0 [install|remove]"
        exit 1
        ;;
esac

exit 0
