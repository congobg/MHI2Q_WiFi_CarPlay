#!/bin/sh

# ============================================================
# AltScreen.sh  -  MHI2 (NVIDIA/H) and MHI2Q (QC) in one script
#                  persistent overlay tree + procnto links (ln -sP)
#
# The pack (tar / tar.gz, paths mirroring the live system) is unpacked
# ONCE, at install or when the pack changes, into /mnt/ota/altscreen/root,
# together with copies of the stock binaries our wrappers start. At boot
# "start" only creates the links: no unpacking, no copying, no scans.
#
#   mnt/app/eso/lib/libcpproxy.so -> /mnt/ota/altscreen/root/mnt/app/eso/lib/libcpproxy.so
#
# Everything lives in this one tree - also the wireless CarPlay part
# (mnt/ota/wcp/...). Those files are linked FILE BY FILE, so /mnt/ota/wcp stays
# a real directory for what is not code: the receiver identity (pair/),
# wcp.conf, the markers and logs. prepare creates the real directories, and
# removes old real copies there that the pack now provides (one copy only).
# mnt/ota/wcp/pair and mnt/ota/altscreen are never taken from a pack.
# A second pack /mnt/ota/app/wcp.tar.gz (SF_PACK2) is used as well if it
# exists - one pack holding everything works just the same.
#
# The platform is detected at run time: NVIDIA units have mm-ipod
# (/mnt/app/armle/usr/sbin/mm-ipod), QC units do not. On NVIDIA mm-ipod
# is also saved and shadowed by the RGI-H shim. SF_PLATFORM=NV or QC
# overrides the detection.
#
# Usage:
#
#   AltScreen.sh prepare     unpack the pack to /mnt/ota/altscreen/root and save
#                        the stock binaries there (done by install, and by start
#                        when the pack is newer than the prepared tree)
#   AltScreen.sh start       link the prepared tree over flash, start the RGI
#                        renderer supervisor, the wireless CarPlay daemons and
#                        aawd (wireless Android Auto)
#   AltScreen.sh stop        stop renderer, supervisor, wireless CarPlay daemons
#                        and aawd, remove the links (the prepared tree stays)
#   AltScreen.sh check       links, files, firewall, processes (read-only)
#   AltScreen.sh checkfw     firewall only (read-only)
#   AltScreen.sh fixfw       pf files (persistent): tcp 6031 on carplay0, and the
#                        CarPlay ports + Android Auto's tcp 5288 on uap0 (wireless
#                        CarPlay / Android Auto on QC)
#   AltScreen.sh install     prepare + boot hook: servicemgrmibhigh runs "AltScreen.sh start" first
#   AltScreen.sh uninstall   put the stock servicemgrmibhigh back (tree stays: purge removes it)
#   AltScreen.sh purge       remove /mnt/ota/altscreen (only while the overlay is not active)
#   AltScreen.sh restorefw   put the stock pf files back
#   AltScreen.sh fixusb      no MTP driver for Android phones (0x18d1) in usblauncher.lua,
#                            so Android Auto connects at cold boot (persistent)
#   AltScreen.sh restoreusb  remove that again (stock usblauncher.lua)
#   AltScreen.sh patchwifi   patched Wi-Fi driver from the pack (mnt/ota/wcp/drv/) over
#                            the stock one, stock copy kept in .../lib/dll/stock/ (reboot)
#   AltScreen.sh restorewifi stock Wi-Fi driver back (reboot)
#   install / uninstall also run fixfw + fixusb + patchwifi / restorefw + restoreusb +
#   restorewifi.
#   AltScreen.sh flags [dir]  control files from a "flags" folder into /mnt/ota/app;
#                            install does this first (folder next to this script, or
#                            /fs/sda0/flags, /fs/usb0/flags, ...)
#
# ALL control files (markers, settings, tuning values) are in /mnt/ota/app;
# "check" lists the ones that are set, with what each is for (CONTROL_FILES).
#
# Every path in the prepared list is shadowed with "ln -sP" (procnto
# namespace, RAM only). Flash is never written at boot: a reboot without
# the hook (or with the off switch) always gives stock back. /mnt/ota is
# written only by prepare (install, or a newer pack).
#
# Stock binaries the wrappers start are copied into the tree ONCE (cp -p, at
# install or with a new pack - an unchanged copy is reused) and linked as
# /mnt/app/eso/bin/apps/stock/<name>: same file name, so the running process
# keeps its stock name for pidin / slay / scripts (dio_manager, gal, btstack,
# smartphone_integrator).
# If the firmware brings a newer stock file than the copy, start copies it
# again before linking - the saved stock can never be a wrong version.
#
# Preload layout: libairplay and gal stay STOCK.
#   dio_manager  wrapper -> LD_PRELOAD libcpproxy.so (QC: + librgi_hook.so,
#                libwcpstart.so), execs stock/dio_manager
#   gal          wrapper -> LD_PRELOAD libaaproxy.so (AltScreen) and/or
#                libaawusb.so (wireless Android Auto), execs stock/gal
#   btstack      wrapper -> LD_PRELOAD libbthook.so (wireless CarPlay and the
#                Android Auto Bluetooth channel), execs stock/btstack; starts the
#                wireless CarPlay daemons
#   smartphone_integrator  wrapper (wireless Android Auto) -> USB_HOST_LIB_PATH
#                libaawusb.so + LD_PRELOAD libaawmcc.so, execs
#                stock/smartphone_integrator
#   mm-ipod      (NVIDIA only) RGI-H shim -> librgi_hook.so, execs mm-ipod.orig
# Each wrapper must carry one of the MOD_TAGS texts, so it is never taken
# as stock. A wrapper is linked only if the pack holds it.
#
# Directory links (/mnt/app/eso/hmi/lib) REPLACE the stock directory,
# they do not merge: prepare checks that the pack holds its complete
# content and leaves an incomplete directory out (SF_FORCE=1 links anyway).
#
# start runs before the linked services launch (boot hook).
#
# start and stop run only when the MMI is in normal mode
# (/dev/ooc/startup = "normal"); in software-download mode ("swdl")
# they do nothing. install/uninstall/check/firewall always work.
#
# Overrides (environment):
#   SF_PACK          tar(.gz) to unpack            (default /mnt/ota/app/AltScreen.tar.gz)
#   SF_PACK2         optional second pack          (default /mnt/ota/app/wcp.tar.gz)
#   SF_BASE          prepared tree                 (default /mnt/ota/altscreen)
#   SF_DISABLE       off switch: if this file exists, the boot hook does
#                    not run start and start does nothing
#                                                  (default /mnt/ota/app/.sf_disable)
#                    An "sf_disable" file on SD/USB creates it at boot.
#   SF_FORCE         1 = link incomplete directories anyway (at prepare)
#   SF_MARKER        written when start finishes (default /tmp/AltScreenStarted)
#   SF_SCRIPT        script the boot hook runs; install copies this
#                    script there        (default /mnt/ota/app/AltScreen.sh)
#   SF_PLATFORM      NV or QC: skip the mm-ipod detection
#   SF_IGNORE_MODE   1 = run start/stop whatever /dev/ooc/startup says
#   SF_LSD_WAIT      lsd.sh waitfor timeout in s (default 20)
#   SF_RENDER        0 = do not start the RGI renderer supervisor on start
#   SF_RENDER_DELAY  first renderer start after N s (default 30)
#   SF_WCP           0 = do not start the wireless CarPlay daemons on start
#                    (also /mnt/ota/app/wcp_noboot)
#   SF_AAW           0 = do not start aawd (wireless Android Auto) on start
# ============================================================

PATH=/proc/boot:/bin:/usr/bin:/usr/sbin:/sbin:/mnt/app/armle/bin:/mnt/app/armle/sbin:/mnt/app/armle/usr/bin:/mnt/app/armle/usr/sbin
PACK="${SF_PACK:-/mnt/ota/app/AltScreen.tar.gz}"
PACK2="${SF_PACK2:-/mnt/ota/app/wcp.tar.gz}"
BASE="${SF_BASE:-/mnt/ota/altscreen}"
ROOT="$BASE/root"                     # prepared tree: mod files + stock copies at live paths
RD="$ROOT"                            # link target root (is_our_link, check)
OLD_RD=/ramdisk                       # older versions linked from here (stop still removes those)
LINKSF="$BASE/links.txt"              # live paths start links, one per line (made by prepare)
ORIGF="$BASE/orig.txt"                # "<saved path> <source path>" of the stock copies
PREPF="$BASE/prepared.txt"            # what was prepared, from which pack
PLOG="$BASE/prepare.log"              # prepare output (tar list, errors)
# runtime state, in RAM like the links themselves. Flat files: /tmp is
# /dev/shmem on these units and has no directories (mkdir: Function not
# implemented)
STATE=/tmp/.sf_state                  # the links start made, one per line
LOG=/tmp/.sf_start.log                # ln errors of the last start
DISABLE="${SF_DISABLE:-/mnt/ota/app/.sf_disable}"
MARKER="${SF_MARKER:-/tmp/AltScreenStarted}"   # lsd.sh waits for this
WCP_BOOT=/mnt/ota/wcp/wcp-boot.sh
AAW_BOOT=/mnt/ota/wcp/aaw-boot.sh
SELF="$0"                       # this script (the crash watch runs as "$SELF crashwatch")

# Platform: NVIDIA (MHI2, H) has mm-ipod, QC (MHI2Q) has none.
MMIPOD=/mnt/app/armle/usr/sbin/mm-ipod
case "${SF_PLATFORM:-}" in
    NV|nv|H|h) PLAT=NV ;;
    QC|qc|Q|q) PLAT=QC ;;
    *)         if [ -e "$MMIPOD" ] || [ -L "$MMIPOD" ]; then PLAT=NV; else PLAT=QC; fi ;;
esac
if [ "$PLAT" = NV ]; then
    PLAT_NAME="MHI2 (NVIDIA)"
    PLAT_FILES="$MMIPOD"
    PLAT_ORIG="$MMIPOD:$MMIPOD.orig"
else
    PLAT_NAME="MHI2Q (QC)"
    PLAT_FILES=""
    PLAT_ORIG=""
fi

# Paths shadowed by the pack (files or whole directories); those not in
# the pack are left alone. A new file in the pack is only linked once its
# path is listed here (e.g. start-ap.sh: the access point - HT20, channel 6,
# Apple element - called by connectionmanager ~9 s after boot, flash keeps
# the stock script).
LINKS="
$PLAT_FILES
/mnt/app/eso/bin/apps/dio_manager
/mnt/app/eso/bin/apps/gal
/mnt/app/eso/bin/apps/btstack
/mnt/app/eso/bin/apps/smartphone_integrator
/mnt/app/eso/bin/vidaa
/mnt/app/eso/bin/vidcp
/mnt/app/eso/lib/libaaproxy.so
/mnt/app/eso/lib/libcpproxy.so
/mnt/app/eso/lib/libaawusb.so
/mnt/app/eso/lib/libaawmcc.so
/mnt/app/eso/hmi/lib
/mnt/app/eso/hmi/lsd/jars/RGI.jar
/mnt/app/eso/hmi/lsd/jars/AltScreen.jar
/mnt/app/eso/hmi/lsd/jars/WCP.jar
/mnt/app/eso/hmi/lsd/hmi_startup.json
/mnt/app/eso/telephone/start-ap.sh
"

# Four mod parts, in two packs (both may be installed):
#   AltScreen  phone map / video in the cluster: libcpproxy, vidcp, libaaproxy, vidaa
#   RGI        route guidance over the cluster map: librgi_hook, maneuver_render + the
#              /mnt/app/eso/hmi/lib files, RGI.jar, AltScreen.jar (the HMI patches)
#   wireless   libbthook (btstack), receiver hook, daemons, start-ap.sh, WCP.jar
#   aaw        wireless Android Auto: libaawusb (the virtual phone), libaawmcc, the
#              smartphone_integrator wrapper, aawd + aaw-boot.sh (in /mnt/ota/wcp).
#              It uses the wireless part's libbthook (Android Auto Bluetooth channel)
#              and access point.
#   AltScreen.tar.gz = AltScreen + RGI      wcp.tar.gz = RGI + wireless + aaw
# A linked path belongs to a part by where it is (any pack layout works the same).
# Shared: the dio_manager and gal wrappers (they preload per active part), the stock
# copies, the HMI startup file.
# /mnt/ota/app/altscreen_off, rgi_off, wcp_off or aaw_off leaves that part's paths
# unlinked (stock); start writes "v3 <active parts>" to /tmp/.sf_features for the
# wrappers and the HMI (no Smartphone Cluster without the AltScreen part).
# Sets _FT: altscreen | rgi | rgilib (RGI's files, librgi_hook also used by
# wireless CarPlay: linked while RGI or wireless is on) | hmi (AltScreen.jar:
# linked while AltScreen or RGI is on) | wcp | aaw | shared.
FEATURES=/tmp/.sf_features
feature_of()
{
    case "$1" in
        /mnt/ota/wcp/aawd|/mnt/ota/wcp/aaw-boot.sh|/mnt/app/eso/bin/apps/smartphone_integrator|/mnt/app/eso/lib/libaawusb.so|/mnt/app/eso/lib/libaawmcc.so)
            _FT=aaw ;;
        /mnt/ota/wcp/*|/mnt/app/eso/bin/apps/btstack|/mnt/app/eso/telephone/start-ap.sh|/mnt/app/eso/hmi/lsd/jars/WCP.jar)
            _FT=wcp ;;
        /mnt/app/eso/hmi/lsd/jars/RGI.jar)
            _FT=rgi ;;
        /mnt/app/eso/hmi/lsd/jars/AltScreen.jar)
            _FT=hmi ;;         # the patched HMI classes: RGI and the cluster map both use them
        /mnt/app/eso/hmi/lib)
            _FT=rgilib ;;      # RGI's, but wireless needs librgi_hook from it too
        /mnt/app/eso/bin/apps/dio_manager|/mnt/app/eso/bin/apps/gal|/mnt/app/eso/bin/apps/stock|/mnt/app/eso/bin/apps/stock/*|/mnt/app/eso/hmi/lsd/hmi_startup.json)
            _FT=shared ;;
        *)  _FT=altscreen ;;
    esac
}

# HMI startup configuration: lsd.sh already tells the HMI to look for
# $BASE_DIR/lsd/hmi_startup.json before the copy inside lsd.jxe
# (-Dipl.config.dir.hmi_startup). Ours is made on the unit from the firmware's own
# file (resources/hmi_startup.json inside the zip /ifs/lsd.jxe, read with zipget
# from the pack, or unzip if the unit has it) with one change: TerminalMode's
# media dependency (0x0D00) becomes asynchronous, so with CarPlay as the last audio
# source the start no longer waits 20 s for the media domain. Made by prepare
# (install) and again at start whenever the firmware's file changed (cksum), so it
# always matches the firmware; linked like the pack's files (flash stays stock);
# off with /mnt/ota/app/hmi_startup_off. Not made if the stock file does not look
# exactly as expected (then the HMI keeps its own).
HMI_STARTUP=/mnt/app/eso/hmi/lsd/hmi_startup.json
HMI_JXE=/ifs/lsd.jxe
HMI_ENTRY=resources/hmi_startup.json
ZIPGET=/mnt/app/eso/hmi/lib/zipget                # in the tree (both packs)

# hmi_startup_stock <tree root> <out>: the firmware's own file out of lsd.jxe
hmi_startup_stock()
{
    rm -f "$2"
    _HZ="no zipget in the tree, no unzip"
    [ -f "$HMI_JXE" ] || return 1
    if [ -x "$1$ZIPGET" ]; then
        "$1$ZIPGET" "$HMI_JXE" "$HMI_ENTRY" "$2" 2>/dev/null && return 0
        _HZ="zipget exit $? (2: not in the archive, 3: unsupported, 4: data error)"
    fi
    if command -v unzip > /dev/null 2>&1; then
        unzip -p "$HMI_JXE" "$HMI_ENTRY" > "$2" 2>/dev/null && [ -s "$2" ] && return 0
    fi
    rm -f "$2"
    return 1
}

# hmi_startup_make <tree root>: <root>$HMI_STARTUP up to date, or removed.
# Sets _HS: "" = ready to link, else why not.
hmi_startup_make()
{
    _HS=""
    _HO="$1$HMI_STARTUP"
    _HF="$BASE/hmi_startup.stock.json"
    if [ ! -f "$HMI_JXE" ]; then
        rm -f "$_HO" "$_HO.src"; _HS="no $HMI_JXE"; return
    fi
    if ! hmi_startup_stock "$1" "$_HF"; then
        rm -f "$_HO" "$_HO.src"; _HS="cannot read $HMI_ENTRY from $HMI_JXE: $_HZ"; return
    fi
    _HSUM=$(cksum < "$_HF")
    if [ -f "$_HO" ] && [ "$(cat "$_HO.src" 2>/dev/null)" = "$_HSUM" ]; then return; fi
    rm -f "$_HO" "$_HO.src"
    _HL1=$(grep -n '"name": "TerminalMode",' "$_HF" | sed -n '1s/:.*//p')
    _HL2=$(grep -n '"required_state": "0x0D00"' "$_HF" | sed -n '1s/:.*//p')
    _HN=$(grep -c '"required_state": "0x0D00"' "$_HF")
    if [ -z "$_HL1" ] || [ -z "$_HL2" ] || [ "$_HN" != 1 ] || [ "$_HL2" -le "$_HL1" ]; then
        _HS="stock file not as expected (TerminalMode / 0x0D00 not found once)"; return
    fi
    # the 0x0D00 line must belong to TerminalMode: no other component starts in between
    if [ "$(sed -n "$((_HL1 + 1)),$((_HL2 - 1))p" "$_HF" | grep -c '"name": "[^"]*",')" != 0 ]; then
        _HS="stock file not as expected (0x0D00 is not TerminalMode's)"; return
    fi
    if sed -n "$((_HL2 + 1))p" "$_HF" | grep -q start_asynchron; then
        _HS="already asynchronous in the stock file - nothing to do"; return
    fi
    _HCR=""
    sed -n "${_HL2}p" "$_HF" | grep -q "$(printf '\r')" && _HCR=$(printf '\r')
    _HIND=$(sed -n "${_HL2}s/\".*//p" "$_HF")
    mkdir -p "${_HO%/*}" 2>/dev/null
    sed "${_HL2}s/\"0x0D00\"/\"0x0D00\",${_HCR}\\
${_HIND}\"start_asynchron\": true/" "$_HF" > "$_HO.new" 2>/dev/null
    # check: one line more, one start_asynchron more, the line now ends with a comma
    if [ "$(( $(wc -l < "$_HO.new") ))" != "$(( $(wc -l < "$_HF") + 1 ))" ] ||
       [ "$(grep -c start_asynchron "$_HO.new")" != "$(( $(grep -c start_asynchron "$_HF") + 1 ))" ] ||
       ! sed -n "${_HL2}p" "$_HO.new" | grep -q '"0x0D00",'; then
        rm -f "$_HO.new"; _HS="could not make the file (check failed)"; return
    fi
    mv -f "$_HO.new" "$_HO" && echo "$_HSUM" > "$_HO.src" || { rm -f "$_HO.new" "$_HO"; _HS="could not write $_HO"; return; }
    echo "  HMI startup file made from $HMI_JXE ($HMI_ENTRY): TerminalMode media dependency asynchronous"
}

# Stock binaries a wrapper starts: "<live path>:<path the wrapper execs>".
# prepare saves the stock file to ROOT/<that path> when the pack holds the
# wrapper; start links it. They keep their file name (stock/<name>), so the
# processes are still called dio_manager, gal, btstack, smartphone_integrator
# (pidin, slay, scripts).
ORIG="
$PLAT_ORIG
/mnt/app/eso/bin/apps/dio_manager:/mnt/app/eso/bin/apps/stock/dio_manager
/mnt/app/eso/bin/apps/gal:/mnt/app/eso/bin/apps/stock/gal
/mnt/app/eso/bin/apps/btstack:/mnt/app/eso/bin/apps/stock/btstack
/mnt/app/eso/bin/apps/smartphone_integrator:/mnt/app/eso/bin/apps/stock/smartphone_integrator
"

# Text that marks a file as one of our wrappers (never saved as stock).
# QC_WiFi_AAuto: the wireless Android Auto bench wrappers (gal, smartphone_integrator) that
# may still be on a unit's flash from the tests without the pack.
MOD_TAGS='RGI-H shim|RGI-Q2? TEST wrapper|dio_manager preload wrapper|gal preload wrapper|btstack - wrapper|smartphone_integrator preload wrapper|QC_WiFi_AAuto'

# Paths older (pre-preload) packs linked. Never linked any more; stop
# still removes such a link and start refuses to run while one is left.
LEGACY="
/mnt/app/eso/lib/libairplay.so
"

# ============================================================
# HELPERS
# ============================================================

# MMI run mode from /dev/ooc/startup: "normal" or "swdl" (software
# download). The node has no trailing newline - read still sets it.
OOC_STARTUP=/dev/ooc/startup
run_mode()
{
    _RM=""
    [ -r "$OOC_STARTUP" ] && read _RM < "$OOC_STARTUP"
    echo "$_RM"
}

# True if start/stop may run ($1 = command name, for the message).
# Sets MMI_MODE. Only "normal" runs; an unreadable node is taken as
# normal (with a note), anything else - swdl - does not run.
mode_ok()
{
    MMI_MODE=$(run_mode)
    [ "${SF_IGNORE_MODE:-0}" = 1 ] && return 0
    case "$MMI_MODE" in
        normal) return 0 ;;
        "")     echo "NOTE: $OOC_STARTUP not readable - assuming normal mode"
                return 0 ;;
        *)      echo "MMI is in '$MMI_MODE' mode, not normal - $1 not run."
                return 1 ;;
    esac
}

# Every path start may link: the saved stock copies, then LINKS
cur_links()
{
    for _P in $ORIG; do _S="${_P#*:}"; echo "$_S"; echo "${_S%/*}"; done
    for _P in $LINKS; do echo "$_P"; done
}

# cur_links plus LEGACY (for stop and the leftover-link check)
all_links()
{
    cur_links
    for _P in $LEGACY; do echo "$_P"; done
    [ -f "$LINKSF" ] && cat "$LINKSF"          # incl. the file-by-file /mnt/ota/wcp links
    [ -f "$STATE" ] && cat "$STATE"
}

# True if $1 is our procnto link: pointing into the prepared tree, or into
# /ramdisk (older versions of this script)
is_our_link()
{
    [ -L "$1" ] || return 1
    _L=$(ls -ld "$1" 2>/dev/null)
    case "$_L" in
        *"> $ROOT$1"|*"> $OLD_RD$1") return 0 ;;
    esac
    return 1
}

# Stock entries of directory $1 that tree $2 does not have
# (a directory link would hide them)
dir_missing()
{
    find "$1" ! -type d 2>/dev/null | while read _F; do
        [ -e "$2$_F" ] || [ -L "$2$_F" ] || echo "$_F"
    done
}

# True if $1 and $2 have the same content (cmp; file size if cmp is missing)
same_file()
{
    [ -f "$2" ] || return 1
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$1" "$2"
    else
        [ $(( $(wc -c < "$1") )) -eq $(( $(wc -c < "$2") )) ]
    fi
}

# Real stock file for live path $1 ($2 = where the wrapper execs it, $3 =
# the wrapper in the new tree): the flash file, or - if flash already holds
# a wrapper/mod - the original kept beside it (stock/<n>, rgd_real/<n>,
# <n>.orig). Never a link, never one of our wrappers.
stock_of()
{
    for _C in "$1" "$2" "${1%/*}/stock/${1##*/}" "${1%/*}/rgd_real/${1##*/}" "$1.orig"; do
        [ -f "$_C" ] || continue
        [ -L "$_C" ] && continue
        grep -E "$MOD_TAGS" "$_C" >/dev/null 2>&1 && continue
        same_file "$_C" "$3" && continue
        echo "$_C"
        return 0
    done
    return 1
}


# ============================================================
# RGI renderer supervisor (Android Auto needs it from boot; the
# CarPlay hook - mm-ipod shim / dio_manager wrapper - only runs for
# CarPlay).  Singleton - a second start just exits.
# /mnt/ota/app/rgd_disable or /tmp/rgd_disable keeps it off.
# The H supervisor keeps its pid files in /dev/shmem, the QC one in
# /tmp: stop looks in both.
# ============================================================

RGI_DIR=/mnt/app/eso/hmi/lib/rgi
RGI_SUP="$RGI_DIR/rgi_render_sup.sh"
RGI_PID_DIRS="/dev/shmem /tmp"
RGD_DISABLE="/mnt/ota/app/rgd_disable /tmp/rgd_disable"
SF_RENDER_DELAY="${SF_RENDER_DELAY:-30}"

start_renderer()
{
    [ "${SF_RENDER:-1}" = "0" ] && { echo "Renderer: not started (SF_RENDER=0)"; return 0; }
    [ -f "$RGI_SUP" ] || return 0
    [ "${ON_RGI:-1}" = 0 ] && return 0                 # RGI part not installed / off
    for _DF in $RGD_DISABLE; do
        [ -f "$_DF" ] && { echo "Renderer: off ($_DF)"; return 0; }
    done
    LD_PRELOAD= /bin/sh "$RGI_SUP" "$SF_RENDER_DELAY" </dev/null >/dev/null 2>&1 &
    echo "Renderer: supervisor started (first start in $SF_RENDER_DELAY s)"
}

# Supervisor and renderer run from the linked tree: stop them before unlinking.
stop_renderer()
{
    for _PF in $(for _PD in $RGI_PID_DIRS; do
                     echo "$_PD/rgi_render_sup.pid $_PD/rgi_maneuver_render.pid"
                 done); do
        if [ -f "$_PF" ]; then
            read _RP < "$_PF"
            [ -n "$_RP" ] && kill "$_RP" 2>/dev/null && echo "Stopped pid $_RP (${_PF##*/})"
            rm -f "$_PF"
        fi
    done
    slay -f maneuver_render 2>/dev/null
}


# ============================================================
# STOP
# ============================================================



# ============================================================
# Wireless CarPlay daemons (wcpd, wcppaird): /mnt/ota/wcp/wcp-boot.sh.
# Started in the background - it waits for the MFi chip's i2c bus itself.
# The btstack wrapper starts it too (whichever comes first; a second start
# finds wcpd running and does nothing). dio_manager is not started here:
# wcpd starts it on demand when an iPhone is on Bluetooth.
# Off: SF_WCP=0 or /mnt/ota/app/wcp_noboot.
# ============================================================

start_wcp()
{
    [ "${SF_WCP:-1}" = 0 ] && { echo "Wireless CarPlay: not started (SF_WCP=0)"; return 0; }
    [ -f "$WCP_BOOT" ] || return 0
    [ -f /mnt/ota/app/wcp_noboot ] && { echo "Wireless CarPlay: off (/mnt/ota/app/wcp_noboot)"; return 0; }
    ( unset LD_PRELOAD; /bin/sh "$WCP_BOOT" start ) </dev/null >/dev/null 2>&1 &
    echo "Wireless CarPlay: daemons starting ($WCP_BOOT)"
}

stop_wcp()
{
    [ -f "$WCP_BOOT" ] || return 0
    ( unset LD_PRELOAD; /bin/sh "$WCP_BOOT" stop ) </dev/null >/dev/null 2>&1
    echo "Wireless CarPlay: daemons stopped"
}

# ============================================================
# Wireless Android Auto: aawd (/mnt/ota/wcp/aaw-boot.sh). aawd takes the
# Android Auto Bluetooth channel from libbthook (127.0.0.1:57344), gives the
# phone the access point's details, accepts it on uap0 tcp 5288 and relays it
# to gal through the virtual phone (libaawusb). Started only while the aaw part
# is on; aaw-boot.sh itself also honours aaw_off.
# Off: SF_AAW=0 or /mnt/ota/app/aaw_off.
# ============================================================

start_aaw()
{
    [ "${SF_AAW:-1}" = 0 ] && { echo "Wireless Android Auto: aawd not started (SF_AAW=0)"; return 0; }
    [ -f "$AAW_BOOT" ] || return 0
    [ "${ON_AAW:-1}" = 0 ] && return 0                 # aaw part not installed / off
    ( unset LD_PRELOAD; /bin/sh "$AAW_BOOT" start ) </dev/null >/dev/null 2>&1 &
    echo "Wireless Android Auto: aawd starting ($AAW_BOOT)"
}

stop_aaw()
{
    [ -f "$AAW_BOOT" ] || return 0
    ( unset LD_PRELOAD; /bin/sh "$AAW_BOOT" stop ) </dev/null >/dev/null 2>&1
    echo "Wireless Android Auto: aawd stopped"
}


# ============================================================
# CRASH WATCH: switch our part off in a program that keeps crashing
#
# The system's dumper (boot.sh: dumper -d /mnt/ota/system/core) leaves a
# core file for every process that dies of a fault (SIGSEGV, SIGBUS, ...);
# a normal exit, a slay or a launcher restart leaves none. The watcher
# looks at that directory every CW_POLL s (a file newer than its stamp =
# a crash; the name before the first dot is the program - the dumper
# numbers repeated cores, so names alone would not do). Two crashes of the
# same program within CW_WINDOW s switch OUR part in it off; the program's
# next start (its launcher restarts it) then runs stock:
#   btstack             /tmp/bthook_off      Bluetooth + calls stay, no wireless
#   dio_manager (USB)   /tmp/cpproxy_disable + /tmp/rgd_disable: plain CarPlay
#   dio_manager (wireless, /tmp/wcp_dio_mode)  /tmp/wcp_dio_off: no more wireless
#   gal                 /tmp/aaproxy_disable + /tmp/aawusb_off: plain Android Auto
#                       (both of our libraries in gal off: the core does not say which)
#   smartphone_integrator  /tmp/aawusb_off   USB phones as stock, no wireless Android
#                       Auto (its wrapper also counts its own starts, see there)
#   maneuver_render     /tmp/rgd_disable      the supervisor stops restarting it
#   altscreen_present   /tmp/cpproxy_disable  no cluster video
#   j9 (HMI)            $DISABLE (sticky: all mods off at every boot until it is
#                       deleted) and the overlay is stopped at once, so the HMI
#                       comes back stock without waiting for a reboot
# The /tmp files hold the reason and last until the next reboot.
# Log (only on events): /tmp/crashwatch.log. Off: SF_CRASHWATCH=0.
# ============================================================

CORE_DIR=/mnt/ota/system/core
CW_PID=/tmp/crashwatch.pid
CW_LOG=/tmp/crashwatch.log
CW_WINDOW=600
CW_POLL=10

cw_log() { echo "`date` $*" >> "$CW_LOG" 2>/dev/null; }

start_crashwatch()
{
    [ "${SF_CRASHWATCH:-1}" = 0 ] && { echo "Crash watch: not started (SF_CRASHWATCH=0)"; return 0; }
    if [ -f "$CW_PID" ]; then
        read _CP < "$CW_PID"
        [ -n "$_CP" ] && kill -0 "$_CP" 2>/dev/null && { echo "Crash watch: running (pid $_CP)"; return 0; }
    fi
    ( unset LD_PRELOAD; /bin/sh "$SELF" crashwatch ) </dev/null >/dev/null 2>&1 &
    echo "Crash watch: started ($CORE_DIR)"
}

stop_crashwatch()
{
    [ -f "$CW_PID" ] || return 0
    read _CP < "$CW_PID"
    [ -n "$_CP" ] && kill "$_CP" 2>/dev/null && echo "Crash watch: stopped (pid $_CP)"
    rm -f "$CW_PID"
}

# cw_act <key> <reason> - our part in that program off
cw_act()
{
    case "$1" in
        btstack)           echo "$2" > /tmp/bthook_off ;;
        dio_usb)           echo "$2" > /tmp/cpproxy_disable; echo "$2" > /tmp/rgd_disable ;;
        dio_wireless)      echo "$2" > /tmp/wcp_dio_off ;;
        gal)               echo "$2" > /tmp/aaproxy_disable; echo "$2" > /tmp/aawusb_off ;;
        smartphone_integrator) echo "$2" > /tmp/aawusb_off ;;
        maneuver_render)   echo "$2" > /tmp/rgd_disable ;;
        altscreen_present) echo "$2" > /tmp/cpproxy_disable ;;
        j9)                echo "$2" > "$DISABLE"
                           sync 2>/dev/null
                           cw_log "HMI crash loop: $DISABLE written, overlay stopped (stock HMI now and at every boot until $DISABLE is deleted)"
                           rm -f "$CW_PID"            # stop_overlay must not kill this watcher
                           ( stop_overlay ) >> "$CW_LOG" 2>&1
                           exit 0 ;;
    esac
}

# cw_crash <program name from the core file>
cw_crash()
{
    _K=$1
    if [ "$_K" = dio_manager ]; then
        _M=
        [ -f /tmp/wcp_dio_mode ] && read _M _MP < /tmp/wcp_dio_mode
        if [ "$_M" = wireless ]; then _K=dio_wireless; else _K=dio_usb; fi
    fi
    case "$_K" in
        btstack|dio_usb|dio_wireless|gal|smartphone_integrator|maneuver_render|altscreen_present|j9) ;;
        *) return 0 ;;
    esac
    eval "_DONE=\${CW_DONE_$_K:-}"
    [ -n "$_DONE" ] && return 0
    eval "_LAST=\${CW_T_$_K:-}"
    eval "CW_T_$_K=$SECONDS"
    cw_log "crash: $1 ($_K)"
    [ -n "$_LAST" ] || return 0
    _DT=$((SECONDS - _LAST))
    [ "$_DT" -le "$CW_WINDOW" ] || return 0
    eval "CW_DONE_$_K=1"
    cw_log "$_K crashed twice within $_DT s - our part in it switched off"
    cw_act "$_K" "`date`: $1 crashed twice within $_DT s - our part switched off by the AltScreen.sh crash watch"
}

# The core files as "name:size:month+day+time", one word each (ls -l: perms
# links owner group size month day time name).
cw_sig()
{
    ls -l "$CORE_DIR" 2>/dev/null | while read _a _b _c _d _sz _m1 _m2 _m3 _nm; do
        case "$_nm" in *.core*) echo "$_nm:$_sz:$_m1$_m2$_m3" ;; esac
    done
}

# A crash is a core file that is new or changed since the watch started, counted
# once it has stopped changing (the next poll) and once per program per poll.
# Not by time stamps: the clock starts at 1 Jan 1970 00:00 at every boot, so a
# core file from an earlier boot written at "00:04" looked newer than this boot's
# stamp and was counted again at every poll until the clock passed 00:04 (car
# test 27 Oct, 5092: an empty dio_manager.core.gz from an earlier boot - "dio_usb
# crashed twice" at 14 s and 25 s, "dio_wireless" at 35 s and 45 s, nothing
# crashed; RGI, cluster video and wireless CarPlay were switched off for nothing).
crash_watch()
{
    [ -d "$CORE_DIR" ] || { cw_log "no $CORE_DIR - crash watch not running"; return 0; }
    echo $$ > "$CW_PID"
    _OLD=" $(echo $(cw_sig)) "
    _PEND=" "
    cw_log "crash watch: `echo $_OLD | wc -w` core file(s) already there - not counted"
    while :; do
        sleep "$CW_POLL"
        _NEW=" $(echo $(cw_sig)) "
        [ "$_NEW" = "$_OLD" ] && [ "$_PEND" = " " ] && continue
        _NP=" "
        _SEEN=" "
        for _L in $_NEW; do
            case "$_OLD" in
                *" $_L "*)                          # unchanged since the last poll
                    case "$_PEND" in
                        *" $_L "*)                  # was new/changed: now complete
                            _P=${_L%%:*}; _P=${_P%%.*}
                            case "$_SEEN" in
                                *" $_P "*) ;;
                                *) _SEEN="$_SEEN$_P "; cw_crash "$_P" ;;
                            esac ;;
                    esac ;;
                *) _NP="$_NP$_L " ;;                # new or still being written
            esac
        done
        _PEND=$_NP
        _OLD=$_NEW
    done
}


# ============================================================
# CONTROL FILES - all in /mnt/ota/app (/tmp ones: until the next reboot).
# "check" lists those that are set: name | what it is for.
# ============================================================
CONTROL_FILES="
.sf_disable|all mods off (boot hook)
altscreen_off|AltScreen part off (no phone map in cluster)
rgi_off|RGI part off (no route guidance)
wcp_off|wireless CarPlay off (stock BT/Wi-Fi)
aaw_off|wireless Android Auto off
aawusb_off|virtual-phone shim off (SI, gal)
debug_aaw|wireless Android Auto logs on
hmi_startup_off|stock HMI startup file (20 s wait)
wcp_wifi_on|Wi-Fi switched on by the HMI (empty: once, "always": every start)
wcp_keep_ipv6|Keep ipv6 add on WiFi (slow startup otherwise)
hotspot_note|stock Wi-Fi hotspot data note also for CarPlay / Android Auto phones
rgi_box_near|RGI arrow box only near the turn (empty/follow: follow-road outside, none: nothing outside)
debug_wificp|wireless CarPlay logs on
debug_wificp_raw|plus raw dumps
debug_hook|hook and renderer logs
debug_video|video bridge logs on
debug_java|Java HMI logs on
bthook_off|Bluetooth hook off, stock
bthook_test|Bluetooth hook logs only
bthook_noask|BT address from stack
bthook_nousbresume|no wireless after USB
wcp_noboot|wireless daemons not started
wcp.conf|wireless CarPlay settings
wcp_hmi.conf|HMI bridge settings
wcp_btmac|car Bluetooth address (override)
rgd_disable|route renderer not started
rgi_passive|RGI hook only logs
rgi_java_nodefer|CarPlay modules start immediately
rgi_projection_nowait|cluster switch without waiting
rgi_pb_keep|stock phonebook kept
rgi_alt_hide|altitude hidden too
rgi_scale_keep|map scale stays visible
rgi_cluster_fps|cluster frame rate (test)
rgi_cluster_restore_fps|cluster rate after (test)
aa_cluster.daynight|AA theme follows day/night
rgd_window_id|renderer window id
rgd_swap_interval|renderer swap interval
"
CONTROL_TMP="
/tmp/rgd_disable|route renderer not started
/tmp/cpproxy_disable|cluster (libcpproxy) off
/tmp/aaproxy_disable|AA cluster (libaaproxy) off
/tmp/aawusb_off|virtual-phone shim off (SI, gal)
/tmp/aaw_off|AA Bluetooth channel off
/tmp/wcp_dio_off|wireless dio_manager not started
/tmp/rgi_passive|RGI hook only logs
/tmp/rgi_java_nodefer|CarPlay modules start immediately
/tmp/bthook_off|Bluetooth hook off, stock
/tmp/altscreen_port|test port file
"

# control_lines - one line per control file that is set, and per unknown file in
# /mnt/ota/app. A function of its own: QNX's ksh ends a $( ... ) at the ")" of a
# case pattern inside it ("syntax error: ';;' unexpected"), so no case in there.
control_lines()
{
    echo "$CONTROL_FILES" | while IFS='|' read _F _W; do
        [ -n "$_F" ] && [ -e "/mnt/ota/app/$_F" ] || continue
        printf '  set   %-24s %s\n' "$_F" "$_W"
        _RS=
        [ "$_F" = .sf_disable ] && [ -s "/mnt/ota/app/$_F" ] && read _RS < "/mnt/ota/app/$_F"
        [ -n "$_RS" ] && printf '          %s\n' "$_RS"
    done
    echo "$CONTROL_TMP" | while IFS='|' read _F _W; do
        [ -n "$_F" ] && [ -e "$_F" ] || continue
        printf '  set   %-24s %s (until reboot)\n' "$_F" "$_W"
        _RS=
        [ -s "$_F" ] && read _RS < "$_F"
        [ -n "$_RS" ] && printf '          %s\n' "$_RS"
    done
    for _P in /mnt/ota/app/* /mnt/ota/app/.[!.]*; do
        [ -e "$_P" ] || continue
        _F=${_P##*/}
        case "$_F" in
            AltScreen.sh|*.tar.gz) continue ;;
            AltScreen.tar.gz.checksum|AltScreen.tar.gz.fileinfo) continue ;;   # install markers
        esac
        echo "$CONTROL_FILES" | grep "^$_F|" >/dev/null 2>&1 && continue
        printf '  ?     %-24s not a known control file\n' "$_F"
    done
}

# check_controls - the control files that are set, each with what it is for;
# other files in /mnt/ota/app are listed as not known
check_controls()
{
    echo ""
    echo "--- control files (/mnt/ota/app)"
    _OUT=$(control_lines)
    if [ -n "$_OUT" ]; then echo "$_OUT"; else echo "  (none set)"; fi
    echo ""
    echo "--- crash watch ($CORE_DIR)"
    _CP=
    [ -f "$CW_PID" ] && read _CP < "$CW_PID"
    if [ -n "$_CP" ] && kill -0 "$_CP" 2>/dev/null; then
        echo "  running (pid $_CP)"
    else
        echo "  WARN  not running"
    fi
    [ -f "$CW_LOG" ] && tail -5 "$CW_LOG" | sed 's/^/  /'
}

# ============================================================
# FLAGS: control files from SD/USB at install   (AltScreen.sh flags [folder])
# ============================================================
# install copies every control file found in a "flags" folder on the install
# medium into /mnt/ota/app: empty markers and files with a value alike (the CR
# of Windows line ends removed). The folder is looked for next to this script,
# then at the root of the SD cards / USB sticks (FLAG_DIRS); the first one found
# is used. Only names listed in CONTROL_FILES are copied - "name.txt" counts as
# "name" (Windows hides the extension); anything else (README, Thumbs.db, ._*)
# is skipped and listed. Flags already in /mnt/ota/app that the folder does not
# have are left as they are.
APP_DIR=/mnt/ota/app
FLAG_DIRS="${SF_FLAG_DIRS:-/fs/sda0/flags /fs/sda1/flags /fs/sdb0/flags /fs/sdb1/flags /fs/usb0/flags /fs/usb1/flags /fs/mmc0/flags}"

# flags_dir [folder]: the flags folder to use (empty: none). No case statement:
# called inside $( ) (see control_lines).
flags_dir()
{
    if [ -n "$1" ]; then
        [ -d "$1" ] && echo "$1"
        return 0
    fi
    _FD=${0%/*}
    [ "$_FD" = "$0" ] && _FD=.
    _FD=$(cd "$_FD" 2>/dev/null && pwd)
    if [ -n "$_FD" ] && [ "$_FD" != "$APP_DIR" ] && [ -d "$_FD/flags" ]; then
        echo "$_FD/flags"
        return 0
    fi
    for _FD in $FLAG_DIRS; do
        [ -d "$_FD" ] && { echo "$_FD"; return 0; }
    done
    return 0
}

# control_what <name>: the CONTROL_FILES description (empty if not a control file)
control_what()
{
    echo "$CONTROL_FILES" | while IFS='|' read _CF _CW; do
        [ -n "$_CF" ] && [ "$_CF" = "$1" ] && { echo "${_CW:-control file}"; break; }
    done
}

copy_flags()
{
    echo ""
    echo "============================================================"
    echo "FLAGS: control files from a flags folder -> $APP_DIR"
    echo "============================================================"
    _FLD=$(flags_dir "$1")
    if [ -z "$_FLD" ]; then
        if [ -n "$1" ]; then echo "  ERROR: $1 is not a folder"; return 1; fi
        echo "  no flags folder (next to $0, or $FLAG_DIRS) - nothing set"
        return 0
    fi
    echo "  from $_FLD"
    mkdir -p "$APP_DIR" 2>/dev/null
    _NF=0; _NX=0
    for _FP in "$_FLD"/* "$_FLD"/.[!.]*; do
        [ -f "$_FP" ] || continue
        _FN=${_FP##*/}
        _FW=$(control_what "$_FN")
        if [ -z "$_FW" ] && [ "${_FN%.txt}" != "$_FN" ]; then
            _FW=$(control_what "${_FN%.txt}")
            [ -n "$_FW" ] && _FN=${_FN%.txt}
        fi
        if [ -z "$_FW" ]; then
            echo "  skip  ${_FP##*/} (not a known control file)"
            _NX=$((_NX + 1))
            continue
        fi
        _FT="$APP_DIR/$_FN"
        rm -f "$_FT.new"
        if { tr -d '\015' < "$_FP" > "$_FT.new" 2>/dev/null || cp "$_FP" "$_FT.new"; } &&
           mv -f "$_FT.new" "$_FT"
        then
            _FV=""
            if [ -s "$_FT" ]; then
                if [ $(( $(wc -l < "$_FT") )) -le 1 ]; then read _FV < "$_FT"; _FV=" = $_FV"
                else _FV=" ($(( $(wc -l < "$_FT") )) lines)"; fi
            fi
            [ "$_FN" != "${_FP##*/}" ] && _FV="$_FV  (from ${_FP##*/})"
            echo "  set   $_FN$_FV - $_FW"
            _NF=$((_NF + 1))
        else
            rm -f "$_FT.new"
            echo "  ERROR could not write $_FT"
        fi
    done
    sync
    echo "  $_NF flag(s) set in $APP_DIR, $_NX skipped"
    return 0
}

# ============================================================
# PREPARE: pack -> /mnt/ota/altscreen/root (+ stock copies)
#
# Everything is built in root.new and only then swapped in, so an
# interrupted prepare never leaves a half tree behind: the old tree (if
# any) stays in use until the new one is complete.
# Refuses while the overlay is active (its links point into the tree).
# ============================================================

prepare_tree()
{
    echo ""
    echo "============================================================"
    echo "$PLAT_NAME PREPARE  $PACK -> $ROOT"
    echo "============================================================"

    if [ ! -f "$PACK" ] && [ ! -f "$PACK2" ]; then
        echo "ERROR: no pack: neither $PACK (AltScreen CarPlay) nor $PACK2 (wireless CarPlay)"
        return 1
    fi
    [ -f "$PACK" ] || echo "AltScreen CarPlay: no $PACK - not installed"
    [ -f "$PACK2" ] && echo "Wireless CarPlay pack: $PACK2"
    if [ -f "$STATE" ]; then
        echo "ERROR: overlay active - run: $0 stop   (install does this by itself)"
        return 1
    fi
    for _P in $(all_links); do
        if [ -L "$_P" ]; then
            echo "ERROR: $_P is a link (leftover overlay?) - run: $0 stop"
            return 1
        fi
    done

    _NEW="$BASE/root.new"
    case "$BASE" in ""|/) echo "ERROR: BASE='$BASE'"; return 1 ;; esac
    rm -rf "$_NEW" "$BASE/root.old"
    mkdir -p "$_NEW" || { echo "ERROR: cannot create $_NEW"; return 1; }
    : > "$PLOG"

    # Each pack is unpacked into its own empty directory and merged into the new
    # tree file by file: a second archive unpacked over the first one would make
    # tar try to replace directories that are already there. Files in both packs
    # (the dio_manager wrapper, librgi_hook.so) are the same; the later pack wins.
    : > "$BASE/unpacked.txt"
    _STG="$BASE/root.pk"
    for _PK in "$PACK" "$PACK2"; do
        [ -f "$_PK" ] || continue
        case "$_PK" in
            *.tar) _Z="" ;;
            *)     _Z="z" ;;
        esac
        echo "Unpacking $_PK ..."
        rm -rf "$_STG"; mkdir -p "$_STG"
        if ! tar -${_Z}xvf "$_PK" -C "$_STG" >> "$BASE/unpacked.txt" 2>>"$PLOG"; then
            echo "ERROR: tar failed:"
            sed 's/^/  | /' "$PLOG"
            rm -rf "$_NEW" "$_STG"
            return 1
        fi
        _MERR=0
        ( cd "$_STG" && find . -type f ) > "$BASE/.pkfiles"
        while read _F; do
            _F="${_F#./}"
            mkdir -p "$_NEW/${_F%/*}" 2>/dev/null
            rm -f "$_NEW/$_F"
            mv "$_STG/$_F" "$_NEW/$_F" 2>>"$PLOG" || cp -p "$_STG/$_F" "$_NEW/$_F" 2>>"$PLOG" || _MERR=1
        done < "$BASE/.pkfiles"
        rm -rf "$_STG" "$BASE/.pkfiles"
        if [ "$_MERR" = 1 ]; then
            echo "ERROR: could not merge $_PK into the tree:"
            sed 's/^/  | /' "$PLOG"
            rm -rf "$_NEW"
            return 1
        fi
    done
    echo "  $(grep -c . "$BASE/unpacked.txt") entries"

    # HMI startup file, made from this firmware's lsd.jxe (not from a pack)
    rm -f "$_NEW$HMI_STARTUP"                   # an older pack may still carry a copy
    hmi_startup_make "$_NEW"
    [ -n "$_HS" ] && echo "  HMI startup file not made: $_HS (the HMI keeps its own)"

    # mnt/ota/... (wireless CarPlay): linked file by file (see the header)
    : > "$BASE/ota.txt.new"
    if [ -d "$_NEW/mnt/ota" ]; then
        rm -rf "$_NEW/mnt/ota/wcp/pair" "$_NEW/mnt/ota/altscreen" 2>/dev/null
        find "$_NEW/mnt/ota" -type f 2>/dev/null | while read _F; do echo "${_F#$_NEW}"; done > "$BASE/ota.txt.new"
        _NO=0; _NR=0
        while read _D; do
            mkdir -p "${_D%/*}" 2>/dev/null           # real directory: data written there stays
            if [ -f "$_D" ] && [ ! -L "$_D" ]; then   # an old real copy: the tree's file replaces it
                rm -f "$_D" && _NR=$((_NR + 1))
            fi
            _NO=$((_NO + 1))
        done < "$BASE/ota.txt.new"
        echo "  $_NO file(s) under /mnt/ota (wireless CarPlay), linked file by file; $_NR old copies there removed"
    else
        echo "  NOTE  the pack has no mnt/ota/wcp files: the wireless CarPlay part is not in it"
        echo "        (built without manifest_wcp.txt? check: tar -tzf $PACK | grep mnt/ota)"
    fi

    for _P in $LEGACY; do
        [ -e "$_NEW$_P" ] && echo "  NOTE  pack still has $_P - not linked (preload layout keeps it stock), remove it from the pack"
    done

    # Stock copies for the wrappers the pack holds
    : > "$BASE/orig.txt.new"
    _SKIPW=""
    for _PAIR in $ORIG; do
        _P="${_PAIR%%:*}"; _S="${_PAIR#*:}"
        [ -e "$_NEW$_P" ] || continue                 # no wrapper in the pack: stock stays as it is
        _SRC=$(stock_of "$_P" "$_S" "$_NEW$_P")
        if [ -z "$_SRC" ]; then
            echo "  ERROR no stock $_P found (flash, stock/, rgd_real/, .orig: all modded, links or missing)"
            _SKIPW="$_SKIPW $_P"
            continue
        fi
        [ "$_SRC" != "$_P" ] && echo "  NOTE  flash $_P is modded - using $_SRC as stock"
        mkdir -p "$_NEW${_S%/*}"
        # the copy in the current tree, if it is still this stock file: hard
        # link (no data copied) or a local copy; else copy it from flash
        _HOW=""
        if [ -f "$ROOT$_S" ] && [ ! "$_SRC" -nt "$ROOT$_S" ] &&
           [ $(( $(wc -c < "$_SRC") )) -eq $(( $(wc -c < "$ROOT$_S") )) ]; then
            if ln "$ROOT$_S" "$_NEW$_S" 2>/dev/null; then _HOW="kept"
            elif cp -p "$ROOT$_S" "$_NEW$_S" 2>>"$PLOG"; then _HOW="kept (copied)"
            fi
        fi
        if [ -z "$_HOW" ] && cp -p "$_SRC" "$_NEW$_S" 2>>"$PLOG" && same_file "$_SRC" "$_NEW$_S"; then
            _HOW="saved"
        fi
        if [ -n "$_HOW" ] && chmod 0755 "$_NEW$_S"; then
            echo "  $_HOW $_SRC -> $ROOT$_S"
            echo "$_S $_SRC" >> "$BASE/orig.txt.new"
        else
            echo "  ERROR copy $_SRC -> $_NEW$_S failed"
            rm -f "$_NEW$_S"
            _SKIPW="$_SKIPW $_P"
        fi
    done

    # The list start links: stock copies first, then the pack's paths
    : > "$BASE/links.txt.new"
    _NL=0; _NS=0
    # (a saved path whose directory is not on flash - stock/btstack - is
    # reached by linking that directory, which then holds only our copy)
    while read _S _SRC; do
        if [ -d "${_S%/*}" ] || [ -L "${_S%/*}" ]; then _LP="$_S"; else _LP="${_S%/*}"; fi
        grep -qFx "$_LP" "$BASE/links.txt.new" 2>/dev/null && continue
        echo "$_LP" >> "$BASE/links.txt.new"; _NL=$((_NL + 1))
    done < "$BASE/orig.txt.new"
    while read _D; do
        [ -n "$_D" ] && { echo "$_D" >> "$BASE/links.txt.new"; _NL=$((_NL + 1)); }
    done < "$BASE/ota.txt.new"
    rm -f "$BASE/ota.txt.new"
    for _P in $LINKS; do
        [ -e "$_NEW$_P" ] || continue
        case " $_SKIPW " in
            *" $_P "*) echo "  skip  $_P (no stock copy saved)"; _NS=$((_NS + 1)); continue ;;
        esac
        if [ -d "$_NEW$_P" ] && [ -d "$_P" ]; then
            dir_missing "$_P" "$_NEW" > "$BASE/.missing"
            if [ -s "$BASE/.missing" ]; then
                echo "  $_P: $(grep -c . "$BASE/.missing") stock file(s) not in the pack, e.g.:"
                head -5 "$BASE/.missing" | sed 's/^/        /'
                if [ "${SF_FORCE:-0}" != 1 ]; then
                    echo "  skip  $_P (would hide them - SF_FORCE=1 prepare to link anyway)"
                    rm -f "$BASE/.missing"
                    _NS=$((_NS + 1))
                    continue
                fi
            fi
            rm -f "$BASE/.missing"
        fi
        echo "$_P" >> "$BASE/links.txt.new"; _NL=$((_NL + 1))
    done

    # Swap the new tree in
    if [ -d "$ROOT" ]; then
        mv "$ROOT" "$BASE/root.old" || { echo "ERROR: cannot move the old tree"; rm -rf "$_NEW"; return 1; }
    fi
    if ! mv "$_NEW" "$ROOT"; then
        echo "ERROR: cannot move the new tree in place"
        [ -d "$BASE/root.old" ] && mv "$BASE/root.old" "$ROOT"
        return 1
    fi
    mv -f "$BASE/orig.txt.new" "$ORIGF"
    mv -f "$BASE/links.txt.new" "$LINKSF"
    rm -rf "$BASE/root.old"
    {
        echo "pack=$PACK"
        [ -f "$PACK" ] && echo "pack_bytes=$(( $(wc -c < "$PACK") ))"
        [ -f "$PACK2" ] && echo "pack2=$PACK2"
        echo "links=$_NL"
        echo "skipped=$_NS"
        _D=$(date 2>/dev/null); [ -n "$_D" ] && echo "date=$_D"
    } > "$PREPF"
    sync

    echo ""
    echo "Prepared: $_NL link(s), $_NS skipped. Tree: $ROOT   List: $LINKSF"
    return 0
}


# ============================================================
# STOP
# ============================================================

stop_overlay()
{
    echo ""
    echo "============================================================"
    echo "$PLAT_NAME OVERLAY STOP"
    echo "============================================================"

    mode_ok stop || return 1

    rm -f "$MARKER" "$FEATURES"
    stop_crashwatch
    stop_renderer
    stop_aaw
    stop_wcp

    # Only paths that are OUR links are removed - never a real file.
    N=0
    for P in $(all_links); do
        if is_our_link "$P"; then
            rm -f "$P" 2>/dev/null
            if [ -L "$P" ]; then
                echo "  ERROR could not remove link $P"
            else
                echo "  unlinked $P"
                N=$((N + 1))
            fi
        fi
    done

    # A RAM tree left by an older version of this script
    if [ -d "$OLD_RD/mnt" ] && [ -d "$OLD_RD/.sf" ]; then
        rm -rf "$OLD_RD/mnt" "$OLD_RD/.sf" && echo "  removed the old RAM tree $OLD_RD/mnt"
    fi

    rm -f "$STATE"

    echo ""
    echo "Links removed: $N (the prepared tree $ROOT stays)."
    echo "New starts of the services use the stock files; processes already"
    echo "running keep their files until restarted (or reboot)."
}


# ============================================================
# START: links only
# ============================================================

start_main()
{
    echo ""
    echo "============================================================"
    echo "$PLAT_NAME OVERLAY START"
    echo "============================================================"

    # swdl: nothing linked; the marker gets status=<mode> so lsd.sh
    # does not wait out its timeout
    if ! mode_ok start; then
        SF_RESULT="$MMI_MODE"
        return 0
    fi

    if [ -f "$DISABLE" ]; then
        echo "Disabled ($DISABLE exists) - nothing done."
        SF_RESULT=disabled
        return 0
    fi

    if [ -f "$STATE" ]; then
        echo "ERROR: overlay already active. Run: $0 stop"
        return 1
    fi

    : > "$LOG"

    # Not prepared yet, or a newer pack: prepare once (this boot is slower)
    if [ ! -f "$LINKSF" ] || [ ! -d "$ROOT" ]; then
        echo "No prepared tree - preparing from $PACK"
        prepare_tree || return 1
    elif { [ -f "$PACK" ] && [ "$PACK" -nt "$LINKSF" ]; } || { [ -f "$PACK2" ] && [ "$PACK2" -nt "$LINKSF" ]; }; then
        echo "A pack is newer than the prepared tree - preparing again"
        prepare_tree || return 1
    fi

    # Firmware brought a newer stock file than our copy: copy it again
    # (shell test only - no process unless something changed)
    while read _S _SRC; do
        [ -n "$_S" ] || continue
        if [ -f "$_SRC" ] && [ ! -L "$_SRC" ] && [ "$_SRC" -nt "$ROOT$_S" ]; then
            if grep -E "$MOD_TAGS" "$_SRC" >/dev/null 2>&1; then
                echo "  WARN  $_SRC is newer than the saved stock but is a wrapper - kept the old copy"
            elif cp -p "$_SRC" "$ROOT$_S.new" 2>>"$LOG" && chmod 0755 "$ROOT$_S.new" && mv -f "$ROOT$_S.new" "$ROOT$_S"; then
                echo "  stock $_SRC changed (firmware?) - saved again"
            else
                rm -f "$ROOT$_S.new"
                echo "  ERROR could not refresh $ROOT$_S from $_SRC"
            fi
        fi
    done < "$ORIGF"

    # Leftover links (state file lost) - refuse, as before
    LEFT=0
    while read P; do
        [ -L "$P" ] && { echo "ERROR: $P is already a link"; LEFT=1; }
    done < "$LINKSF"
    [ "$LEFT" = 0 ] || { echo "Run: $0 stop"; return 1; }

    # Data directories under /mnt/ota (e.g. /mnt/ota/wcp: pairing data,
    # btmac.last) must be REAL directories: made here, before the links, in
    # case they were never there (new unit) or were deleted in a clean-up.
    # After the links exist, the path manager shows such a directory even
    # when the file system has none, and a mkdir there would not create it.
    while read P; do
        case "$P" in /mnt/ota/*) mkdir -p "${P%/*}" 2>/dev/null ;; esac
    done < "$LINKSF"

    # Which parts are installed (a path of theirs in the list) and switched on
    HAVE_ALT=0; HAVE_RGI=0; HAVE_WCP=0; HAVE_AAW=0
    while read P; do
        feature_of "$P"
        case "$_FT" in altscreen) HAVE_ALT=1 ;; rgi|rgilib|hmi) HAVE_RGI=1 ;; wcp) HAVE_WCP=1 ;; aaw) HAVE_AAW=1 ;; esac
    done < "$LINKSF"
    ON_ALT=$HAVE_ALT; ON_RGI=$HAVE_RGI; ON_WCP=$HAVE_WCP; ON_AAW=$HAVE_AAW
    [ -f /mnt/ota/app/altscreen_off ] && ON_ALT=0
    [ -f /mnt/ota/app/rgi_off ] && ON_RGI=0
    [ -f /mnt/ota/app/wcp_off ] && ON_WCP=0
    [ -f /mnt/ota/app/aaw_off ] && ON_AAW=0
    _F="v3"
    [ "$ON_ALT" = 1 ] && _F="$_F altscreen"
    [ "$ON_RGI" = 1 ] && _F="$_F rgi"
    [ "$ON_WCP" = 1 ] && _F="$_F wcp"
    [ "$ON_AAW" = 1 ] && _F="$_F aaw"
    echo "$_F" > "$FEATURES"
    [ "$HAVE_ALT" = 1 ] && { [ "$ON_ALT" = 1 ] && echo "AltScreen (phone map in the cluster): on" || echo "AltScreen: off (/mnt/ota/app/altscreen_off)"; }
    [ "$HAVE_RGI" = 1 ] && { [ "$ON_RGI" = 1 ] && echo "RGI (route guidance in the cluster): on" || echo "RGI: off (/mnt/ota/app/rgi_off)"; }
    [ "$HAVE_WCP" = 1 ] && { [ "$ON_WCP" = 1 ] && echo "Wireless CarPlay: on" || echo "Wireless CarPlay: off (/mnt/ota/app/wcp_off)"; }
    if [ "$HAVE_AAW" = 1 ]; then
        if [ "$ON_AAW" = 0 ]; then echo "Wireless Android Auto: off (/mnt/ota/app/aaw_off)"
        elif [ "$ON_WCP" = 1 ]; then echo "Wireless Android Auto: on"
        else echo "Wireless Android Auto: on, but the wireless part is off/missing - no Bluetooth handshake (bench use only)"
        fi
    fi

    # The links
    : > "$STATE"
    NLINK=0
    NSKIP=0
    NOFF=0
    while read P; do
        [ -n "$P" ] || continue
        feature_of "$P"
        if { [ "$_FT" = altscreen ] && [ "$ON_ALT" = 0 ]; } ||
           { [ "$_FT" = rgi ] && [ "$ON_RGI" = 0 ]; } ||
           { [ "$_FT" = rgilib ] && [ "$ON_RGI" = 0 ] && [ "$ON_WCP" = 0 ]; } ||
           { [ "$_FT" = hmi ] && [ "$ON_RGI" = 0 ] && [ "$ON_ALT" = 0 ]; } ||
           { [ "$_FT" = wcp ] && [ "$ON_WCP" = 0 ]; } ||
           { [ "$_FT" = aaw ] && [ "$ON_AAW" = 0 ]; } ||
           { [ "$_FT" = shared ] && [ "$ON_ALT" = 0 ] && [ "$ON_RGI" = 0 ] && [ "$ON_WCP" = 0 ] && [ "$ON_AAW" = 0 ]; }; then
            NOFF=$((NOFF + 1))
            continue
        fi
        if [ "$P" = "$HMI_STARTUP" ]; then
            if [ -f /mnt/ota/app/hmi_startup_off ]; then
                _HS="switched off (/mnt/ota/app/hmi_startup_off)"
            else
                hmi_startup_make "$ROOT"            # again if the firmware's file changed
            fi
            if [ -n "$_HS" ]; then
                echo "  stock HMI startup file: $_HS"
                NOFF=$((NOFF + 1))
                continue
            fi
        fi
        if [ ! -e "$ROOT$P" ]; then
            echo "  skip  $P (not in $ROOT - run: $0 prepare)"
            NSKIP=$((NSKIP + 1))
        elif ln -sP "$ROOT$P" "$P" 2>>"$LOG"; then
            echo "$P" >> "$STATE"
            NLINK=$((NLINK + 1))
        else
            echo "  ERROR ln -sP $P failed"
            NSKIP=$((NSKIP + 1))
        fi
    done < "$LINKSF"

    _OFFT=""
    [ "$NOFF" -gt 0 ] && _OFFT=", $NOFF of a switched-off part"
    echo "  $NLINK link(s), $NSKIP skipped$_OFFT   (tree $ROOT)"

    start_renderer
    start_wcp
    start_aaw
    start_crashwatch
}


start_overlay()
{
    rm -f "$MARKER"
    _T0=${SECONDS:-}
    SF_RESULT=""

    start_main
    _RC=$?

    if [ -z "$SF_RESULT" ]; then
        if [ "$_RC" = 0 ]; then SF_RESULT=ok; else SF_RESULT=failed; fi
    fi

    if [ -n "$_T0" ] && [ -n "$SECONDS" ]; then
        _DT=$((SECONDS - _T0))
    else
        _DT="?"
    fi

    {
        echo "status=$SF_RESULT"
        echo "seconds=$_DT"
        echo "links=${NLINK:-0}"
        echo "skipped=${NSKIP:-0}"
        _D=$(date 2>/dev/null)
        [ -n "$_D" ] && echo "date=$_D"
    } > "$MARKER.tmp.$$" && mv -f "$MARKER.tmp.$$" "$MARKER"

    echo "Marker   : $MARKER (status=$SF_RESULT, ${_DT} s)"
    return $_RC
}


# ============================================================
# BOOT HOOK (install / uninstall)
#
# The stock servicemgrmibhigh is kept as servicemgrmibhigh.orig and
# replaced by a small wrapper that:
#   0. skips everything when the MMI is not in normal mode (swdl)
#   1. checks the off switch - /mnt/ota/app/.sf_disable (sticky), or an
#      sf_disable file on SD/USB, which creates /mnt/ota/app/.sf_disable
#   2. runs "AltScreen.sh start" (links in place before any service starts)
#   3. execs the stock servicemgrmibhigh.orig
# and lsd.sh gets "waitfor /tmp/AltScreenStarted 20", so the HMI
# starts only after the links are in place.
# The off-switch path is written into the hook at install time
# (STOP=...): after changing SF_DISABLE, run install again.
# Turn the mods back on:  rm /mnt/ota/app/.sf_disable  (then reboot)
# ============================================================

SVC=/mnt/app/eso/bin/servicemgrmibhigh
SVC_ORIG="$SVC.orig"
HOOK_TAG="AltScreen boot hook"
HOOK_LOG=/tmp/AltScreen_boot.log
HOOK_SCRIPT="${SF_SCRIPT:-/mnt/ota/app/AltScreen.sh}"

# Our hook, or an older runNV.sh / runQC.sh one: install rewrites those
# in place (servicemgrmibhigh.orig kept) so they call HOOK_SCRIPT.
is_hook() { grep -E "(AltScreen|run(NV|QC)) boot hook" "$1" >/dev/null 2>&1; }

# A plausible stock binary: present, not tiny, not our wrapper
is_stock_bin()
{
    [ -f "$1" ] || return 1
    is_hook "$1" && return 1
    [ $(( $(wc -c < "$1") )) -gt 65536 ]
}

write_hook()
{
    {
        echo '#!/bin/sh'
        echo "## $HOOK_TAG - written by AltScreen.sh install, removed by AltScreen.sh uninstall"
        echo "NV=$HOOK_SCRIPT"
        echo "MARKER=$MARKER"
        echo "LOG=$HOOK_LOG"
        echo "STOP=$DISABLE"
        cat <<'HOOK'
ORIG=/mnt/app/eso/bin/servicemgrmibhigh.orig

# lsd.sh waits for $MARKER: leave it on every path, so the HMI never
# sits out the whole timeout when the mods are off.
mark() { [ -f "$MARKER" ] || echo "status=$1" > "$MARKER" 2>/dev/null; }

# 0. Software download (swdl) mode: no mods, stock start only.
RUN_MODE=""
[ -r /dev/ooc/startup ] && read RUN_MODE < /dev/ooc/startup
case "$RUN_MODE" in
    normal|"") ;;
    *) mark "$RUN_MODE"; exec "$ORIG" "$@" ;;
esac

# 1. Off switches first: with one set, no mod is started.
#    $STOP is sticky - delete it to turn the mods back on.
[ -f "$STOP" ] && { mark stopped; exec "$ORIG" "$@"; }
for d in /fs/sda0 /fs/sda1 /fs/usb0 /fs/usb1 /fs/mmc0; do
    if [ -f "$d/sf_disable" ]; then
        echo stopped > "$STOP" 2>/dev/null
        sync 2>/dev/null
        mark stopped
        exec "$ORIG" "$@"
    fi
done

# 2. Mods: the links must exist before servicemgr starts the services.
if [ -f "$NV" ]; then
    /bin/sh "$NV" start > "$LOG" 2>&1
    echo "AltScreen.sh start returned $?" >> "$LOG"
fi

# 3. Stock service manager (marker only if start did not write one)
mark skipped
exec "$ORIG" "$@"
HOOK
    } > "$1"
}

# ------------------------------------------------------------
# lsd.sh: wait for the marker before the HMI starts
#   "waitfor /tmp/AltScreenStarted 20" right after the
#   "## Path setup:" / "##" comment block. Stock copy kept once
#   as lsd.sh.rgi-stock; uninstall removes just that line.
# ------------------------------------------------------------

LSD=/mnt/app/eso/hmi/lsd/lsd.sh
LSD_WAIT="${SF_LSD_WAIT:-20}"
LSD_LINE="waitfor $MARKER $LSD_WAIT"

lsd_patched() { grep -q "^waitfor $MARKER" "$LSD" 2>/dev/null; }

# stdin -> stdout with LSD_LINE after the "## Path setup:" block;
# fails (and nothing is written back) if the block is not found
lsd_add_filter()
{
    _ST=0
    while IFS= read -r _L || [ -n "$_L" ]; do
        putline "$_L"
        case "$_ST" in
            0) case "$_L" in "## Path setup:"*) _ST=1 ;; esac ;;
            1) if [ "${_L%% }" = "##" ]; then putline "$LSD_LINE"; _ST=2; fi ;;
        esac
    done
    [ "$_ST" = 2 ]
}

# stdin -> stdout without our waitfor line
lsd_del_filter()
{
    while IFS= read -r _L || [ -n "$_L" ]; do
        case "$_L" in "waitfor $MARKER"*) continue ;; esac
        putline "$_L"
    done
    return 0
}

# Rewrite $LSD through filter $1: temp file with the same mode, then mv
lsd_rewrite()
{
    cp -p "$LSD" "$LSD.new" || return 1
    if "$1" < "$LSD" > "$LSD.tmp" && cat "$LSD.tmp" > "$LSD.new" &&
       mv -f "$LSD.new" "$LSD"
    then
        _R=0
    else
        _R=1
    fi
    rm -f "$LSD.tmp" "$LSD.new"
    return $_R
}

lsd_install()
{
    [ -f "$LSD" ] || { echo "  WARN  $LSD not found - no wait added"; return 1; }
    if lsd_patched; then
        echo "  ok    $LSD already waits for $MARKER"
        return 0
    fi
    if [ ! -f "$LSD.rgi-stock" ]; then
        cp -p "$LSD" "$LSD.rgi-stock" || { echo "  ERROR backup of $LSD failed"; return 1; }
    fi
    if lsd_rewrite lsd_add_filter && lsd_patched; then
        echo "  added '$LSD_LINE' to $LSD"
    else
        echo "  ERROR no '## Path setup:' / '##' block in $LSD - left unchanged"
        return 1
    fi
}

lsd_uninstall()
{
    lsd_patched || return 0
    if lsd_rewrite lsd_del_filter && ! lsd_patched; then
        rm -f "$LSD.rgi-stock"
        echo "  removed the wait from $LSD"
    else
        echo "  ERROR could not remove the wait from $LSD"
        return 1
    fi
}

# Copy this script to $HOOK_SCRIPT, the path the boot hook runs.
# Temp file + mv: safe even when it is run from $HOOK_SCRIPT itself
# (the running shell keeps reading the old copy).
self_install()
{
    case "$0" in
        /*) _SELF="$0" ;;
        *)  _SELF="$PWD/$0" ;;
    esac
    if [ ! -f "$_SELF" ]; then
        echo "  WARN  cannot find this script ($0) - $HOOK_SCRIPT not updated"
        return 1
    fi
    if mkdir -p "${HOOK_SCRIPT%/*}" &&
       cp "$_SELF" "$HOOK_SCRIPT.new" && chmod 0755 "$HOOK_SCRIPT.new" &&
       same_file "$_SELF" "$HOOK_SCRIPT.new" && mv -f "$HOOK_SCRIPT.new" "$HOOK_SCRIPT"
    then
        echo "  copied $_SELF -> $HOOK_SCRIPT"
    else
        rm -f "$HOOK_SCRIPT.new"
        echo "  ERROR could not copy $_SELF to $HOOK_SCRIPT"
        return 1
    fi
}

install_hook()
{
    echo ""
    echo "============================================================"
    echo "INSTALL BOOT HOOK  ($SVC)"
    echo "============================================================"

    [ -f "$SVC" ] || { echo "ERROR: $SVC not found"; return 1; }

    # The tree first: unpack the pack and save the stock binaries
    _WAS_ACTIVE=0
    if [ -f "$STATE" ]; then
        echo "Overlay active - stopping it for the prepare, starting it again afterwards"
        stop_overlay
        _WAS_ACTIVE=1
    fi
    prepare_tree || { echo "ERROR: prepare failed - boot hook not changed"; [ "$_WAS_ACTIVE" = 1 ] && start_overlay; return 1; }
    [ "$_WAS_ACTIVE" = 1 ] && start_overlay

    self_install
    [ -f "$HOOK_SCRIPT" ] || echo "WARN: $HOOK_SCRIPT not found - the hook will skip start until it exists"

    if is_hook "$SVC"; then
        is_stock_bin "$SVC_ORIG" || {
            echo "ERROR: $SVC is already the hook, but $SVC_ORIG is missing or not a binary."
            echo "Restore the stock servicemgrmibhigh by hand first."
            return 1
        }
        echo "Hook already installed - rewriting the hook only, $SVC_ORIG kept."
        _SAVE=0
    else
        is_stock_bin "$SVC" || { echo "ERROR: $SVC does not look like the stock binary"; return 1; }
        [ -f "$SVC_ORIG" ] && echo "NOTE: replacing the old $SVC_ORIG (firmware updated?)"
        _SAVE=1
    fi

    mount -uw /mnt/app 2>/dev/null
    touch "$SVC.rwtest" 2>/dev/null && rm -f "$SVC.rwtest" || {
        echo "ERROR: /mnt/app is not writable"
        return 1
    }

    _OK=1

    # Each file is written next to its target and then renamed (mv),
    # so a power loss never leaves a half-written servicemgrmibhigh.
    if [ "$_SAVE" = 1 ]; then
        if cp "$SVC" "$SVC_ORIG.new" && chmod 0755 "$SVC_ORIG.new" &&
           same_file "$SVC" "$SVC_ORIG.new" && mv -f "$SVC_ORIG.new" "$SVC_ORIG"
        then
            echo "  saved $SVC -> $SVC_ORIG"
        else
            echo "  ERROR saving $SVC_ORIG - nothing changed"
            rm -f "$SVC_ORIG.new"
            _OK=0
        fi
    fi

    if [ "$_OK" = 1 ]; then
        if write_hook "$SVC.new" && chmod 0755 "$SVC.new" && is_hook "$SVC.new" &&
           mv -f "$SVC.new" "$SVC"
        then
            echo "  hook written to $SVC"
        else
            echo "  ERROR writing the hook - $SVC unchanged"
            rm -f "$SVC.new"
            _OK=0
        fi
    fi

    # Only with a working hook: the hook is what writes the marker.
    [ "$_OK" = 1 ] && lsd_install

    sync
    mount -ur /mnt/app 2>/dev/null

    [ "$_OK" = 1 ] || return 1

    # Wireless CarPlay needs the car's Wi-Fi as access point; the MMI can switch it
    # off. Ask the HMI (WCP.jar, WlanAutoOn) to switch it on once at the next start.
    # "always" in the file instead = at every start; the file is left alone if set.
    _HW=0
    while read _P; do
        feature_of "$_P"
        [ "$_FT" = wcp ] && { _HW=1; break; }
    done < "$LINKSF" 2>/dev/null
    if [ "$_HW" = 1 ] && [ ! -f /mnt/ota/app/wcp_wifi_on ]; then
        : > /mnt/ota/app/wcp_wifi_on && echo "Wi-Fi: switched on once at the next start (/mnt/ota/app/wcp_wifi_on)"
    fi

    if [ ! -f /mnt/ota/app/aa_cluster.daynight ]; then
        : > /mnt/ota/app/aa_cluster.daynight && echo "AA theme follows day/night (/mnt/ota/app/aa_cluster.daynight)"
    fi

    if [ ! -f /mnt/ota/app/wcp_keep_ipv6 ]; then
        : > /mnt/ota/app/wcp_keep_ipv6 && echo "Keep ipv6 add on WiFi (slow startup otherwise)"
    fi

    echo ""
    echo "Installed ($PLAT_NAME). Next boot runs: $HOOK_SCRIPT start   (log: $HOOK_LOG)"
    echo "Prepared tree: $ROOT (a newer pack is prepared again by start; or: $0 prepare)"
    echo "Off switch: $DISABLE (sticky), or sf_disable on SD/USB at boot"
}

uninstall_hook()
{
    echo ""
    echo "============================================================"
    echo "UNINSTALL BOOT HOOK  ($SVC)"
    echo "============================================================"

    if is_hook "$SVC" && ! is_stock_bin "$SVC_ORIG"; then
        echo "ERROR: $SVC_ORIG missing or not a binary - nothing changed."
        return 1
    fi

    mount -uw /mnt/app 2>/dev/null
    _OK=1

    # lsd.sh first: without the hook nobody writes the marker
    lsd_uninstall || _OK=0

    if is_hook "$SVC"; then
        if cp "$SVC_ORIG" "$SVC.new" && chmod 0755 "$SVC.new" &&
           same_file "$SVC_ORIG" "$SVC.new" && mv -f "$SVC.new" "$SVC"
        then
            rm -f "$SVC_ORIG"
            echo "  restored stock $SVC"
        else
            rm -f "$SVC.new"
            echo "  ERROR restoring $SVC - hook left in place"
            _OK=0
        fi
    else
        echo "  hook not installed"
    fi

    sync
    mount -ur /mnt/app 2>/dev/null
    [ "$_OK" = 1 ] && echo "Uninstalled. Reboot for a stock start. (The prepared tree $BASE stays: $0 purge)"
}


# ============================================================
# CHECK / FIREWALL
# ============================================================
#
#   AltScreen.sh check      links, files, firewall and processes, read-only
#   AltScreen.sh fixfw      allow the cluster-screen port on carplay0 in the pf
#                       files (stock allows 6030 only; the alt-screen stream
#                       uses 6031).  PERSISTENT change in $SF_FW_DIR - stock
#                       copy kept once as <file>.rgi-stock.  Reboot to load.
#   AltScreen.sh restorefw  put the stock pf files back
#
# If the unit keeps its pf files elsewhere:
#   SF_FW_DIR=/path AltScreen.sh check

FW_DIR="${SF_FW_DIR:-/mnt/system/etc}"
# pf.conf and every pf.<if>.conf (pf.ecm0, pf.mlan0, pf.ppp0, ...); files without a
# carplay0 tcp port rule are reported and left alone.
fw_files()
{
    for _FF in "$FW_DIR"/pf.conf "$FW_DIR"/pf.*.conf; do
        [ -f "$_FF" ] && echo "${_FF##*/}"
    done
}
FW_TAG="RGI fixfw"

ALT_PORT=6031
[ -f /tmp/altscreen_port ] && read ALT_PORT < /tmp/altscreen_port

N_OK=0; N_WARN=0; N_FAIL=0
ok()   { echo "  OK    $*"; N_OK=$((N_OK + 1)); }
warn() { echo "  WARN  $*"; N_WARN=$((N_WARN + 1)); }
fail() { echo "  FAIL  $*"; N_FAIL=$((N_FAIL + 1)); }

# True if port $2 is inside the "{ ... }" list of pf rule line $1
# (single ports and A:B ranges).
port_in_rule()
{
    _PR_L="$1"; _PR_P="$2"
    case "$_PR_L" in *"{"*"}"*) ;; *) return 1 ;; esac
    _PR_LIST=${_PR_L#*\{}
    _PR_LIST=${_PR_LIST%%\}*}
    _PR_IFS=$IFS
    IFS=', '
    for _PR_T in $_PR_LIST; do
        case "$_PR_T" in
            *:*) _PR_LO=${_PR_T%%:*}; _PR_HI=${_PR_T#*:}
                 if [ "$_PR_P" -ge "$_PR_LO" ] 2>/dev/null && [ "$_PR_P" -le "$_PR_HI" ] 2>/dev/null; then
                     IFS=$_PR_IFS; return 0
                 fi ;;
            *)   if [ "$_PR_T" = "$_PR_P" ]; then IFS=$_PR_IFS; return 0; fi ;;
        esac
    done
    IFS=$_PR_IFS
    return 1
}

# Write $1 plus a newline exactly as it is (no escape processing - pf
# files can end lines with "\"). printf is missing on the unit, so the
# ksh builtin "print -r" is used; printf only where print is not there.
if command -v print >/dev/null 2>&1; then
    putline() { print -r -- "$1"; }
else
    putline() { printf '%s\n' "$1"; }
fi

# The "pass in quick on carplay0 proto tcp ... port { ... }" line of file $1
fw_rule_line()
{
    grep 'carplay0' "$1" 2>/dev/null | grep 'proto tcp' | grep 'port {' | head -1
}

check_firewall()
{
    echo ""
    echo "--- firewall (carplay0, tcp port $ALT_PORT) ---"
    _ANY=0
    for _F in $(fw_files); do
        _P="$FW_DIR/$_F"
        [ -f "$_P" ] || continue
        _ANY=1
        _LINE=$(fw_rule_line "$_P")
        if [ -z "$_LINE" ]; then
            warn "$_P: no carplay0 tcp port rule found"
        elif port_in_rule "$_LINE" "$ALT_PORT"; then
            ok "$_P allows $ALT_PORT"
        else
            fail "$_P does NOT allow $ALT_PORT  ->  $0 fixfw"
        fi
        [ -f "$_P.rgi-stock" ] && echo "        (stock copy: $_P.rgi-stock)"
    done
    [ "$_ANY" = 1 ] || warn "no pf files in $FW_DIR (set SF_FW_DIR)"

    if command -v pfctl >/dev/null 2>&1; then
        _R=$(pfctl -s rules 2>/dev/null | grep carplay0 | grep -c "$ALT_PORT")
        if [ "$_R" -gt 0 ]; then
            ok "loaded pf rules mention $ALT_PORT"
        else
            warn "loaded pf rules do not mention $ALT_PORT (files fixed? -> reboot)"
        fi
    fi
}

fix_firewall()
{
    echo ""
    echo "============================================================"
    echo "pf: allow tcp $ALT_PORT on carplay0  ($FW_DIR)"
    echo "============================================================"
    mount -uw /mnt/system 2>/dev/null
    _CHANGED=0
    for _F in $(fw_files); do
        _P="$FW_DIR/$_F"
        [ -f "$_P" ] || continue
        _LINE=$(fw_rule_line "$_P")
        if [ -z "$_LINE" ]; then
            echo "  skip $_P (no carplay0 tcp port rule)"; continue
        fi
        if port_in_rule "$_LINE" "$ALT_PORT"; then
            echo "  ok   $_P already allows $ALT_PORT"; continue
        fi
        if [ ! -f "$_P.rgi-stock" ]; then
            cp -p "$_P" "$_P.rgi-stock" || { echo "  ERROR: backup of $_P failed"; return 1; }
        fi
        _TMP="$_P.rgi-new.$$"
        : > "$_TMP" || { echo "  ERROR: cannot write $_TMP"; return 1; }
        _DONE=0
        while IFS= read -r _L || [ -n "$_L" ]; do
            if [ "$_DONE" = 0 ] && [ "$_L" = "$_LINE" ]; then
                _NEXT=$((ALT_PORT - 1))
                case "$_L" in
                    *" $_NEXT, "*)          # 6030, -> 6030:6031,  (stock layout)
                        _L="${_L%%" $_NEXT, "*} $_NEXT:$ALT_PORT, ${_L#*" $_NEXT, "}" ;;
                    *)                      # anything else: append to the list
                        _H=${_L%%\}*}
                        while [ "${_H% }" != "$_H" ]; do _H=${_H% }; done
                        _L="$_H, $ALT_PORT }${_L#*\}}" ;;
                esac
                _DONE=1
            fi
            putline "$_L" >> "$_TMP"
        done < "$_P"
        if ! port_in_rule "$(fw_rule_line "$_TMP")" "$ALT_PORT"; then
            echo "  ERROR: edit of $_P did not work - left unchanged"; rm -f "$_TMP"; return 1
        fi
        # write back into the same file: keeps its owner and mode
        cat "$_TMP" > "$_P" || { echo "  ERROR: cannot write $_P"; rm -f "$_TMP"; return 1; }
        rm -f "$_TMP"
        echo "  fixed $_P"
        echo "        $(fw_rule_line "$_P")"
        _CHANGED=1
    done
    sync
    if [ "$_CHANGED" = 1 ]; then
        echo ""
        echo "Stock copies: $FW_DIR/<file>.rgi-stock.  REBOOT to load the new rules."
    fi
}

# ---- wireless CarPlay on the access point (uap0) ---------------------------
# The stock rule "block in quick on $wlan_if from any to ($wlan_if)" drops all
# traffic to the head unit on uap0 that no earlier rule passes, and the wlan_data
# anchor drops Bonjour multicast. carplay0 (the factory wireless interface) does
# not exist on QC units, so the carplay0 rules do not help there. This inserts
# the CarPlay ports for uap0 right above that block line, in every pf file that
# has it (same block and markers as runQC.sh's fix_firewall_wlan of 22 Oct, so
# an existing copy is replaced, never doubled). uap0 sources are already limited
# to the access point's own network by the stock rule before it.
WLAN_IF=uap0
CP_TCP="5000:5001, 5010, 5288, 6000:6001, 6030, 6100, 6200, 7000:7001, 7100"    # 5288: wireless Android Auto (aawd)
CP_UDP="5001, 6000:6002, 6010:6011, 6020:6021, 7010:7011, 7070:7071, 5353"
WLAN_BLOCK_LINE='block in quick on $wlan_if from any to ($wlan_if)'
RGI_WLAN_BEGIN="# >>> rgi: CarPlay on $WLAN_IF (keep above the uap0 block rule)"
RGI_WLAN_END="# <<< rgi: CarPlay on $WLAN_IF"
PFCTL=/mnt/app/armle/sbin/pfctl
CMP=/mnt/app/armle/usr/bin/cmp

file_has_line() { while IFS= read -r _x || [ -n "$_x" ]; do
                      [ "$_x" = "$2" ] && return 0; done < "$1"; return 1; }
has_queue()     { while IFS= read -r _x || [ -n "$_x" ]; do
                      case "$_x" in "queue $2 "*) return 0 ;; esac; done < "$1"; return 1; }

wlan_rules()    # $1 = pf file (queues only added if that file defines them)
{
    _QV=""; _QA=""
    has_queue "$1" video_out && has_queue "$1" video_ack && _QV=" queue(video_out, video_ack)"
    has_queue "$1" audio_out && has_queue "$1" audio_ack && _QA=" queue(audio_out, audio_ack)"
    putline "$RGI_WLAN_BEGIN"
    putline "pass in quick on $WLAN_IF proto tcp from any to ($WLAN_IF) port { $_CPT } keep state allow-opts$_QV"
    putline "pass in quick on $WLAN_IF proto udp from any to ($WLAN_IF) port { $CP_UDP } keep state allow-opts$_QA"
    putline "pass in quick on $WLAN_IF proto udp from any to { 224.0.0.251, ff02::fb } port 5353 allow-opts"
    putline "$RGI_WLAN_END"
}

fix_firewall_wlan()
{
    echo ""
    echo "============================================================"
    echo "pf: CarPlay ports on $WLAN_IF (wireless)  ($FW_DIR)"
    echo "============================================================"
    mount -uw /mnt/system 2>/dev/null
    _CPT=$CP_TCP
    port_in_rule "{ $_CPT }" "$ALT_PORT" || _CPT="$_CPT, $ALT_PORT"
    _CHANGED=0
    for _F in $(fw_files); do
        _P="$FW_DIR/$_F"
        if ! file_has_line "$_P" "$WLAN_BLOCK_LINE"; then
            echo "  skip $_P (no $WLAN_IF block rule)"; continue
        fi
        _TMP="$_P.rgi-new.$$"
        : > "$_TMP" || { echo "  ERROR: cannot write $_TMP"; return 1; }
        _SKIP=0; _INS=0
        while IFS= read -r _L || [ -n "$_L" ]; do
            case "$_L" in "# >>> rgi: CarPlay on $WLAN_IF"*) _SKIP=1; continue ;; esac   # drop the older copy
            if [ "$_SKIP" = 1 ]; then
                case "$_L" in "# <<< rgi: CarPlay on $WLAN_IF"*) _SKIP=0 ;; esac
                continue
            fi
            if [ "$_INS" = 0 ] && [ "$_L" = "$WLAN_BLOCK_LINE" ]; then
                wlan_rules "$_P" >> "$_TMP"; _INS=1
            fi
            putline "$_L" >> "$_TMP"
        done < "$_P"
        if [ "$_SKIP" = 1 ] || [ "$_INS" = 0 ]; then
            echo "  ERROR: $_P: rgi block unterminated or anchor missing - left unchanged"
            rm -f "$_TMP"; return 1
        fi
        if [ -x "$CMP" ] && "$CMP" -s "$_P" "$_TMP"; then
            echo "  ok   $_P already up to date"; rm -f "$_TMP"; continue
        fi
        if [ -x "$PFCTL" ]; then                      # parse-only check, nothing loaded
            _ERR=$("$PFCTL" -nf "$_TMP" 2>&1); _RC=$?
            if [ $_RC -ne 0 ]; then
                # pf.ppp0.conf names ppp0 (the mobile data link), which only exists
                # while it is up: pfctl then fails on it with "SIOCGIFMTU: No such
                # device" whatever we add. If the unchanged file fails the very same
                # way, the error is not ours - the file is written anyway.
                _ERR0=$("$PFCTL" -nf "$_P" 2>&1); _RC0=$?
                if [ $_RC0 -ne 0 ] && [ "$_ERR0" = "$_ERR" ]; then
                    echo "  note $_P cannot be fully checked now - the unchanged file fails the same way ($_ERR)"
                else
                    echo "  ERROR: pfctl rejects new $_P - left unchanged"; echo "$_ERR"
                    rm -f "$_TMP"; continue
                fi
            fi
        fi
        if [ ! -f "$_P.rgi-stock" ]; then
            cp -p "$_P" "$_P.rgi-stock" || { echo "  ERROR: backup of $_P failed"; rm -f "$_TMP"; continue; }
        fi
        cat "$_TMP" > "$_P" || { echo "  ERROR: cannot write $_P"; rm -f "$_TMP"; continue; }
        rm -f "$_TMP"
        echo "  fixed $_P"
        _CHANGED=1
    done
    sync
    [ "$_CHANGED" = 1 ] && { echo ""; echo "Stock copies: <file>.rgi-stock.  REBOOT to load the new rules."; }
    return 0
}

check_firewall_wlan()
{
    echo ""
    echo "--- firewall ($WLAN_IF, wireless CarPlay) ---"
    for _F in $(fw_files); do
        _P="$FW_DIR/$_F"
        file_has_line "$_P" "$WLAN_BLOCK_LINE" || continue
        if grep -q "^# >>> rgi: CarPlay on $WLAN_IF" "$_P" 2>/dev/null; then
            ok "$_P has the $WLAN_IF CarPlay block"
            grep "port {.*5288" "$_P" >/dev/null 2>&1 || \
                warn "$_P: the $WLAN_IF block has no tcp 5288 (wireless Android Auto)  ->  $0 fixfw, reboot"
        else
            fail "$_P has no $WLAN_IF CarPlay block  ->  $0 fixfw"
        fi
    done
    if command -v pfctl >/dev/null 2>&1 || [ -x "$PFCTL" ]; then
        _R=$("$PFCTL" -s rules 2>/dev/null | grep "on $WLAN_IF" | grep -c "5000")
        if [ "$_R" -gt 0 ]; then
            ok "loaded pf rules pass the CarPlay ports on $WLAN_IF"
        else
            warn "loaded pf rules do not pass port 5000 on $WLAN_IF (files fixed? -> reboot)"
        fi
    fi
}

restore_firewall()
{
    echo ""
    echo "pf: restoring stock files in $FW_DIR"
    mount -uw /mnt/system 2>/dev/null
    for _F in $(fw_files); do
        _P="$FW_DIR/$_F"
        if [ -f "$_P.rgi-stock" ]; then
            cat "$_P.rgi-stock" > "$_P" && rm -f "$_P.rgi-stock" && echo "  restored $_P"
        fi
    done
    sync
    echo "REBOOT to load the stock rules."
}

# ============================================================
# USB: no MTP driver for Android phones   (fixusb / restoreusb)
# ============================================================
#
# At cold boot an Android phone can enumerate twice (USB-0.4 errno 19,
# then USB-0.5). io-fs-media (MTP) then cannot open a session, gives up
# after ~30 s and the phone is reset - the head unit cannot reach it
# until it re-enumerates by itself (15-70 s later). Android Auto only
# starts after the HMI (~01:07), so start_aoa hits the dead device
# ("No such device") and fails once or twice. Plugged in later it works.
#
# fixusb inserts a block right after "custom = function(obj)" in
# usblauncher.lua (the function that builds the MTP driver command for
# every MTP device): with $USB_MARK present, phones with Google's vendor
# id 0x18d1 get no MTP driver (an echo, the no-op the stock rules use);
# every other device keeps the stock command. Each call logs its decision
# to /tmp/mtp_custom.log. PERSISTENT change on /mnt/system (flash), read
# by usblauncher only at boot; stock copy kept as $USB_ORIG
# (from the unpatched file, or - if the file already holds a block -
# derived by cutting the block out). rm $USB_MARK = stock MTP behaviour.
# restoreusb cuts the block out again (also a hand-installed v1/v2 block).
#
# The Lua block checks the fixed path /etc/mtp_skip_android (and
# /mnt/app/mtp_skip_android); SF_USBL / SF_USB_MARK / SF_USB_ORIG are
# for tests only.

USBL="${SF_USBL:-/etc/usblauncher.lua}"
USB_MARK="${SF_USB_MARK:-/etc/mtp_skip_android}"
USB_ORIG="${SF_USB_ORIG:-/mnt/system/etc/usblauncher.lua.orig}"
USB_ANCHOR='custom = function(obj)'
USB_BEGIN='-- >>> AltScreen.sh fixusb'
USB_END='-- <<< AltScreen.sh fixusb'

usb_patched() { grep -q 'mtp_skip_android' "$USBL" 2>/dev/null; }

# The Lua block inserted after $USB_ANCHOR (tested with Lua 5.2, which
# usblauncher embeds: skip only for 0x18d1 + marker; a missing or odd
# vendor-id field can only lead to the stock command).
usb_block()
{
    cat <<'LUA'
       -- >>> AltScreen.sh fixusb: no MTP driver for Android phones (CarPlay_On_Dash, 21.10.2026)
       -- No MTP driver for phones with Google's vendor id 0x18d1 while /etc/mtp_skip_android
       -- (or /mnt/app/mtp_skip_android) exists. At cold boot such a phone can enumerate twice;
       -- io-fs-media then fails the MTP session, the phone is reset and stays unreachable until
       -- it re-enumerates, so Android Auto (start_aoa) fails. Decision log: /tmp/mtp_custom.log.
       -- "AltScreen.sh restoreusb" removes this block; rm the marker = stock behaviour.
       local mod_vid, mod_pid, mod_devno = nil, nil, nil
       pcall(function() mod_vid = obj.vendor_id or obj.vid end)
       pcall(function() mod_pid = obj.product_id or obj.did end)
       pcall(function() mod_devno = obj.devno end)
       if type(mod_vid) == "string" then
           mod_vid = tonumber(mod_vid) or tonumber(mod_vid, 16)
       end
       local mod_etc = posix.stat("/etc/mtp_skip_android") ~= nil
       local mod_app = posix.stat("/mnt/app/mtp_skip_android") ~= nil
       local mod_skip = (mod_vid == 0x18d1) and (mod_etc or mod_app)
       pcall(function()
           local f = io.open("/tmp/mtp_custom.log", "a")
           if f then
               f:write(string.format("custom: obj=%s vid=%s pid=%s devno=%s etc_marker=%s app_marker=%s skip=%s\n",
                   type(obj), tostring(mod_vid), tostring(mod_pid), tostring(mod_devno),
                   tostring(mod_etc), tostring(mod_app), tostring(mod_skip)))
               f:close()
           end
       end)
       if mod_skip then
           return 'echo "[usblauncher.lua] MTP skipped for Android phone (mtp_skip_android)"'
       end
       -- <<< AltScreen.sh fixusb
LUA
}

# stdin -> stdout with usb_block after the first $USB_ANCHOR line;
# fails if the anchor is not found
usb_add_filter()
{
    _ST=0
    while IFS= read -r _L || [ -n "$_L" ]; do
        putline "$_L"
        if [ "$_ST" = 0 ]; then
            case "$_L" in "$USB_ANCHOR"*) usb_block; _ST=1 ;; esac
        fi
    done
    [ "$_ST" = 1 ]
}

# stdin -> stdout without our block: the tagged one (fixusb) or a
# hand-installed v1/v2 block (first line mentions CarPlay_On_Dash, ends
# with the "end" after the "MTP skipped" return)
usb_del_filter()
{
    _ST=0
    while IFS= read -r _L || [ -n "$_L" ]; do
        case "$_ST" in
            0) case "$_L" in
                   *"$USB_BEGIN"*)      _ST=1; continue ;;
                   *CarPlay_On_Dash*)   _ST=2; continue ;;
               esac ;;
            1) case "$_L" in *"$USB_END"*) _ST=0 ;; esac
               continue ;;
            2) case "$_L" in *"MTP skipped for Android phone"*) _ST=3 ;; esac
               continue ;;
            3) _ST=0
               continue ;;
        esac
        putline "$_L"
    done
    [ "$_ST" = 0 ]
}

usb_check_added()   { grep -q -e "$USB_END" "$1" && grep -q 'mtp_skip_android' "$1" && grep -q "^$USB_ANCHOR" "$1"; }
usb_check_removed() { ! grep -q 'mtp_skip_android' "$1" && grep -q "^$USB_ANCHOR" "$1"; }

# Rewrite $USBL through filter $1, check the result with $2 before it
# replaces the file: temp copy with the stock mode, then mv (atomic -
# a half-written usblauncher.lua would stop every USB device)
usb_rewrite()
{
    _R=1
    if "$1" < "$USBL" > "$USBL.tmp" && [ -s "$USBL.tmp" ] && "$2" "$USBL.tmp" &&
       cp -p "$USBL" "$USBL.new" && cat "$USBL.tmp" > "$USBL.new" &&
       same_file "$USBL.tmp" "$USBL.new" && mv -f "$USBL.new" "$USBL"
    then
        _R=0
    fi
    rm -f "$USBL.tmp" "$USBL.new"
    return $_R
}

# Stock copy $USB_ORIG from the unpatched $USBL (temp + mv, checked)
usb_orig_save()
{
    if cp -p "$USBL" "$USB_ORIG.new" && same_file "$USBL" "$USB_ORIG.new" &&
       mv -f "$USB_ORIG.new" "$USB_ORIG"
    then
        echo "  stock copy $USB_ORIG"
        rm -f "$USBL.rgi-stock"      # name used by the first fixusb version
        return 0
    fi
    rm -f "$USB_ORIG.new"
    echo "  ERROR: stock copy $USB_ORIG failed - left unchanged"
    return 1
}

# Stock copy $USB_ORIG from a patched $USBL: the block cut out
usb_orig_derive()
{
    if usb_del_filter < "$USBL" > "$USB_ORIG.new" && [ -s "$USB_ORIG.new" ] &&
       usb_check_removed "$USB_ORIG.new" && mv -f "$USB_ORIG.new" "$USB_ORIG"
    then
        echo "  stock copy $USB_ORIG (block cut out of $USBL)"
        rm -f "$USBL.rgi-stock"
        return 0
    fi
    rm -f "$USB_ORIG.new"
    echo "  WARN  could not derive a stock copy - restoreusb cuts the block out instead"
    return 1
}

fix_usb()
{
    echo ""
    echo "============================================================"
    echo "USB: no MTP driver for Android phones (0x18d1)  ($USBL)"
    echo "============================================================"
    [ -f "$USBL" ] || { echo "  skip: $USBL not found"; return 0; }
    mount -uw /mnt/system 2>/dev/null
    if usb_patched; then
        echo "  ok   $USBL already has the MTP skip"
        # no stock copy yet (e.g. a hand-installed block): cut the block out
        [ -f "$USB_ORIG" ] || usb_orig_derive
    elif ! grep -q "^$USB_ANCHOR" "$USBL"; then
        echo "  skip: no '$USB_ANCHOR' in $USBL (other firmware?) - left unchanged"
        return 0
    else
        # the unpatched file is the current stock: refresh the copy
        usb_orig_save || return 1
        if usb_rewrite usb_add_filter usb_check_added && usb_patched; then
            echo "  patched $USBL (block after '$USB_ANCHOR')"
        else
            echo "  ERROR: edit of $USBL did not work - left unchanged"
            return 1
        fi
    fi
    if touch "$USB_MARK" 2>/dev/null; then
        echo "  marker $USB_MARK set"
    else
        echo "  WARN  could not create $USB_MARK - the MTP skip stays off"
    fi
    sync
    echo "  REBOOT: usblauncher reads $USBL only at boot (decision log /tmp/mtp_custom.log)."
    echo "  Off without uninstall: rm $USB_MARK"
}

restore_usb()
{
    echo ""
    echo "USB: removing the MTP skip from $USBL"
    mount -uw /mnt/system 2>/dev/null
    # marker first: without it the block does nothing, whatever happens next
    rm -f "$USB_MARK"
    if [ -f /mnt/app/mtp_skip_android ]; then
        mount -uw /mnt/app 2>/dev/null
        rm -f /mnt/app/mtp_skip_android
        mount -ur /mnt/app 2>/dev/null
    fi
    _UO="$USB_ORIG"
    [ -f "$_UO" ] || _UO="$USBL.rgi-stock"     # name used by the first fixusb version
    if [ ! -f "$USBL" ]; then
        echo "  skip: $USBL not found"
    elif ! usb_patched; then
        echo "  ok   $USBL has no MTP skip"
        rm -f "$USB_ORIG" "$USBL.rgi-stock"
    elif usb_rewrite usb_del_filter usb_check_removed; then
        echo "  removed the MTP skip from $USBL"
        rm -f "$USB_ORIG" "$USBL.rgi-stock"
    elif [ -f "$_UO" ] && ! grep -q 'mtp_skip_android' "$_UO" &&
         cp -p "$_UO" "$USBL.new" && same_file "$_UO" "$USBL.new" &&
         mv -f "$USBL.new" "$USBL"
    then
        rm -f "$USB_ORIG" "$USBL.rgi-stock"
        echo "  restored $USBL from $_UO"
    else
        rm -f "$USBL.new"
        echo "  ERROR: could not remove the block - $USBL unchanged (marker removed: stock MTP behaviour)"
        sync
        return 1
    fi
    sync
    echo "  REBOOT for the stock usblauncher.lua."
}

# ============================================================
# Wi-Fi driver: patched Marvell 88W8787 driver   (patchwifi / restorewifi)
# ============================================================
#
# io-pkt loads $WIFIDRVO at boot (startup.sh start_wlan: mount -Tio-pkt
# /armle/lib/dll/devnp-mrvl_wlan-sdiorm.so; /armle is /mnt/app/armle).
# patchwifi:
#   1. saves the stock driver ONCE as $WIFIDRVS. A second install never copies
#      over it: the live file may already be the patched one. (A stock copy
#      wifidrv.sh made, <driver>.carplay-stock, is used if the live file is patched.)
#   2. puts the patched driver from the pack ($WIFIDRVP, mnt/ota/wcp/drv/ in the
#      pack) over $WIFIDRVO: copied next to it, checked, then renamed (mv -f).
#      Never written in place: io-pkt has the running driver mapped; the rename
#      leaves that copy alone, the new file is loaded at the next boot.
# Only for a known firmware: the patched driver must be in WIFI_KNOWN, and the
# stock driver and the running io-pkt must be the ones it was built for. Another
# firmware (a 3638 driver in the pack on a 5092 unit) is skipped, nothing changed.
# restorewifi: the stock copy back over $WIFIDRVO (same way), then the copy is
# removed. A driver that is neither stock nor a known patched one (firmware
# update?) is left alone. PERSISTENT (flash), active after a REBOOT.

WIFIDRVO=/mnt/app/armle/lib/dll/devnp-mrvl_wlan-sdiorm.so          # the driver io-pkt loads
WIFIDRVS=/mnt/app/armle/lib/dll/stock/devnp-mrvl_wlan-sdiorm.so    # saved stock driver
WIFIDRVP=/mnt/ota/wcp/drv/devnp-mrvl_wlan-sdiorm.so                # patched driver (pack)
WIFI_IOPKT=/sbin/io-pkt-v6-hc                                      # the io-pkt that runs

# Known drivers (POSIX cksum "crc size", as cksum prints them on the unit):
#   <name> <stock driver> <patched driver> <io-pkt it needs>
# Add a line per firmware / build; several patched builds may share one stock.
WIFI_KNOWN="
3638-rx   662303204 421788   836483370 483956   550038311 1293819
3638-rx3  662303204 421788   2413324127 421788  550038311 1293819
5092-full 3675690355 418361  521950619 484052   3318228940 1299484
"

# wifi_sum <file>: "crc size" (empty if no file). Only the first two fields:
# QNX cksum prints "crc size STDIN" for standard input.
wifi_sum()
{
    [ -f "$1" ] || return 0
    set -- $(cksum < "$1" 2>/dev/null)
    [ -n "$2" ] && echo "$1 $2"
}

# wifi_row <s|p> "<crc> <size>": the WIFI_KNOWN line whose stock (s) or patched (p)
# driver it is. Sets _WR_N (name), _WR_S (stock), _WR_P (patched), _WR_I (io-pkt).
# No case statement in here: it runs inside $( ) (see control_lines).
wifi_row()
{
    _WR_N=; _WR_S=; _WR_P=; _WR_I=
    _WR=$(echo "$WIFI_KNOWN" | while read _a _b _c _d _e _f _g; do
              [ -n "$_a" ] || continue
              if [ "$1" = s ] && [ "$_b $_c" = "$2" ]; then echo "$_a $_b $_c $_d $_e $_f $_g"; fi
              if [ "$1" = p ] && [ "$_d $_e" = "$2" ]; then echo "$_a $_b $_c $_d $_e $_f $_g"; fi
          done | head -1)
    [ -n "$_WR" ] || return 1
    set -- $_WR
    _WR_N=$1; _WR_S="$2 $3"; _WR_P="$4 $5"; _WR_I="$6 $7"
    return 0
}

# wifi_put <source> <target>: copy next to the target, check, rename over it
wifi_put()
{
    rm -f "$2.new"
    if cp -f "$1" "$2.new" && chmod 0755 "$2.new" && same_file "$1" "$2.new" &&
       mv -f "$2.new" "$2" && same_file "$1" "$2"
    then
        return 0
    fi
    rm -f "$2.new"
    return 1
}

wifi_rw()
{
    mount -uw /mnt/app 2>/dev/null
    touch "$WIFIDRVO.rwtest" 2>/dev/null && rm -f "$WIFIDRVO.rwtest" && return 0
    echo "  ERROR: /mnt/app is not writable - nothing changed"
    return 1
}

wifi_ro() { sync; mount -ur /mnt/app 2>/dev/null; }

patch_wifi()
{
    echo ""
    echo "============================================================"
    echo "Wi-Fi driver: patched driver  ($WIFIDRVO)"
    echo "============================================================"
    _WSRC="$ROOT$WIFIDRVP"                     # prepared tree first (no link needed)
    [ -f "$_WSRC" ] || _WSRC="$WIFIDRVP"
    [ -f "$_WSRC" ] || { echo "  skip: no patched driver in the pack ($WIFIDRVP)"; return 0; }
    [ -f "$WIFIDRVO" ] || { echo "  skip: $WIFIDRVO not found"; return 0; }

    _WPS=$(wifi_sum "$_WSRC")
    if ! wifi_row p "$_WPS"; then
        echo "  ERROR: $_WSRC ($_WPS) is not a known patched driver (WIFI_KNOWN) - nothing changed"
        return 1
    fi
    _WN=$_WR_N; _WSTOCK=$_WR_S; _WIO=$_WR_I
    _WIS=$(wifi_sum "$WIFI_IOPKT")
    if [ "$_WIS" != "$_WIO" ]; then
        echo "  skip: the pack's driver is $_WN; $WIFI_IOPKT ($_WIS) is not its io-pkt ($_WIO)"
        echo "        - other firmware: the stock driver stays"
        return 0
    fi
    _WLS=$(wifi_sum "$WIFIDRVO")

    # the live file: stock, already this patched driver, or another patched
    # build for the same stock (replaced) - anything else is left alone
    _WLIVE=
    if [ "$_WLS" = "$_WPS" ] && same_file "$_WSRC" "$WIFIDRVO"; then _WLIVE=patched
    elif [ "$_WLS" = "$_WSTOCK" ]; then _WLIVE=stock
    elif wifi_row p "$_WLS" && [ "$_WR_S" = "$_WSTOCK" ]; then _WLIVE="other ($_WR_N)"
    else
        echo "  ERROR: $WIFIDRVO ($_WLS) is neither the stock driver of $_WN ($_WSTOCK)"
        echo "         nor a known patched one (firmware update?) - left unchanged"
        return 1
    fi

    # 1. stock copy - once, never overwritten
    _WSAVE=
    if [ -f "$WIFIDRVS" ]; then
        if [ "$(wifi_sum "$WIFIDRVS")" != "$_WSTOCK" ]; then
            echo "  ERROR: $WIFIDRVS is not the stock driver of $_WN ($_WSTOCK) - nothing changed"
            return 1
        fi
        echo "  ok    stock copy $WIFIDRVS (kept)"
    elif [ "$_WLIVE" = stock ]; then
        _WSAVE="$WIFIDRVO"
    elif [ "$(wifi_sum "$WIFIDRVO.carplay-stock")" = "$_WSTOCK" ]; then
        _WSAVE="$WIFIDRVO.carplay-stock"        # saved by wifidrv.sh
    else
        echo "  ERROR: $WIFIDRVO is already patched and there is no stock copy"
        echo "         ($WIFIDRVS) to restore it from - nothing changed"
        return 1
    fi

    if [ "$_WLIVE" = patched ] && [ -z "$_WSAVE" ]; then
        echo "  ok    $WIFIDRVO is already the patched driver ($_WN)"
        return 0
    fi

    wifi_rw || return 1
    if [ -n "$_WSAVE" ]; then
        mkdir -p "${WIFIDRVS%/*}" 2>/dev/null
        if wifi_put "$_WSAVE" "$WIFIDRVS"; then
            echo "  saved $_WSAVE -> $WIFIDRVS"
        else
            echo "  ERROR: could not save the stock driver to $WIFIDRVS - nothing changed"
            wifi_ro; return 1
        fi
    fi
    if [ "$_WLIVE" = patched ]; then
        echo "  ok    $WIFIDRVO is already the patched driver ($_WN)"
    elif wifi_put "$_WSRC" "$WIFIDRVO"; then
        echo "  patched $WIFIDRVO ($_WN, was $_WLIVE)"
        echo "  REBOOT: io-pkt loads the driver only at boot."
    else
        echo "  ERROR: could not write $WIFIDRVO - it is unchanged"
        wifi_ro; return 1
    fi
    wifi_ro
    return 0
}

restore_wifi()
{
    echo ""
    echo "============================================================"
    echo "Wi-Fi driver: stock driver back  ($WIFIDRVO)"
    echo "============================================================"
    [ -f "$WIFIDRVO" ] || { echo "  skip: $WIFIDRVO not found"; return 0; }
    _WLS=$(wifi_sum "$WIFIDRVO")
    if [ ! -f "$WIFIDRVS" ]; then
        if wifi_row p "$_WLS"; then
            echo "  ERROR: $WIFIDRVO is patched ($_WR_N) but there is no stock copy $WIFIDRVS - left unchanged"
            return 1
        fi
        echo "  ok    no stock copy: the driver was not patched by this script"
        return 0
    fi
    _WSS=$(wifi_sum "$WIFIDRVS")
    if wifi_row p "$_WSS"; then
        echo "  ERROR: the stock copy $WIFIDRVS is a patched driver ($_WR_N) - no stock to restore, left unchanged"
        return 1
    fi
    if [ "$_WLS" = "$_WSS" ] && same_file "$WIFIDRVS" "$WIFIDRVO"; then
        echo "  ok    $WIFIDRVO is the stock driver"
        wifi_rw || return 1
        rm -f "$WIFIDRVS" && rmdir "${WIFIDRVS%/*}" 2>/dev/null
        echo "  removed the stock copy $WIFIDRVS"
        wifi_ro
        return 0
    fi
    if ! wifi_row p "$_WLS"; then
        echo "  WARN  $WIFIDRVO ($_WLS) is not a known patched driver (firmware update?)"
        echo "        - left as it is, stock copy $WIFIDRVS kept"
        return 1
    fi
    if [ "$_WSS" != "$_WR_S" ]; then
        echo "  ERROR: $WIFIDRVS ($_WSS) is not the stock driver of $_WR_N ($_WR_S) - left unchanged"
        return 1
    fi
    wifi_rw || return 1
    if wifi_put "$WIFIDRVS" "$WIFIDRVO"; then
        echo "  restored stock $WIFIDRVO (was $_WR_N)"
        rm -f "$WIFIDRVS" && rmdir "${WIFIDRVS%/*}" 2>/dev/null
        echo "  removed the stock copy $WIFIDRVS"
        echo "  REBOOT: io-pkt loads the driver only at boot."
    else
        echo "  ERROR: could not write $WIFIDRVO - it is unchanged (stock copy kept)"
        wifi_ro; return 1
    fi
    wifi_ro
    return 0
}

# check: which driver is on flash, the stock copy, loaded by io-pkt
check_wifi()
{
    echo ""
    echo "--- Wi-Fi driver ($WIFIDRVO) ---"
    if [ ! -f "$WIFIDRVO" ]; then fail "$WIFIDRVO missing"; return; fi
    _WLS=$(wifi_sum "$WIFIDRVO")
    if wifi_row p "$_WLS"; then
        ok "patched driver ($_WR_N, cksum $_WLS)"
        if [ ! -f "$WIFIDRVS" ]; then
            fail "no stock copy $WIFIDRVS - restorewifi cannot put stock back"
        elif [ "$(wifi_sum "$WIFIDRVS")" = "$_WR_S" ]; then
            ok "stock copy $WIFIDRVS"
        else
            fail "$WIFIDRVS is not the stock driver of $_WR_N"
        fi
        [ "$(wifi_sum "$WIFI_IOPKT")" = "$_WR_I" ] || \
            warn "$WIFI_IOPKT is not the io-pkt of $_WR_N - the driver runs its fixes only (runtime part off)"
    elif wifi_row s "$_WLS"; then
        echo "  -     stock driver (${_WR_N%%-*} firmware, cksum $_WLS)"
        if [ -f "$ROOT$WIFIDRVP" ] || [ -f "$WIFIDRVP" ]; then
            echo "        the pack has a patched driver: $0 patchwifi (then reboot)"
        fi
    else
        warn "unknown driver (cksum $_WLS) - not in WIFI_KNOWN"
    fi
    # loaded: listed in io-pkt's memory map, or its interfaces exist (uap0, mlan0)
    _WIP=$(pids_of io-pkt-v6-hc)
    if [ -n "$_WIP" ] && pids_have_lib "$_WIP" 'mrvl_wlan'; then
        ok "io-pkt (pid $_WIP) has the Wi-Fi driver loaded (a file changed since boot is used after a reboot)"
    elif ifconfig uap0 >/dev/null 2>&1 || ifconfig mlan0 >/dev/null 2>&1; then
        ok "Wi-Fi driver attached in io-pkt (uap0/mlan0 present; a file changed since boot is used after a reboot)"
    else
        warn "no uap0/mlan0 - the Wi-Fi driver is not attached in io-pkt"
    fi
}

# --- links / files / processes --------------------------------

# PIDs of processes whose arguments contain $1
pids_of()
{
    pidin ar 2>/dev/null | grep -v grep | grep -F "$1" |
    while read _P _A; do echo "$_P"; done
}

# Number of mapped objects matching $2 over the PIDs in $1
pids_lib_count()
{
    _PLC=0
    for _P in $1; do
        _PLC=$((_PLC + $(pidin -p "$_P" mem 2>/dev/null | grep -cE "$2")))
    done
    echo "$_PLC"
}

# True if any PID in $1 has a mapped object matching $2 (extended regex)
pids_have_lib()
{
    for _P in $1; do
        pidin -p "$_P" mem 2>/dev/null | grep -E "$2" >/dev/null && return 0
    done
    return 1
}

# $1 = live path, $2 = text: served from the RAM copy or from flash
check_file()
{
    if [ -f "$1" ]; then
        if [ -f "$STATE" ] && [ -f "$RD$1" ]; then ok "$2  ($1, overlay)"
        else ok "$2  ($1, flash)"; fi
    else
        fail "$2 missing  ($1)"
    fi
}

size_of() { wc -c < "$1" 2>/dev/null | (read n; echo $((n + 0))); }

# Known files (POSIX cksum "crc size name"). Add lines from the unit:
#   cksum /mnt/app/eso/lib/libairplay.so  ->  <crc> <size> libairplay-3346-STOCK
# "-STOCK" = ok, "-patched(<lib>)" = fail. A file not listed here is
# still caught by the proxy-name test in check_stock.
KNOWN_SUMS="
1109648048 1389617 gal-3638-patched(libaaproxy.so)
4149625390 1389617 gal-3638-patched(libsdisproxy.so)
2320472471 1405891 gal-5092-patched(libsdisproxy.so)
3670834165 1389617 gal-3638-STOCK
2839327272 1405891 gal-5092-STOCK
3223483532 753372 libairplay-3638-patched(libcpproxy.so)
443997927 753372 libairplay-3638-patched(libirc_mmx_svc.so)
1717114119 763420 libairplay-5092-patched(libirc_mmx_svc.so)
2295309441 753372 libairplay-3638-STOCK
3791488696 763420 libairplay-5092-STOCK
"

# $1 = live path, $2 = label, $3 = ERE of proxy libs a patched file names.
# With the preload wrappers the hooked files must be STOCK: a patched gal
# or libairplay (DT_NEEDED on a proxy) would load the proxy a second time.
check_stock()
{
    _CS_F="$1"; _CS_N="$2"; _CS_RE="$3"
    if [ ! -f "$_CS_F" ]; then fail "$_CS_N missing  ($_CS_F)"; return; fi
    if grep -E "$_CS_RE" "$_CS_F" >/dev/null 2>&1; then
        fail "$_CS_N is PATCHED (names $_CS_RE) - with the preload the proxy would load twice"
        return
    fi
    if ! command -v cksum >/dev/null 2>&1; then
        ok "$_CS_N names no proxy lib (no cksum on this unit)"; return
    fi
    set -- $(cksum "$_CS_F" 2>/dev/null)
    _CS_ID=$(echo "$KNOWN_SUMS" | grep "^$1 $2 " | while read a b c; do echo "$c"; done | tail -1)
    case "$_CS_ID" in
        *STOCK*)   ok "$_CS_N is stock ($_CS_ID)" ;;
        *"("*")"*) fail "$_CS_N is PATCHED ($_CS_ID) - with the preload the proxy would load twice" ;;
        *)         ok "$_CS_N names no proxy lib (cksum $1 $2 - add to KNOWN_SUMS as STOCK)" ;;
    esac
}

check_setup()
{
    echo ""
    echo "============================================================"
    echo "$PLAT_NAME CHECK   pack $PACK"
    echo "============================================================"

    echo ""
    echo "--- MMI mode ---"
    _MM=$(run_mode)
    case "$_MM" in
        normal) ok "MMI mode: normal" ;;
        "")     warn "$OOC_STARTUP not readable - mode unknown (start/stop assume normal)" ;;
        *)      warn "MMI mode: $_MM - start/stop do nothing until a normal boot" ;;
    esac

    echo ""
    echo "--- parts ---"
    _HA=0; _HR=0; _HW=0
    if [ -f "$LINKSF" ]; then
        while read _P; do
            feature_of "$_P"
            case "$_FT" in altscreen) _HA=1 ;; rgi|rgilib|hmi) _HR=1 ;; wcp) _HW=1 ;; esac
        done < "$LINKSF"
    fi
    _FNOW=$(cat "$FEATURES" 2>/dev/null)
    for _PT in altscreen rgi wcp; do
        if [ "$_PT" = altscreen ]; then _N="AltScreen (phone map in the cluster)"; _H=$_HA; _PK="$PACK"
        elif [ "$_PT" = rgi ]; then _N="RGI (route guidance in the cluster)"; _H=$_HR; _PK="$PACK or $PACK2"
        else _N="wireless CarPlay"; _H=$_HW; _PK="$PACK2"; fi
        if [ "$_H" = 0 ]; then
            echo "  -     $_N: not installed (in $_PK)"
        elif [ -f "/mnt/ota/app/${_PT}_off" ]; then
            echo "  off   $_N: installed, switched off (/mnt/ota/app/${_PT}_off)"
        else
            case " $_FNOW " in
                *" $_PT "*) ok "$_N: on" ;;
                *)          warn "$_N: installed - active from the next start" ;;
            esac
        fi
    done

    if [ -L "$HMI_STARTUP" ]; then
        if hmi_startup_stock "$ROOT" /tmp/.sf_hmi_stock.json &&
           [ "$(cat "$ROOT$HMI_STARTUP.src" 2>/dev/null)" = "$(cksum < /tmp/.sf_hmi_stock.json)" ]; then
            ok "HMI startup file: ours, made from this firmware's lsd.jxe (no 20 s wait with CarPlay last)"
        else
            warn "HMI startup file: does not match this firmware's lsd.jxe - the next start makes it again"
        fi
        rm -f /tmp/.sf_hmi_stock.json
    elif [ -f /mnt/ota/app/hmi_startup_off ]; then
        echo "  off   HMI startup file: stock (/mnt/ota/app/hmi_startup_off)"
    elif [ -f "$HMI_JXE" ]; then
        echo "  -     HMI startup file: stock (not made - see the start log)"
    fi

    echo ""
    echo "--- prepared tree ---"
    if [ -f "$PACK" ]; then ok "pack $PACK"; elif [ -f "$PACK2" ]; then ok "only the wireless pack ($PACK2)"; else warn "no pack in /mnt/ota/app (the prepared tree still works)"; fi
    if [ -f "$LINKSF" ] && [ -d "$ROOT" ]; then
        ok "tree $ROOT ($(grep -c . "$LINKSF") paths in $LINKSF)"
        [ -f "$PREPF" ] && sed -n 's/^date=/        prepared: /p' "$PREPF"
        if [ -f "$PACK" ] && [ "$PACK" -nt "$LINKSF" ]; then
            warn "pack is newer than the prepared tree - the next start prepares again (or: $0 prepare)"
        fi
        if [ -f "$PACK2" ] && [ -f "$PACK" ]; then
            ok "second pack $PACK2"
            [ "$PACK2" -nt "$LINKSF" ] && warn "$PACK2 is newer than the prepared tree - the next start prepares again"
        fi
    else
        warn "not prepared - the next start prepares (or: $0 prepare / install)"
    fi
    if [ -f "$ORIGF" ]; then
        while read _S _SRC; do
            [ -n "$_S" ] || continue
            if [ ! -f "$ROOT$_S" ]; then
                fail "stock copy $ROOT$_S missing - run: $0 prepare"
            elif [ -f "$_SRC" ] && [ ! -L "$_SRC" ] && [ "$_SRC" -nt "$ROOT$_S" ]; then
                warn "stock $_SRC newer than its copy (firmware?) - the next start saves it again"
            else
                ok "stock copy ${_S##*/} (from $_SRC)"
            fi
        done < "$ORIGF"
    fi

    echo ""
    echo "--- links ---"
    [ -f "$DISABLE" ] && warn "disabled by $DISABLE"

    if [ -f "$STATE" ]; then
        ok "overlay active ($(grep -c . "$STATE") links)"
        for P in $(cat "$LINKSF" 2>/dev/null); do
            if is_our_link "$P"; then
                ok "$P"
            elif grep -qFx "$P" "$STATE"; then
                fail "$P was linked at start but is not now"
            else
                warn "$P not linked (skipped at start - see $HOOK_LOG / $LOG)"
            fi
        done
    else
        warn "overlay not active (no state file) - run: $0 start"
        for P in $(all_links); do
            [ -L "$P" ] && fail "leftover link $P (run: $0 stop)"
        done
    fi
    for P in $LEGACY; do
        is_our_link "$P" && fail "$P is still linked (pre-preload pack) - run: $0 stop; $0 start"
    done

    echo ""
    echo "--- RGI files ---"
    L=/mnt/app/eso/hmi/lib
    J=/mnt/app/eso/hmi/lsd/jars
    check_file $RGI_DIR/librgi_hook.so      "RGI hook"
    check_file $RGI_DIR/maneuver_render     "renderer"
    check_file $RGI_DIR/rgi_render_sup.sh   "renderer supervisor"
    if [ "$PLAT" = NV ]; then
        check_file $L/flag_atlas.rgba           "flag atlas"
        check_file $L/rgd_blank.png             "rgd_blank.png (creates displayable 98 at HMI start)"
        for _S in main.vert main.frag fxaa.vert fxaa.frag; do
            if [ -f "$L/shaders/$_S.bin" ]; then
                ok "shader blob $_S.bin"
            else
                warn "shader blob $_S.bin missing (needed by the H2 renderer; HL compiles its own)"
            fi
        done
    fi
    check_file $J/RGI.jar                   "RGI.jar"
    check_file $J/AltScreen.jar             "projection jar AltScreen.jar"

    echo ""
    echo "--- projection (preload) ---"
    check_file /mnt/app/eso/bin/vidcp          "vidcp"
    check_file /mnt/app/eso/bin/vidaa          "vidaa"
    check_file /mnt/app/eso/lib/libcpproxy.so  "libcpproxy.so (CarPlay cluster, preloaded)"
    check_file /mnt/app/eso/lib/libaaproxy.so  "libaaproxy.so (Android Auto cluster, preloaded)"

    D=/mnt/app/eso/bin/apps/dio_manager
    if grep -E "$MOD_TAGS" "$D" >/dev/null 2>&1; then
        ok "dio_manager is the preload wrapper"
        grep 'libcpproxy.so' "$D" >/dev/null 2>&1 || \
            fail "dio_manager wrapper does not preload libcpproxy.so - no CarPlay cluster screen"
        grep -E 'stock/dio_manager|dio_manager\.orig' "$D" >/dev/null 2>&1 || \
            warn "dio_manager wrapper does not mention stock/dio_manager"
        if [ "$PLAT" = QC ]; then
            grep 'librgi_hook.so' "$D" >/dev/null 2>&1 || \
                warn "dio_manager wrapper does not preload librgi_hook.so - no CarPlay route guidance"
        fi
        DS="${D%/*}/stock/dio_manager"
        [ -f "$DS" ] || DS="$D.orig"
        if [ ! -f "$DS" ]; then
            fail "wrapper present but no stock/dio_manager"
        elif grep -E "$MOD_TAGS" "$DS" >/dev/null 2>&1; then
            fail "$DS is a wrapper too (would loop) - stop, reboot, start"
        elif [ "$(size_of "$DS")" -gt 65536 ]; then
            case "$(size_of "$DS")" in
                606693) ok "stock dio_manager ($DS): QC 3638 (606693 bytes)" ;;
                691203) ok "stock dio_manager ($DS): QC 5092 (691203 bytes)" ;;
                *)      ok "stock dio_manager ($DS, $(size_of "$DS") bytes)" ;;
            esac
        else
            fail "$DS is only $(size_of "$DS") bytes - not the stock binary"
        fi
    else
        fail "dio_manager is not the preload wrapper - no CarPlay cluster screen"
    fi

    G=/mnt/app/eso/bin/apps/gal
    if grep 'gal preload wrapper' "$G" >/dev/null 2>&1; then
        ok "gal is the preload wrapper"
        grep 'libaaproxy.so' "$G" >/dev/null 2>&1 || \
            fail "gal wrapper does not preload libaaproxy.so - no Android Auto cluster screen"
        GS="${G%/*}/stock/gal"
        [ -f "$GS" ] || GS="$G.orig"
        if [ ! -f "$GS" ]; then
            fail "gal wrapper present but no stock/gal"
        elif grep -E "$MOD_TAGS" "$GS" >/dev/null 2>&1; then
            fail "$GS is a wrapper too (would loop) - stop, reboot, start"
        fi
    else
        fail "gal is not the preload wrapper - no Android Auto cluster screen"
    fi

    B=/mnt/app/eso/bin/apps/btstack
    if grep 'btstack - wrapper' "$B" >/dev/null 2>&1; then
        ok "btstack is the wrapper (libbthook, wireless CarPlay)"
        if [ -f /mnt/app/eso/bin/apps/stock/btstack ] && ! grep -E "$MOD_TAGS" /mnt/app/eso/bin/apps/stock/btstack >/dev/null 2>&1; then
            ok "stock btstack available (stock/btstack)"
        else
            fail "btstack wrapper present but no stock stock/btstack - Bluetooth would not start!"
        fi
        if [ -e /eso/bin/apps/btstack ] && ! grep 'btstack - wrapper' /eso/bin/apps/btstack >/dev/null 2>&1; then
            warn "/eso/bin/apps/btstack is not the wrapper - is /eso the same tree as /mnt/app/eso?"
        fi
    else
        echo "        btstack: stock (no wrapper - wireless CarPlay needs the btstack wrapper)"
    fi

    A=/mnt/app/eso/bin/apps/smartphone_integrator
    if grep 'smartphone_integrator preload wrapper' "$A" >/dev/null 2>&1; then
        ok "smartphone_integrator is the wrapper (wireless Android Auto)"
        AS=/mnt/app/eso/bin/apps/stock/smartphone_integrator
        if [ -f "$AS" ] && ! grep -E "$MOD_TAGS" "$AS" >/dev/null 2>&1; then
            ok "stock smartphone_integrator available (stock/smartphone_integrator)"
        else
            fail "smartphone_integrator wrapper present but no stock/smartphone_integrator - no phone connections at all!"
        fi
        _SIP=$(pids_of smartphone_integrator)
        if [ -z "$_SIP" ]; then
            warn "smartphone_integrator not running"
        else
            if pids_have_lib "$_SIP" 'libaawusb\.so'; then
                ok "smartphone_integrator uses libaawusb (virtual phone)"
            else
                warn "smartphone_integrator without libaawusb (aaw_off / aawusb_off / start counter, see /tmp/aawusb_si.log)"
            fi
            if pids_have_lib "$_SIP" 'libaawmcc\.so'; then
                ok "smartphone_integrator has libaawmcc (media connector test for the virtual phone)"
            else
                warn "smartphone_integrator without libaawmcc - the HMI would not offer the wireless phone"
            fi
        fi
        grep 'libaawusb.so' /mnt/app/eso/bin/apps/gal >/dev/null 2>&1 || \
            fail "gal wrapper does not preload libaawusb.so - wireless Android Auto cannot reach gal"
        if [ -n "$(pidin -p aawd -f a 2>/dev/null | sed -n '1!p')" ]; then
            ok "aawd running (wireless Android Auto)"
        else
            warn "aawd not running  ->  $AAW_BOOT start"
        fi
        [ -f /tmp/aaw_vdev ] && ok "a phone is connected: virtual phone published (/tmp/aaw_vdev)"
    else
        echo "        smartphone_integrator: stock (no wrapper - wireless Android Auto needs it)"
    fi

    # preload: the hooked library/binary must be the stock one
    check_stock /mnt/app/eso/lib/libairplay.so "libairplay.so" 'libcpproxy\.so|libirc_mmx_svc\.so'
    _GS="${G%/*}/stock/gal"; [ -f "$_GS" ] || _GS="$G.orig"
    check_stock "$_GS"                         "stock gal"     'libaaproxy\.so|libsdisproxy\.so'

    if [ "$PLAT" = NV ]; then
    echo ""
    echo "--- RGI-H shim ---"
    _SH=$MMIPOD
    if grep 'RGI-H shim' "$_SH" >/dev/null 2>&1; then
        ok "mm-ipod is the RGI-H shim"
        if grep 'RGI-H shim' "$_SH.orig" >/dev/null 2>&1; then
            fail "mm-ipod.orig is the shim too (would loop) - stop, reboot, start"
        elif [ -f /mnt/app/armle/usr/sbin/rgd_real/mm-ipod ] || [ -f "$_SH.orig" ]; then
            ok "stock mm-ipod available (rgd_real/ or mm-ipod.orig)"
        else
            fail "shim present but no stock mm-ipod (rgd_real/mm-ipod or mm-ipod.orig)"
        fi
        grep 'librgi_hook.so' "$_SH" >/dev/null 2>&1 || \
            warn "shim does not preload librgi_hook.so (older shim with librgd_hook.so?)"
    else
        fail "mm-ipod is not the RGI-H shim - no CarPlay route guidance"
    fi
    fi

    echo ""
    echo "--- boot hook ---"
    if is_hook "$SVC"; then
        ok "servicemgrmibhigh is the boot hook"
        if is_stock_bin "$SVC_ORIG"; then ok "stock $SVC_ORIG present"
        else fail "$SVC_ORIG missing - the unit will not start services!"; fi
        _HN=$(grep '^NV=' "$SVC" | head -1)
        _HN=${_HN#NV=}
        if [ -f "$_HN" ]; then ok "hook runs $_HN"; else fail "hook runs $_HN - not found"; fi
        [ "$_HN" = "$HOOK_SCRIPT" ] || warn "hook runs $_HN, not $HOOK_SCRIPT (old hook? run: $0 install)"
        grep -q "$HOOK_TAG" "$SVC" 2>/dev/null || warn "old runNV/runQC hook - run: $0 install"
        grep -q '/dev/ooc/startup' "$SVC" 2>/dev/null || \
            warn "hook has no swdl check (older hook) - run: $0 install"
        _HS=$(grep '^STOP=' "$SVC" | head -1)
        _HS=${_HS#STOP=}
        if [ "$_HS" = "$DISABLE" ]; then
            ok "hook off switch: $_HS"
        else
            warn "hook off switch is '${_HS:-none (old hook)}', not $DISABLE - run: $0 install"
        fi
    else
        warn "boot hook not installed ($0 install)"
    fi
    if lsd_patched; then ok "lsd.sh waits for $MARKER"
    else warn "lsd.sh does not wait for $MARKER ($0 install)"; fi
    for _BL in $HOOK_LOG /tmp/runNV_boot.log /tmp/runQC_boot.log; do
        [ -f "$_BL" ] && tail -1 "$_BL" | sed 's/^/        boot: /'
    done

    check_firewall
    check_firewall_wlan

    echo ""
    echo "--- access point (start-ap.sh) ---"
    _AP=/mnt/app/eso/telephone/start-ap.sh
    if [ -L "$_AP" ]; then ok "$_AP is our link"
    elif [ -f "$ROOT$_AP" ]; then warn "$_AP is not linked (stock script in use) - $0 prepare"
    else warn "no start-ap.sh in the pack - the stock script runs (HT40)"; fi
    if [ -f /tmp/start-ap.log ]; then
        _APL=$(grep -E "^applied|falling back" /tmp/start-ap.log | tail -1)
        case "$_APL" in
            applied*) ok "AP: $_APL" ;;
            *)        warn "AP: ${_APL:-our script ran, no config applied}" ;;
        esac
    else
        warn "AP: no /tmp/start-ap.log - our start-ap.sh has not run since boot"
    fi

    echo ""
    echo "--- USB (MTP skip for Android phones) ---"
    if usb_patched; then
        ok "$USBL skips MTP for 0x18d1 phones (fixusb)"
        if [ -f "$USB_MARK" ] || [ -f /mnt/app/mtp_skip_android ]; then
            ok "marker $USB_MARK set"
        else
            warn "marker $USB_MARK missing - the MTP skip is off (stock MTP)"
        fi
        if [ -f "$USB_ORIG" ]; then
            ok "stock copy $USB_ORIG"
        else
            warn "no stock copy $USB_ORIG (fixusb derives one; restoreusb works without it)"
        fi
        if [ -f /tmp/mtp_custom.log ]; then
            echo "        last decision: $(tail -1 /tmp/mtp_custom.log 2>/dev/null)"
        fi
    else
        echo "  NOTE  $USBL has no MTP skip (AltScreen.sh fixusb if Android Auto fails at cold boot)"
    fi

    check_wifi

    echo ""
    echo "--- processes ---"
    for _N in $([ "$PLAT" = NV ] && echo mm-ipod) dio_manager gal vidcp vidaa maneuver_render rgi_render_sup.sh btstack wcpd wcppaird; do
        _C=$(pidin ar 2>/dev/null | grep -v grep | grep -c "$_N")
        case "$_N:$_C" in
            maneuver_render:0)      warn "maneuver_render not running (supervisor starts it $SF_RENDER_DELAY s after start)" ;;
            rgi_render_sup.sh:0)    warn "rgi_render_sup.sh not running" ;;
            maneuver_render:1|rgi_render_sup.sh:1) ok "$_N running" ;;
            maneuver_render:*|rgi_render_sup.sh:*) fail "$_N running $_C times (must be 1)" ;;
            *:0)                    echo "        $_N: not running" ;;
            *)                      echo "        $_N: running ($_C)" ;;
        esac
    done
    # By PID, not "pidin -p <name>": the shim starts the real binary as
    # mm-ipod.orig / rgd_real/mm-ipod, so a name lookup finds nothing.
    _MP=""
    [ "$PLAT" = NV ] && _MP=$(pids_of 'mm-ipod')
    if [ -n "$_MP" ]; then
        if pids_have_lib "$_MP" 'librgi_hook.so'; then
            ok "mm-ipod has librgi_hook.so loaded"
        else
            warn "mm-ipod (pid $_MP) runs without librgi_hook.so (rgd_disable? replug after install?)"
        fi
    fi
    # By PID: the wrapper becomes the stock binary (stock/dio_manager)
    _DP=$(pids_of 'dio_manager')
    if [ -n "$_DP" ]; then
        if pids_have_lib "$_DP" 'libcpproxy.so'; then
            [ "$(pids_lib_count "$_DP" 'libcpproxy.so')" -gt 1 ] && \
                warn "libcpproxy.so mapped more than once in dio_manager (patched libairplay too?)"
            ok "dio_manager has libcpproxy.so loaded"
        else
            fail "dio_manager (pid $_DP) runs without libcpproxy.so (CarPlay cluster)"
        fi
        pids_have_lib "$_DP" 'libirc_mmx_svc.so' && \
            fail "dio_manager maps libirc_mmx_svc.so - the old patched libairplay is still in use"
        if [ "$PLAT" = QC ]; then
            if pids_have_lib "$_DP" 'librgi_hook.so'; then
                ok "dio_manager has librgi_hook.so loaded"
            else
                warn "dio_manager (pid $_DP) runs without librgi_hook.so (rgd_disable? hook missing?)"
            fi
        fi
    fi
    _GP=$(pids_of '/gal')
    if [ -n "$_GP" ]; then
        if pids_have_lib "$_GP" 'libaaproxy.so'; then
            [ "$(pids_lib_count "$_GP" 'libaaproxy.so')" -gt 1 ] && \
                warn "libaaproxy.so mapped more than once in gal (patched stock gal?)"
            ok "gal has the Android Auto proxy loaded"
        elif pids_have_lib "$_GP" 'libsdisproxy.so'; then
            fail "gal (pid $_GP) maps libsdisproxy.so - the old patched gal is still in use"
        else
            fail "gal (pid $_GP) runs without libaaproxy.so (Android Auto cluster)"
        fi
    fi

    check_controls

    echo ""
    echo "============================================================"
    echo "CHECK: $N_OK ok, $N_WARN warning(s), $N_FAIL failure(s)"
    echo "============================================================"
    [ "$N_FAIL" = 0 ]
}


# ============================================================
# ARGUMENT
# ============================================================

case "$1" in

    start)
        start_overlay
        ;;

    prepare)
        prepare_tree
        ;;

    crashwatch)                 # started by "start" in the background
        crash_watch
        ;;

    purge)
        if [ -f "$STATE" ]; then
            echo "Overlay active - run: $0 stop   first"
            exit 1
        fi
        case "$BASE" in
            ""|/|/mnt|/mnt/ota) echo "ERROR: BASE='$BASE' - not removed"; exit 1 ;;
        esac
        rm -rf "$BASE" && echo "removed $BASE"
        ;;

    stop)
        stop_overlay
        ;;

    check)
        check_setup
        ;;

    checkfw)
        check_firewall
        check_firewall_wlan
        [ "$N_FAIL" = 0 ]
        ;;

    fixfw)
        fix_firewall
        fix_firewall_wlan
        check_firewall
        check_firewall_wlan
        ;;

    restorefw)
        restore_firewall
        ;;

    fixusb)
        fix_usb
        ;;

    restoreusb)
        restore_usb
        ;;

    flags)
        copy_flags "$2"
        ;;

    patchwifi|patch_wifi)
        patch_wifi
        ;;

    restorewifi|restore_wifi)
        restore_wifi
        ;;

    install)
        copy_flags
        install_hook
        fix_firewall
        fix_firewall_wlan
        check_firewall
        check_firewall_wlan
        fix_usb
        patch_wifi
        ;;

    uninstall)
        uninstall_hook
        restore_firewall
        check_firewall
        restore_usb
        restore_wifi
        ;;

    *)
        echo "Usage:"
        echo "  $0 prepare     unpack $PACK to $ROOT and save the stock binaries (once)"
        echo "  $0 start       link $ROOT (+ RGI renderer supervisor, wireless CarPlay daemons)"
        echo "  $0 stop        stop renderer and wireless CarPlay daemons, remove the links"
        echo "  $0 purge       remove $BASE (overlay not active)"
        echo "  $0 check       links, files, firewall, processes (read-only)"
        echo "  $0 checkfw     firewall only (read-only)"
        echo "  $0 fixfw       allow tcp $ALT_PORT on carplay0 in the pf files (persistent, reboot)"
        echo "  $0 restorefw   put the stock pf files back"
        echo "  $0 fixusb      no MTP driver for Android phones (0x18d1): Android Auto at cold boot (persistent, reboot)"
        echo "  $0 restoreusb  stock usblauncher.lua again"
        echo "  $0 patchwifi   patched Wi-Fi driver ($WIFIDRVP) over the stock one, stock copy kept (persistent, reboot)"
        echo "  $0 restorewifi stock Wi-Fi driver back (persistent, reboot)"
        echo "  $0 flags [dir] control files from a flags folder (next to this script, /fs/sda0/flags, ...) into /mnt/ota/app"
        echo "  $0 install     flags + boot hook in servicemgrmibhigh (runs start at every boot)"
        echo "  $0 uninstall   put the stock servicemgrmibhigh back"
        exit 1
        ;;

esac
