# Wireless CarPlay on MHI2Q QC — Technical Reference

Companion to `PROJECT_STATUS.md`. Unit: MHI2Q QC (mmx2qc), rel/CLU7, QNX 6.5.0 ARMv7, firmware 3638 / MU0917. Stock CarPlay receiver: AirPlay 210.81 in `dio_manager`.

**Last update:** 2026-10-25 — libbthook, car-initiated iAP2, `dio_manager` on demand, boot start, event-channel pump, logging markers.

---

## 1. Overview

The design follows a factory wireless unit (Audi MIB2+):

1. **Bluetooth.** The iPhone and `wcpd` run iAP2 over an RFCOMM channel that `libbthook.so` adds to the stock Bluetooth stack: authentication (the car's MFi chip), identification, Wi-Fi credentials, then `CarPlayStartSession`. The car opens this iAP2 channel itself when it connected the phone (cold boot, after a session, after pairing).
2. **On demand.** As soon as an iPhone is on Bluetooth, `wcpd` starts `dio_manager` in wireless mode; CarPlay is offered to the HMI once it is ready.
3. **Wi-Fi.** The phone joins the car's access point and connects to the stock receiver; `libwcpstart.so` (preloaded into `dio_manager`) does pairing, encryption and the stream and audio adaptation.
4. **iAP2 inside the session.** The stock iAP2 client (Cinemo) runs a second iAP2 session with the phone through the AirPlay event and control channels (`iAPSendMessage`). The phone then drops its Bluetooth iAP2, and the car releases Bluetooth (`disableBluetooth`).
5. **End.** `dio_manager` re-enables Bluetooth and exits after every session; the next phone starts it again. A USB iPhone gets its `dio_manager` from smartphone_integrator, as stock; only one runs at a time and USB wins.

---

## 2. Components

| Component | Runs in | Role |
| --- | --- | --- |
| `btstack` wrapper | started by the connectivity launcher in place of `/eso/bin/apps/btstack` | runs the **stock** btstack with `libbthook.so` preloaded; starts `wcp-boot.sh` once per boot |
| `libbthook.so` | stock btstack | RFCOMM server channel + SDP records (iAP2, CarPlay), bridge to `wcpd`, car-initiated iAP2 — without changing any code (§5) |
| `wcp-boot.sh` | shell | starts `wcppaird` and `wcpd` (`start/stop/restart/status`) |
| `wcpd` | daemon | Bluetooth iAP2, Wi-Fi credentials, `dio_manager` on demand, offer to the HMI, `CarPlayStartSession`, recovery, access-point watch |
| `wcppaird` | daemon | receiver identity (Ed25519), Pair-Setup / Pair-Verify, MFi coprocessor |
| `dio-up.sh` | shell (called by `wcpd`) | starts `dio_manager` in wireless mode through its wrapper, unless one runs |
| `dio_manager` wrapper + insert `dio_manager.wcp.inc` | shell (started by smartphone_integrator or `dio-up.sh`) | preloads librgi_hook, libcpproxy, libwcpstart; records `usb`/`wireless`; stops a wireless instance when a USB phone needs `dio_manager` |
| `libwcpstart.so` | preloaded into `dio_manager` | everything on Wi-Fi (§6, §8); passive for USB |
| `librgi_hook.so` (`wcp` module) | `dio_manager` | wireless parts of the Identify, Wi-Fi request; no StartSession inside the session |
| `libcpproxy.so` | `dio_manager` | cluster stream (type 111) over Wi-Fi without the legacy AES setup |
| `AltScreenQ_wcp.jar` | HMI (Java) | virtual CarPlay device 200, connect/disconnect, session state to the HMI |
| AP overlay (`start-ap.sh`) | access point start | HT20, channel 6, Apple vendor element |

`libwcpstart.so` sources:

| File | Content |
| --- | --- |
| `wcpstart.c` | constructor, start order, interface `carplay0 → uap0`, Bonjour, `/tmp/wcp_dio_ready` |
| `wcphook.c` | socket interposers, encryption, request/reply adaptation, `/info`, keep-alive, iAP2 inside the session, event-channel pump, watchdog, startup-timer redirect, audio relay + pacer, diagnostics |
| `wcpaead.c` | ChaCha20-Poly1305 |
| `wcpplist.c / .h` | binary plist reader / writer (root-first layout) |
| `wcpaac.c / .h` | AAC-LC → PCM through the unit's Cinemo codec |
| `wcpopus/` | fixed-point libopus 1.4 (symbols hidden) |
| `wcpdebug.h` | logging switch shared by all components (§9) |

---

## 3. Files on the car

| Where | Files |
| --- | --- |
| `/mnt/ota/wcp/` | `libwcpstart.so`, `libbthook.so`, `wcpd`, `wcppaird`, `wcp-boot.sh`, `dio-up.sh`, `wcp-test4.sh`, `wcp-logcheck.sh`, optional `wcp.conf`, `nv/` (pairing libraries), the libraries `wcpd` needs |
| `/eso/bin/apps/btstack` | the wrapper (from `bthook.zip`) |
| `/eso/bin/apps/stock/btstack` | stock binary (SHA-256 31290e21…, 1 872 828 bytes) |
| `dio_manager` wrapper | with `dio_manager.wcp.inc` inserted right before `exec "$REAL" "$@"` |
| `/mnt/ota/wcp/wcp.conf` | optional, sourced as shell: `BTMAC=…` (car's Bluetooth address), `WCP_KEEP_BT=…` |

---

## 4. Start and lifecycle

| When | What happens |
| --- | --- |
| Boot | The connectivity launcher starts `btstack` (the wrapper): stock btstack + libbthook; in the background, once `/mnt/ota` is mounted, `wcp-boot.sh start` (once per boot, `/tmp/wcp_boot_started`). |
| `wcp-boot.sh start` | `kern.sbmax=1048576`, `/tmp/wcp_btmac`, session file `DISCONNECTED`, then `wcppaird` and `wcpd` (`WCP_START=1`, `WCP_GATE=/tmp/wcp_go`, `WCP_DIO_UP=dio-up.sh`). No `dio_manager`. |
| iPhone on Bluetooth | libbthook opens iAP2 if the phone does not (4 s); `wcpd` gets `phone link up` and runs `dio-up.sh` (head start). |
| `CarPlayAvailability` | `wcpd` waits for `/tmp/wcp_dio_ready`, then writes `AVAILABLE`; the HMI lists device 200 and connects; the receiver listens (`/tmp/wcp_go`); `wcpd` sends `CarPlayStartSession`. |
| Session | Wi-Fi, pairing, encrypted channels, iAP2 inside the session, Bluetooth released (§6). |
| Session end | `dio_manager` re-enables Bluetooth and exits; the car reconnects the phone over Bluetooth; the next connection starts a new `dio_manager`. |
| USB iPhone | smartphone_integrator starts the wrapper (no `WCP_DIO_WIRELESS`): a running wireless instance is stopped first; `/tmp/wcp_dio_mode` = `usb <pid>`; `wcpd` neither starts nor offers wireless until it ends. |
| Recovery | A gate whose `dio_manager` is dead is ignored and removed. If no session is reported within 25 s of StartSession, `wcpd` stops the wireless `dio_manager`, a fresh one is started, and CarPlay is offered again. |

**State files** (all in `/tmp`, which is `/dev/shmem` — no directories):

| File | Written by | Meaning |
| --- | --- | --- |
| `wcp_session` | `wcpd`, hook | `state=` DISCONNECTED / AVAILABLE / CONNECTED / STARTED, phone name, Wi-Fi MAC, IP — read by the HMI bridge |
| `wcp_go` | hook | the receiver listens on port 5000; contains the `dio_manager` pid |
| `wcp_dio_mode` | wrapper insert | `usb <pid>` or `wireless <pid>` |
| `wcp_dio_ready` | libwcpstart | `<pid>` of a wireless `dio_manager` that is up |
| `wcp_phone_gone` | `wcpd` | the phone's Wi-Fi logged off the access point (hook ends the session) |
| `wcp_btmac` | `wcp-boot.sh` | the car's Bluetooth address for the `wcp` module |
| `wcp_boot_started` | btstack wrapper | boot start done (not again on a btstack restart) |
| `bthook_registering` | libbthook | registration in progress; if btstack dies during it, the next btstack start stays stock |

---

## 5. Bluetooth: libbthook

btstack's code is mapped from flash and cannot be written at runtime, so libbthook only intercepts calls btstack makes into shared libraries (`LD_PRELOAD`). Active only in a process named `btstack` with the known build (graft hook words + first words of 16 stack functions, read via `/proc/self/as`).

| Need | How |
| --- | --- |
| The end of the stack start-up | `BluetoothServices::startBtStack` logs the Device-ID result on its trace channel (`Primary DID registered` …). The channel's threshold is lowered to 1 when it is constructed (`tracing::Channel` ctor), the `logCV` interposer sees the message, and a thread with its own stack registers 0.3 s later. |
| RFCOMM channel + SDP records | `RF_RegisterServerChannel` (channel 4), `SDP_AddRecord` × 2 (iAP2 `…DECACAFF`, CarPlay `EC884348-…`), EIR refresh. |
| CarPlay UUID in the advertisement | btstack builds it from the SDP records; the HCI command `Write_Extended_Inquiry_Response` (opcode 0x0C52) passes through `MsgSendv` (3 parts: write message, command header, parameters) and is checked (`CarPlay UUID PRESENT`). |
| Bridge to `wcpd` | worker thread, `127.0.0.1:57342`, frames 1 (connected), 2 (data), 3 (closed), 4 (connect out). |
| Car-initiated iAP2 | btstack's `BtJobStartService` channel (threshold lowered to 1) logs `ACL to <addr> established` / `… already connected -> starting service immediately`. 4 s later without an iAP2 channel, libbthook opens one: SDP query for the phone's iAP2 service, then `RF_OpenClientChannel`. No answer within 12 s → cancelled; busy (no answer, `0x13` in progress) → again after 5 s, up to 3 times; "no iAP2 service" → that address is left alone for 30 s. |
| Atomics | `ldrex`/`strex` + `dmb` (qcc's gcc 4.4 would call `__sync_lock_test_and_set_4`, which QNX libc does not have). |

---

## 6. Wi-Fi session (libwcpstart)

| Step | Detail |
| --- | --- |
| Pairing | `/pair-setup`, `/pair-verify` answered by the hook (bodies to `wcppaird` on 127.0.0.1:57343); then ChaCha20-Poly1305 on control (5000) and event (5001) channels. |
| `/info`, SETUP | feature bit 38 added, bits 20/22 cleared; audio formats (§8); `keepAlivePort`; stream 102 shown to the stock code as 100. |
| Screen | streams 110 (main, 6030) and 111 (cluster, 6031) decrypted frame by frame; the stock code gets plain frames. |
| iAP2 inside the session | Cinemo's `open("/dev/otg-cinemo")` gets a socketpair once the event channel is up. Car → phone: each iAP2 packet as `iAPSendMessage` on the event channel. Phone → car: `iAPSendMessage` on the control channel, answered by the hook. |
| Event-channel replies | No CSeq: requests are queued in wire order (stock / ours, 256 entries), replies matched by order; replies to ours are consumed. |
| Event-channel pump | The stock code reads the event channel only while it waits for its own reply. Whenever a stock thread waits in `select()` without the event socket, the hook adds it and reads and decrypts it itself; data for the stock stays in its buffer and `select()` reports it readable as soon as the stock waits for it. One reader at a time. |
| Startup timer | `dio_manager` ends a session 6 s after iAP2 connects unless the session start stops the timer — reversed order over Wi-Fi. The GOT entry of `s_sessionStartupTimerHandler` (`0x1937a0`) points to the hook, which ignores the timeout while a session with iAP2 inside runs. |
| Bluetooth | `disableBluetooth` from the phone goes to the stock code (Bluetooth released); `wcpd` closes a Bluetooth iAP2 link still open 8 s into a session. |
| Phone gone | `wcpd` follows the access point (`sloginfo -w`): `STA_DEAUTH`/`DISASSOC` of the phone → `/tmp/wcp_phone_gone` → the hook shuts the control connection within 0.25 s. Fallback: 5 s without any traffic from the phone. |

---

## 7. Ports (`uap0`, 10.173.189.1)

| Port | Proto | Owner | Use |
| --- | --- | --- | --- |
| 5000 | TCP | stock receiver (+ hook) | AirPlay control, encrypted |
| 5001 | TCP | stock receiver (+ hook, pump) | event channel, encrypted |
| 6030 | TCP | stock receiver (+ hook) | main screen stream (110) |
| 6031 | TCP | cluster proxy (+ hook) | cluster stream (111) |
| 7070 | UDP | hook relay | all audio from the phone |
| 7071 | UDP | hook | keep-alive |
| 7072 | UDP | stock receiver (moved from 7070) | stock audio socket, fed by the relay on 127.0.0.1 |
| 57342 | TCP (localhost) | `wcpd` | bridge from libbthook |
| 57343 | TCP (localhost) | `wcppaird` | pairing helper for the hook |

---

## 8. Audio path

### 8.1 Advertised formats (Wi-Fi)

| Stream / audio type | In | Out |
| --- | --- | --- |
| 100 default / alert | Opus 16 + PCM 16 mono | Opus 48 mono + PCM 48 stereo + PCM 16 mono |
| 100 telephony, speechRecognition | Opus 16 + PCM 16 mono | Opus 16 + PCM 16 mono |
| 101 default (prompts) | Opus 16 + PCM 16 mono | Opus 16 + PCM 16 mono |
| 102 default / media | – | AAC-LC 48 stereo (+ Opus 48, PCM 48 stereo) |

### 8.2 Stream handling

| Phone sends | Stock receiver sees | Relay does |
| --- | --- | --- |
| 102 media, AAC-LC 48 kHz stereo | type 100, PCM 48 kHz stereo | decrypt → decode → queue → paced on the stock play position (150 ms ahead) |
| 100 / 101, Opus 16 kHz mono | type 100 / 101, PCM 16 kHz mono | decrypt → Opus decode (loss concealment) → PCM; 500 ms lead-in before prompts |
| 100, Opus 48 kHz mono | type 100, PCM 48 kHz stereo | decrypt → decode → stereo |
| microphone | — | stock PCM → Opus 16 kHz mono, 24 kbit/s, complexity 5 → encrypted → to the phone |

### 8.3 Quality compared with USB

| Channel | Wi-Fi | USB | Lowered by us |
| --- | --- | --- | --- |
| Music | AAC-LC 48 kHz stereo from the phone (128 kbit/s CBR or 192 kbit/s VBR) | PCM 48 kHz stereo | no — compressed by the phone, inherent to wireless CarPlay |
| Calls, Siri | 16 kHz mono | 16 kHz mono (stock list `in 0x10 / out 0x8010`) | no |
| Prompts | 16 kHz mono | 16 kHz mono (stock alt list `0x10`) | no |
| Microphone | Opus 24 kbit/s, complexity 5 | PCM | our setting (CPU); can be raised |

---

## 9. Logging

**Build switch** (all native components, same as the RGI hook): `DEBUG_LOG=1` compiles the logging in, `DEBUG_LOG=0` leaves out every log call (arguments not evaluated, no format strings), the level meters and the diagnostic-only interposers. The HMI bridge has the same switch as a constant (`static final boolean DEBUG_LOG` in `WirelessCarPlayBridge.java`).

**Markers** (checked at the first log call, then at most every 5 s — no restart needed):

| Marker | Effect |
| --- | --- |
| `/mnt/ota/app/debug_wificp` | every wireless CarPlay component writes its log file (`DEBUG_LOG=1` builds); scripts log too |
| `/mnt/ota/app/debug_wificp_raw` | together with the above: raw dumps as well — every message in hex, every iAP2 packet (large logs) |
| `/mnt/ota/app/debug_hook` | librgi_hook (incl. its `wcp` module) — RGI framework, unchanged |

`WCP_DIO_TRACE=n` (`dio_manager`'s own trace to `/tmp/dio_trace.log`) also needs `debug_wificp`.

**Log files** (in `/tmp`, RAM; `wcp-test4.sh` keeps the previous run as `/tmp/prev_<name>` and `sloginfo` as `/tmp/prev_slog.txt`):

| File | Component | Content |
| --- | --- | --- |
| `wcphook.log` | libwcpstart (hook) | session, encryption, iAP2 inside the session, event channel, pump, watchdog, audio relay |
| `wcpstart.log` | libwcpstart (start) | start order, HMI parameters, `/tmp/wcp_dio_ready` |
| `bthook.log` | libbthook | start-up point, registration, advertisement, car-initiated iAP2, bridge |
| `wcpd.log` | `wcpd` | Bluetooth iAP2, credentials, on-demand start, offer, StartSession, recovery, access-point events |
| `wcppaird.log` | `wcppaird` | pairing |
| `wcp_dio_up.log` | `dio-up.sh`, wrapper insert | `dio_manager` starts, USB hand-over |
| `wcp_boot.log` | `wcp-boot.sh` | start/stop |
| `dio_manual.log` | `dio-up.sh` | `dio_manager`'s own output |
| `dio_trace.log` | hook | `dio_manager` trace (`WCP_DIO_TRACE`) |
| `wcp_hmi.log` | HMI bridge | device list, session states, HMI calls |
| `rgi_hook.log` | librgi_hook | Identify (`debug_hook`) |

**Reading them:** `sh /mnt/ota/wcp/wcp-logcheck.sh [prev]` prints sessions, alarms, event-channel counters (expected values shown), who ended a session, iAP2, audio summaries, `wcpd`'s on-demand start and recovery, and `dio_manager` starts. The logs can contain NUL bytes: use `tr -d '\000' < file | grep …`.

---

## 10. Control markers

| Marker | Effect |
| --- | --- |
| `/mnt/ota/wcp/bthook_off` | btstack runs stock (library not loaded); no daemons at boot |
| `/mnt/ota/wcp/bthook_test` | libbthook loaded, only logs, registers nothing |
| `/mnt/ota/wcp/wcp_noboot` | libbthook active, daemons not started at boot |
| `/tmp/bthook_registering` | set by libbthook; present after a crash during registration → next btstack start stays stock (remove to retry) |

---

## 11. Switches (environment)

### wcpd (set by `wcp-boot.sh` where noted)

| Variable | Default | Effect |
| --- | --- | --- |
| `WCP_START` | 1 (boot) | answer `CarPlayAvailability` with `CarPlayStartSession` |
| `WCP_GATE` | `/tmp/wcp_go` (boot) | send StartSession only while the receiver listens |
| `WCP_DIO_UP` | `dio-up.sh` (boot) | `dio_manager` on demand; unset = never started by `wcpd` |
| `WCP_BTMAC` | from `wcp.conf` | car's Bluetooth address (identification) |
| `WCP_SS_TIMEOUT_MS` | 25000 | no session this long after StartSession → restart the wireless `dio_manager`; 0 = off |
| `WCP_REOFFER_MS` | 20000 | offer CarPlay again if no receiver came up |
| `WCP_BT_DROP_MS` | 8000 | close a Bluetooth iAP2 link still open this long into a session; 0 = off |
| `WCP_AP_WATCH` | on | 0: do not follow the access point's station events |
| `WCP_CFG` | `/tmp/uaputl_wcp.cfg` | access point configuration (SSID, passphrase, channel) |
| `WCP_IP`, `WCP_PORT`, `WCP_SRCVERS` | 10.173.189.1, 5000, 210.81 | receiver address and version in StartSession |
| `WCP_NAME`, `WCP_MODEL`, `WCP_MANUF` | — | identification strings |
| `WCP_PAIRID`, `WCP_PAIRDIR` | — | receiver pairing identity (shared with the hook and `wcppaird`) |
| `WCP_LIBLOG` | off | log libesoiap2's own trace |
| `WCP_RELAY`, `WCP_NO_HOLD` | off | old relay mode (iAP2 kept on Bluetooth) — test only |
| `WCP_FAKE_MFI` | off | host tests without the MFi chip |

### dio_manager / libwcpstart (set by `dio-up.sh` where noted)

| Variable | Default | Effect |
| --- | --- | --- |
| `WCP_DIO_WIRELESS` | 1 (dio-up) | wireless mode; unset = passive (USB) |
| `WCP_IAP_AIRPLAY` | 1 (dio-up) | stock iAP2 client inside the AirPlay session |
| `WCP_KEEP_BT` | 0 | 1: the hook answers `disableBluetooth` itself (Bluetooth stays) |
| `WCP_PASS_DISABLE_BT` | — | pass `disableBluetooth` to the stock code (default with `WCP_IAP_AIRPLAY`) |
| `WCP_DIO_TIMER` | — | `keep`: leave the startup timer untouched |
| `WCP_DIO_DELAY` | 5 | s before the start thread looks for CDIOManager |
| `WCP_DIO_TRACE` | off | `n`: dio_manager trace at level n → `/tmp/dio_trace.log` (needs `debug_wificp`) |
| `WCP_IFACE` | `uap0` | receiver interface |
| `WCP_NO_EV_PUMP` | off | 1: event-channel pump off |
| `WCP_NO_IAP_RELAY` | off | 1: Cinemo's device is not redirected into the session |
| `WCP_PHONE_TIMEOUT_MS` | 5000 | end the session after this long without traffic from the phone; 0 = off |
| `WCP_TRACE` | 768 | bytes of each message in a raw dump (with `debug_wificp_raw`); 0 = none |
| `WCP_TRACE_PORT` | — | also dump connections to this port |
| `WCP_RELAY_PORT`, `WCP_KA_PORT` | 7070, 7071 | relay and keep-alive ports |
| `WCP_RELAY_PRIO` | 21 | relay thread priority; 0 = unchanged |
| `WCP_STOCK_RCVBUF` | on | 0: default receive buffer for the stock audio socket |
| `WCP_102_BUFFER`, `WCP_102_TARGET`, `WCP_102_LATENCY`, `WCP_102_PKT` | 600, 150, 100, 352 | media: queue before start (ms), lead over the stock play position (ms), latency given to the stock code (ms), packet size (frames) |
| `WCP_102_OPENLOOP`, `WCP_102_NOPACE`, `WCP_102_NOGATE`, `WCP_102_HOLD`, `WCP_102_STRIP` | off | media pacing experiments |
| `WCP_101_LEADIN`, `WCP_100_LEADIN` | 500, 0 | silence before prompts / main-channel voice (ms) |
| `WCP_AF_<NAME>_IN/_OUT`, `WCP_AF_PCM_ONLY`, `WCP_AF_HIGH_NODEFAULT`, `WCP_AUDIO_TYPES`, `WCP_AUDIO_STOCK` | — | audio format list overrides (`DEF`, `MEDIA`, `TEL`, `SIRI`, `ALERT`, `ALT`, `HIGH`) |
| `WCP_INFO_FEATURES_OR`, `WCP_EV_SWAP`, `WCP_SCREEN_CLEAR_FLAGS`, `WCP_DEBUG_CF` | — | experiments / analysis |
| `WCP_EARLY` | off | old start order |

### wcppaird

`WCP_PAIRDIR`, `WCP_PAIRID` (identity), `WCP_NVAIRPLAY`, `WCP_VERIFY_TYPE` (pairing internals), `WCP_LIBLOG`.

---

## 12. Build

`build_wcp.bat` (QNX 6.5.0 SDP in `C:\QNX650`):

```
build_wcp.bat                      DEBUG_LOG=1 (default)
set DEBUG_LOG=0 & build_wcp.bat    release, no log code
```

Output in `build\qnx\`: `libwcpstart.so`, `libbthook.so`, `wcpd`, `wcppaird`; the script checks that `libbthook.so` imports no `__sync` helper (`ntoarmv7-objdump -T libbthook.so | grep -i sync` must print nothing). `wcpopus/libopus_wcp.a` is built first (`make` or `build_win.bat` in `wcpopus/`). A clean build is needed whenever `wcpplist.h` changes. librgi_hook: `build_lib.bat` in its tree. HMI bridge: `build.bat` in `wcphmi_src`.

---

## 13. Test and diagnosis

```sh
sh /mnt/ota/wcp/wcp-boot.sh status     # wcpd, wcppaird, dio_manager + mode, session, logging, raw dumps
sh /mnt/ota/wcp/wcp-test4.sh           # restart the daemons (previous logs → /tmp/prev_*)
sh /mnt/ota/wcp/wcp-test4.sh stop
sh /mnt/ota/wcp/wcp-logcheck.sh        # the important lines; "prev" for the previous run
touch /mnt/ota/app/debug_wificp        # logs on   (rm to switch off)
touch /mnt/ota/app/debug_wificp_raw    # raw dumps on
```

Never start `dio_manager` by hand. A working connection in `wcpd.log`: `phone link up` → `starting dio_manager for wireless CarPlay` → `CarPlayAvailability received` → `dio_manager (wireless) is up after … ms - offering CarPlay` → `gate … present` → `sent CarPlayStartSession` → `phone link down` (Bluetooth iAP2 handed over). In `wcphook.log`: `event pump: reading the event channel …` once per session; no `requests waiting`, `queue FULL`, `no request waiting`.

---

## 14. Key addresses

**Stock `dio_manager`** (cksum 2268931283):

| Item | Address |
| --- | --- |
| GOT entry of `CDIOManager::s_sessionStartupTimerHandler` | `0x1937a0` (redirected by the hook) |
| `AirPlayReceiverServerCreate` PLT | `0x111660` |
| `CDSICarplayImpl::startService` | `0x15D658` (screen params at CDIOManager `+0x2C0..+0x2DC`) |
| `CAirPlayMainThread` ctor | `0x14D3EC` |
| `onEvent_startAirPlay` | `0x150018` |

**Stock `btstack`** (SHA-256 31290e21…):

| Item | Address |
| --- | --- |
| Graft hook points (build check only) | `0x11EFDC` (start-up), `0x12C990` (EIR builder) |
| GOT entry: `startBtStack` trace channel | `0x2C6134` (GOT `0x2C5A50` + `0x6E4`) |
| GOT entry: `BtJobStartService` trace channel | `0x2C6A94` (GOT `0x2C5A50` + `0x1044`) |
| `RF_RegisterServerChannel`, `RF_DeregisterServerChannel` | `0x27C0BC`, `0x27C058` |
| `SDP_AddRecord`, `SDP_RemoveRecord`, EIR refresh | `0x20AE24`, `0x20ADA4`, `0x1DF0A8` |
| `RF_RespondChannel`, `RF_CloseChannel`, `RF_SendData`, `RF_FrameSize`, `RF_AdvanceCredit` | `0x27B9E0`, `0x27BA9C`, `0x27B89C`, `0x27B718`, `0x27B800` |
| `CMGR_RegisterHandler`, `CMGR_CreateDataLink`, `CMGR_GetRemoteDevice` | `0x247C2C`, `0x247BE4`, `0x246D28` |
| `SDP_Query`, `SDP_ParseAttributes`, `RF_OpenClientChannel` | `0x1D4800`, `0x1D3E08`, `0x27BB68` |
| SDIO HCI write (`mv8787bt_writev` → `MsgSendv`) | `0x23C328` |

**Stock `libairplay.so`** (analysis):

| Function | Offset | Note |
| --- | --- | --- |
| `AirPlayReceiverSessionSetup` | `0x26D48` | session and stream setup |
| `_requestProcessSetupPlist` | `~0x2E4F8` | parses the SETUP body |
| `AirPlayReceiverSessionMakeModeStateFromDictionary` | `0x22EE4` | mode changes |
| `_AudioStreamSetProperty` | `0x4A0C0` | audio output properties |
| `AirPlayReceiverSessionTearDown` call sites | `+0x2df6c` (session end), `+0x2fda4` (streams) | seen in the hook's diagnostics |