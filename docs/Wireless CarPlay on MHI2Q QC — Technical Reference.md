# Wireless CarPlay on MHI2Q QC — Technical Reference

Companion to `PROJECT_STATUS.md`. Unit: MHI2Q QC (mmx2qc), rel/CLU7, QNX 6.5.0 ARMv7, firmware 3638 / MU0917 and 5092 (MHI2Q_ER_AUG22_P5092), both initially tested. Stock CarPlay receiver: AirPlay 210.81 in `dio_manager`. One set of wireless binaries for both firmwares: the firmware-specific data are build tables, picked at run time (§14).

**Last update:** 2026-10-27 — 5092 support (iAP2 client start, Bonjour), Wi-Fi channel from the running access point, keep-alive as session activity for the stock idle timer, crash watch by snapshot, Wi-Fi switch-on from the HMI, three parts / one pack.

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
| `dio-up.sh` | shell (called by `wcpd`) | starts `dio_manager` in wireless mode through its wrapper, unless one runs; starts mdnsd (Bonjour) first when none runs (5092's `dio_manager` only starts it for USB) |
| `dio_manager` wrapper + insert `dio_manager.wcp.inc` | shell (started by smartphone_integrator or `dio-up.sh`) | preloads librgi_hook, libcpproxy, libwcpstart; records `usb`/`wireless`; stops a wireless instance when a USB phone needs `dio_manager` |
| `libwcpstart.so` | preloaded into `dio_manager` | everything on Wi-Fi (§6, §8); passive for USB |
| `librgi_hook.so` (`wcp` module) | `dio_manager` | wireless parts of the Identify, Wi-Fi request; no StartSession inside the session |
| `libcpproxy.so` | `dio_manager` | cluster stream (type 111) over Wi-Fi without the legacy AES setup |
| `WCP.jar` (`WirelessCarPlayBridge`, `WlanAutoOn`) | HMI (Java) | virtual CarPlay device 200, connect/disconnect, session state to the HMI (SI's DSI filtered through a dynamic proxy, so one source fits 3638 and 5092); switches the car's Wi-Fi on when `/mnt/ota/app/wcp_wifi_on` asks for it |
| AP overlay (`start-ap.sh`) | access point start | HT20, channel 6 (`WCP_CHANNEL` in `wcp.conf`), Apple vendor element built from this car's Bluetooth and AP MAC (`/mnt/ota/wcp/btmac.last` keeps the address for the next boot) |

`libwcpstart.so` sources:

| File | Content |
| --- | --- |
| `wcpstart.c` | constructor, `dio_manager` build table, start order, interface `carplay0 → uap0`, Bonjour TXT, `/tmp/wcp_dio_ready`, iAP2 client start (5092) |
| `wcphook.c` | socket interposers, encryption, request/reply adaptation, `/info`, keep-alive (+ activity for the stock idle timer), iAP2 inside the session, event-channel pump, watchdog, startup-timer redirect, audio relay + pacer, diagnostics |
| `wcpaead.c` | ChaCha20-Poly1305 |
| `wcpplist.c / .h` | binary plist reader / writer (root-first layout) |
| `wcpaac.c / .h` | AAC-LC → PCM through the unit's Cinemo codec |
| `wcpopus/` | fixed-point libopus 1.4 (symbols hidden) |
| `wcpdebug.h` | logging switch shared by all components (§9) |

### Three parts, one or two packs

| Part | Manifest | Contents | Off switch |
| --- | --- | --- | --- |
| AltScreen (phone map in the cluster) | `manifest_alt.txt` | libcpproxy, vidcp, libaaproxy, vidaa, gal wrapper | `altscreen_off` |
| RGI (route guidance in the cluster) + shared files | `manifest_rgi.txt` | librgi_hook, maneuver_render, renderer supervisor, shaders, RGI.jar, AltScreen.jar, dio_manager wrapper, `zipget` | `rgi_off` |
| Wireless CarPlay | `manifest_wcp.txt` | btstack wrapper + libbthook, libwcpstart, wcpd, wcppaird, scripts, start-ap.sh, WCP.jar | `wcp_off` |

`create_tar.bat` makes one `AltScreen.tar.gz` with all three parts (default); `create_tar.bat both` makes `AltScreen.tar.gz` (AltScreen + RGI) and `wcp.tar.gz` (RGI + wireless). `AltScreen.sh` assigns each linked path to a part by location (`feature_of`) and writes the parts that are on to `/tmp/.sf_features` (`v3 altscreen rgi wcp`). Without AltScreen the HMI keeps the stock cluster map (`GALHandler.isSmartphoneClusterEnabled()` false, no "Smartphone Cluster" menu item, `ClusterSceneLink` silent). `TerminalModeActivator` is compiled from one source into AltScreen.jar and WCP.jar and creates `AndroidAutoAutoLaunchHandler` / `WirelessCarPlayBridge` by name only if installed. The dio_manager wrapper preloads libcpproxy with AltScreen, librgi_hook with RGI (`RGI_MODULES=wcp` — only the wireless module — when RGI is off or `/tmp/rgd_disable` is set), libwcpstart with the wireless part.

---

## 3. Files on the car

| Where | Files |
| --- | --- |
| `/mnt/ota/wcp/` | `libwcpstart.so`, `libbthook.so`, `wcpd`, `wcppaird`, `wcp-boot.sh`, `dio-up.sh`, `wcp-test4.sh`, `wcp-logcheck.sh`, `nv/` (pairing libraries), the libraries `wcpd` needs |
| `/mnt/ota/app/AltScreen.tar.gz` + `/mnt/ota/app/AltScreen.sh` | the mod pack and the overlay script. One pack holds everything (built by `create_tar.bat` from `manifest.txt` + `manifest_wcp.txt`) and all of it lives in `/mnt/ota/altscreen/root`: paths under `mnt/app/...` are linked over flash, paths under `mnt/ota/wcp/...` file by file into `/mnt/ota/wcp`. |
| `/mnt/ota/wcp/` | a real directory for data only: `pair/` (receiver identity, never in a pack); the code there is links into the tree |
| `/mnt/ota/altscreen/root/` | the pack unpacked once (`AltScreen.sh install` / `prepare`, or by `start` when the pack is newer), plus the stock copies `stock/dio_manager`, `stock/gal`, `stock/btstack` (copied from flash once; reused by the next prepare while unchanged; copied again only if the firmware brings a newer stock file). Linked as `/mnt/app/eso/bin/apps/stock/<name>`, so the processes keep their stock names. |
| `/mnt/ota/altscreen/links.txt`, `orig.txt`, `prepared.txt` | the paths `start` links; the stock copies and their sources; what was prepared |
| flash | stays stock (the wrappers are linked over it at boot); an older flash install of the btstack wrapper (`/eso/bin/apps/stock/btstack`) is recognised and its stock binary used |
| `/mnt/ota/app/wcp.conf` | optional, sourced as shell: `WCP_KEEP_BT=…`; `BTMAC=…` only to override the address libbthook finds |

### Pairing data: `/mnt/ota/wcp/pair/` - never delete

| File | What | If lost |
| --- | --- | --- |
| `identity` (64 bytes) | the car's CarPlay pairing key (private + public) | **the car gets a new identity at the next boot: every phone must forget the car and pair again** |
| `pairid` (UUID text) | the car's pairing identifier "pi" (CarPlayStartSession, /info, Bonjour) | same as above |
| `peer-<hex of the phone's pairing id>` (32 bytes) | a phone's public key, written at its first wireless connection; iOS uses one pairing identity per **Apple ID**, so all phones on one Apple ID share one file | that Apple ID pairs again at its next connection (no "Forget This Car" needed) |

`wcppaird` creates `identity` and `pairid` only when they are missing (`new pairing identifier …` in `wcppaird.log`). Seen on 26 Oct: the folder was lost in a clean-up of `/mnt/ota/wcp`, the car came back with a new pi (`A229FAB4…` → `B8687833…`), and the phones connected and passed pair-verify but never started CarPlay until each had forgotten the car and paired again. `AltScreen.sh prepare` never touches `pair/`.

Backup after pairing a new phone (a new Apple ID); restore with the daemons stopped (`wcppaird` keeps the identity in memory):

```
tar -czf /mnt/ota/wcp_pair_backup.tgz -C /mnt/ota/wcp pair          # backup
sh /mnt/ota/wcp/wcp-boot.sh stop                                     # restore
tar -xzf /mnt/ota/wcp_pair_backup.tgz -C /mnt/ota/wcp
reboot
```

---

## 4. Start and lifecycle

| When | What happens |
| --- | --- |
| Boot | The boot hook (servicemgrmibhigh) runs `AltScreen.sh start`: links only (`ln -sP` per line of `links.txt`, stock copies refreshed if the firmware brought newer ones), then the RGI renderer supervisor and `wcp-boot.sh start` in the background (it waits for `/dev/i2c8`). The connectivity launcher then starts `btstack` (the linked wrapper): stock btstack + libbthook; the wrapper also calls `wcp-boot.sh start` (a lock lets only one run). |
| `wcp-boot.sh start` | `kern.sbmax=1048576`, `/tmp/wcp_btmac` only if `BTMAC` is configured, session file `DISCONNECTED`, then `wcppaird` and `wcpd` (`WCP_START=1`, `WCP_GATE=/tmp/wcp_go`, `WCP_DIO_UP=dio-up.sh`). No `dio_manager`. |
| iPhone on Bluetooth | libbthook opens iAP2 if the phone does not (4 s); `wcpd` gets `phone link up` and runs `dio-up.sh` (head start). |
| `dio-up.sh` | mdnsd started if none runs; `dio_manager` started through its wrapper in wireless mode. |
| `CarPlayAvailability` | `wcpd` waits for `/tmp/wcp_dio_ready`, then writes `AVAILABLE`; the HMI lists device 200 and connects; the receiver listens (`/tmp/wcp_go`) — on 5092 the hook now posts the iAP2 client's connect job (Cinemo opens its device \~13 s later); `wcpd` sends `CarPlayStartSession`. |
| Session | Wi-Fi (credentials with the running access point's channel), pairing, encrypted channels, iAP2 inside the session, Bluetooth released (§6). |
| HMI start | `WlanAutoOn`: if `/mnt/ota/app/wcp_wifi_on` exists, role access point + radio on through `DSIWLAN` (once, or every start with `always`). |
| Session end | `dio_manager` re-enables Bluetooth and exits; the car reconnects the phone over Bluetooth; the next connection starts a new `dio_manager`. |
| USB iPhone | smartphone_integrator starts the wrapper (no `WCP_DIO_WIRELESS`): a running wireless instance is stopped first; `/tmp/wcp_dio_mode` = `usb <pid>`; `wcpd` neither starts nor offers wireless until it ends. Seen on the car: with the phone in wireless CarPlay, plugging in only charges it — the USB session ends after \~8 s and wireless comes back; with the phone's Bluetooth and Wi-Fi off, USB CarPlay runs. |
| USB unplugged | libbthook sees the USB `dio_manager` gone (`/tmp/wcp_dio_mode`, checked once a second) and opens iAP2 to the phone 3 s later; wireless CarPlay resumes (`bthook_nousbresume` switches it off). |
| Recovery | A gate whose `dio_manager` is dead is ignored and removed. If no session is reported within 25 s of StartSession, `wcpd` stops the wireless `dio_manager`, a fresh one is started, and CarPlay is offered again. |

**State files** (all in `/tmp`, which is `/dev/shmem` — no directories):

| File | Written by | Meaning |
| --- | --- | --- |
| `wcp_session` | `wcpd`, hook | `state=` DISCONNECTED / AVAILABLE / CONNECTED / STARTED, phone name, Wi-Fi MAC, IP — read by the HMI bridge |
| `wcp_go` | hook | the receiver listens on port 5000; contains the `dio_manager` pid |
| `wcp_dio_mode` | wrapper insert | `usb <pid>` or `wireless <pid>` |
| `wcp_dio_ready` | libwcpstart | `<pid>` of a wireless `dio_manager` that is up |
| `wcp_phone_gone` | `wcpd` | the phone's Wi-Fi logged off the access point (hook ends the session) |
| `wcp_btmac` | libbthook (or `wcp-boot.sh` from `wcp.conf`) | the car's Bluetooth address (`AA:BB:…`) for `wcpd`'s and the `wcp` module's identification. libbthook asks the chip (HCI `Read_BD_ADDR` through `ME_SendHciCommandAsync`, reply at token `+0x38`) or takes the stack's copy at `bt+0x1B4C`; a configured value is kept |
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
| Phone gone | `wcpd` follows the access point (`sloginfo -w`): `STA_DEAUTH`/`DISASSOC` of the phone → `/tmp/wcp_phone_gone` → the hook shuts the control connection within 0.25 s. Fallback: 5 s without any traffic from the phone (15 s while it is still on the Wi-Fi). |
| Wi-Fi credentials | `wcpd` reads the access point config again for every `0x5702` and sends the channel `uaputl sys_config` reports (it once sent the stock config's 11 while the AP ran on 6). |
| Bonjour | `_airplay._tcp` registered by the stock code through mdnsd; the hook adds `pi` / `pk` and the feature bits to the TXT record (logged when it changes, with the register result). mdnsd from `dio-up.sh` when the firmware has not started it. |
| iAP2 client start (5092) | `dio_manager` 5092 connects Cinemo only for a USB iPhone. When the receiver starts listening, the hook calls `CDIOManager::iAP2Connect()`; if that returns 0 (no `CSIService` in a wireless instance), it posts the connect job itself: config string `iap2.device` (key 10) → `UnicodeString8` → iAP2 service connect (`CDIOManager+0xE8`). No second job within 30 s. |
| Stock idle timer | 210.81 ends a session after 30 s without received audio or activity (`sessionDied`). With only keep-alive beacons arriving (car has the screen, no audio) each beacon adds 1 to activityCount (session `+0x1f0`); the session is held with `CFRetain` from `AirPlayReceiverSessionStart` to its end. Only where the idle check matches the verified code (§14). |

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
| microphone | — | stock PCM → Opus 16 kHz mono, 32 kbit/s, complexity 8 (`WCP_MIC_BITRATE`, `WCP_MIC_COMPLEXITY`) → encrypted → to the phone |

### 8.3 Quality compared with USB

| Channel | Wi-Fi | USB | Lowered by us |
| --- | --- | --- | --- |
| Music | AAC-LC 48 kHz stereo from the phone (128 kbit/s CBR or 192 kbit/s VBR) | PCM 48 kHz stereo | no — compressed by the phone, inherent to wireless CarPlay |
| Calls, Siri | 16 kHz mono | 16 kHz mono (stock list `in 0x10 / out 0x8010`) | no |
| Prompts | 16 kHz mono | 16 kHz mono (stock alt list `0x10`) | no |
| Microphone | Opus 32 kbit/s, complexity 8 | PCM | our setting (was 24 kbit/s, complexity 5) |

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

All control files (markers, settings, tuning values) are in `/mnt/ota/app` (older builds used `/mnt/app`, `/mnt/ota/ALT`, `/mnt/ota/wcp` and `/mnt/ota/.sf_disable`). `AltScreen.sh check` lists the ones that are set, each with what it is for, and any other file in `/mnt/ota/app` as not known. `/tmp/…` switches last until the next reboot.

| `/mnt/ota/app/…` | `check` says | Effect |
| --- | --- | --- |
| `.sf_disable` | all mods off (boot hook) | the boot hook starts nothing (`sf_disable` on SD/USB at boot creates it; its path is written into the hook by `install`); also written by the crash watch after an HMI crash loop. Delete it to turn the mods back on |
| `altscreen_off` | AltScreen CarPlay off (stock cluster) | from the next start the AltScreen part's paths stay unlinked (stock cluster, gal, no route guidance); wireless CarPlay keeps running |
| `rgi_off` | RGI part off (no route guidance) | from the next start the RGI part stays unlinked (stock cluster arrows); AltScreen.jar and `hmi/lib` stay linked while another part needs them |
| `wcp_wifi_on` | Wi-Fi switched on by the HMI | empty: WCP.jar switches the car's Wi-Fi on (access point, radio on) at the next HMI start, then removes the file; `always`: at every start. Written by `install` when the wireless part is installed |
| `wcp_off` | wireless CarPlay off (stock BT/Wi-Fi) | from the next start the wireless part's paths stay unlinked (stock btstack, stock start-ap.sh, no daemons, no WCP.jar); AltScreen keeps running |
| `hmi_startup_off` | stock HMI startup file (20 s wait) | from the next start `/mnt/app/eso/hmi/lsd/hmi_startup.json` is not linked: the HMI uses the copy in its jar again (with CarPlay as the last audio source, the start waits 20 s for the media domain) |
| `debug_wificp` | wireless CarPlay logs on | `/tmp/wcphook.log`, `wcpd.log`, `bthook.log`, `wcpstart.log`, `wcppaird.log`, … (DEBUG_LOG=1 builds) |
| `debug_wificp_raw` | plus raw dumps | with the above: hex dumps |
| `debug_hook` | hook and renderer logs | `librgi_hook`, `maneuver_render` |
| `debug_video` | video bridge logs on | vidbridge / `altscreen_present` |
| `debug_java` | Java HMI logs on | `/tmp/carplay_java.log` |
| `bthook_off` | Bluetooth hook off, stock | btstack runs stock (library not loaded); no daemons at boot |
| `bthook_test` | Bluetooth hook logs only | libbthook loaded, only logs, registers nothing |
| `bthook_noask` | BT address from stack | libbthook does not ask the chip for the car's Bluetooth address (stack's copy only) |
| `bthook_nousbresume` | no wireless after USB | libbthook does not open iAP2 when a USB CarPlay session ends |
| `wcp_noboot` | wireless daemons not started | libbthook active, `wcpd`/`wcppaird` not started at boot |
| `wcp.conf` | wireless CarPlay settings | sourced as shell by `wcp-boot.sh` / `dio-up.sh` (`WCP_…` switches, section 11) |
| `wcp_hmi.conf` | HMI bridge settings | optional settings of `WirelessCarPlayBridge` |
| `wcp_btmac` | car Bluetooth address (override) | for `librgi_hook`; normally `/tmp/wcp_btmac` from libbthook |
| `rgd_disable` | route renderer not started | the supervisor does not start `maneuver_render` (a running one is left alone) |
| `rgi_passive` | RGI hook only logs | `librgi_hook` binds and logs, changes nothing |
| `rgi_java_nodefer` | CarPlay modules start immediately | no 10 s defer of the RGI jar's CarPlay modules |
| `rgi_projection_nowait` | cluster switch without waiting | projection jar: switch at once, not after the first picture |
| `rgi_pb_keep` | stock phonebook kept | RGI jar: stock phonebook support in the cluster |
| `rgi_alt_hide` | altitude hidden too | RGI jar: the altitude is hidden as well as the map scale |
| `rgi_scale_keep` | map scale stays visible | RGI jar: map scale and altitude stay |
| `rgi_cluster_fps` | cluster frame rate (test) | RGI jar: update rate of the cluster context (test only) |
| `rgi_cluster_restore_fps` | cluster rate after (test) | RGI jar: rate restored afterwards (test only) |
| `aa_cluster.daynight` | AA theme follows day/night | libaaproxy: Android Auto cluster theme follows day/night (applies from the next connect) |
| `rgd_window_id` | renderer window id | `maneuver_render`: window id (1–255) |
| `rgd_swap_interval` | renderer swap interval | `maneuver_render`: swap interval (0–10); with `rgd_window_id` the only `rgd_paths.h` entries this build reads |

`check` ignores `AltScreen.sh`, `*.tar.gz` and the install markers `AltScreen.tar.gz.checksum` / `AltScreen.tar.gz.fileinfo`; any other file there is listed as "not a known control file" (e.g. dated backups).

| `/tmp/…` (until reboot) | `check` says | Set by / effect |
| --- | --- | --- |
| `rgd_disable` | route renderer not started | by hand or the crash watch: no RGI renderer / hook for this boot |
| `cpproxy_disable` | cluster (libcpproxy) off | by hand or the crash watch: `dio_manager` without libcpproxy |
| `aaproxy_disable` | AA cluster (libaaproxy) off | by hand or the crash watch: `gal` without libaaproxy |
| `wcp_dio_off` | wireless dio_manager not started | crash watch: `dio-up.sh` starts no wireless `dio_manager` |
| `.sf_features` | – | written by `AltScreen.sh start`: the parts installed and switched on (`altscreen`, `wcp`); read by the dio_manager wrapper |
| `rgi_passive` | RGI hook only logs | as the `/mnt/ota/app` one, for this boot |
| `rgi_java_nodefer` | CarPlay modules start immediately | as the `/mnt/ota/app` one, for this boot |
| `bthook_off` | Bluetooth hook off, stock | by hand or the crash watch: stock btstack from its next start |
| `altscreen_port` | test port file | test only |
| `bthook_registering` | – | set by libbthook while it registers; present after a crash during registration → the library stays inactive until reboot |
| `wcp_boot_started` | – | the daemons are started once per boot, not again when the launcher restarts btstack (not a crash guard) |

**Crash watch** (`AltScreen.sh`, started by `start`, `SF_CRASHWATCH=0` = off). The system's dumper leaves a core file in `/mnt/ota/system/core` for every process that dies of a fault (`<name>.core.gz`, repeats numbered `<name>.N.core.gz`, 0 bytes with `-m`); normal exits, `slay` and launcher restarts leave none. The watcher checks that directory every 10 s against a snapshot (name, size, time) taken at its start: a crash is a core file that is new or changed afterwards, counted once it has stopped changing, once per program per poll. (Not by time stamps: the clock starts at 1 Jan 1970 at every boot, so an old core file can look newer than anything written in this boot.) Two crashes of the same program within 10 min switch our part in it off; its next start runs stock:

| Program | Marker (reason inside) | Effect |
| --- | --- | --- |
| `btstack` | `/tmp/bthook_off` | stock btstack: Bluetooth and calls work, no wireless CarPlay |
| `dio_manager`, USB session | `/tmp/cpproxy_disable` + `/tmp/rgd_disable` | plain USB CarPlay |
| `dio_manager`, wireless (`/tmp/wcp_dio_mode`) | `/tmp/wcp_dio_off` | `dio-up.sh` starts no wireless dio_manager; USB unaffected |
| `gal` | `/tmp/aaproxy_disable` | plain Android Auto |
| `maneuver_render` | `/tmp/rgd_disable` | the supervisor stops restarting it |
| `altscreen_present` | `/tmp/cpproxy_disable` | no cluster video |
| `j9` (HMI) | `/mnt/ota/app/.sf_disable` (sticky) | overlay stopped at once (HMI comes back stock), all mods off at every boot until deleted |

`/tmp` markers last until the next reboot. Events: `/tmp/crashwatch.log`. `AltScreen.sh check` shows the markers with their reason and whether the watch runs.

---

## 11. Switches (environment)

### wcpd (set by `wcp-boot.sh` where noted)

| Variable | Default | Effect |
| --- | --- | --- |
| `WCP_START` | 1 (boot) | answer `CarPlayAvailability` with `CarPlayStartSession` |
| `WCP_GATE` | `/tmp/wcp_go` (boot) | send StartSession only while the receiver listens |
| `WCP_DIO_UP` | `dio-up.sh` (boot) | `dio_manager` on demand; unset = never started by `wcpd` |
| `WCP_BTMAC` | from `wcp.conf` (normally empty) | car's Bluetooth address; empty = `/tmp/wcp_btmac` from libbthook |
| `WCP_SS_TIMEOUT_MS` | 25000 | no session this long after StartSession — or after the phone joined the Wi-Fi, if later — → restart the wireless `dio_manager`; while no station is on the car's Wi-Fi it waits instead (restarting would not help); 0 = off |
| `WCP_REOFFER_MS` | 20000 | offer CarPlay again if no receiver came up |
| `WCP_BT_DROP_MS` | 8000 | close a Bluetooth iAP2 link still open this long into a session; 0 = off |
| `WCP_AP_WATCH` | on | 0: do not follow the access point's station events |
| `WCP_CFG` | `/tmp/uaputl_wcp.cfg`, then `/tmp/uaputl.cfg` | access point configuration (SSID, passphrase); read again for every credentials request; the channel comes from the running access point (`uaputl sys_config`) |
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
| `WCP_IAP_DIRECT` | on | 0: no direct connect job when `iAP2Connect()` returns 0 (5092) |
| `WCP_KA_ACTIVITY` | on | 0: keep-alive beacons do not count as session activity for the stock idle timer |
| `WCP_MDNSD` | on (`dio-up.sh`) | 0: `dio-up.sh` does not start mdnsd |
| `WCP_DIO_CONFIG_DIR` | — | `dio-up.sh`: another directory with `dio_manager.json` (e.g. a Cinemo trace level) |
| `WCP_PHONE_TIMEOUT_MS` | 5000 | end the session after this long without traffic from the phone; 0 = off |
| `WCP_TRACE` | 768 | bytes of each message in a raw dump (with `debug_wificp_raw`); 0 = none |
| `WCP_TRACE_PORT` | — | also dump connections to this port |
| `WCP_RELAY_PORT`, `WCP_KA_PORT` | 7070, 7071 | relay and keep-alive ports |
| `WCP_RELAY_PRIO` | 21 | relay thread priority; 0 = unchanged |
| `WCP_STOCK_RCVBUF` | on | 0: default receive buffer for the stock audio socket |
| `WCP_102_BUFFER`, `WCP_102_TARGET`, `WCP_102_LATENCY`, `WCP_102_PKT` | 600, 150, 100, 352 | media: queue before start (ms), lead over the stock play position (ms), latency given to the stock code (ms), packet size (frames) |
| `WCP_102_OPENLOOP`, `WCP_102_NOPACE`, `WCP_102_NOGATE`, `WCP_102_HOLD`, `WCP_102_STRIP` | off | media pacing experiments |
| `WCP_101_LEADIN`, `WCP_100_LEADIN` | 0, 0 | silence before prompts / main-channel voice (ms); no longer needed since the stream keys are prepared at the SETUP |
| `WCP_102_BOOST` | 0 | ms of extra music margin from another stream's SETUP for 2.5 s (test switch) |
| `WCP_RTP_SEQ` | 1 | first RTP sequence number the relay gives the stock; `rand` = old behaviour |
| `WCP_AF_<NAME>_IN/_OUT`, `WCP_AF_PCM_ONLY`, `WCP_AF_HIGH_NODEFAULT`, `WCP_AUDIO_TYPES`, `WCP_AUDIO_STOCK` | — | audio format list overrides (`DEF`, `MEDIA`, `TEL`, `SIRI`, `ALERT`, `ALT`, `HIGH`) |
| `WCP_INFO_FEATURES_OR`, `WCP_EV_SWAP`, `WCP_SCREEN_CLEAR_FLAGS`, `WCP_DEBUG_CF` | — | experiments / analysis |
| `WCP_EARLY` | off | old start order |

### wcppaird

`WCP_PAIRDIR`, `WCP_PAIRID` (identity), `WCP_NVAIRPLAY`, `WCP_VERIFY_TYPE` (pairing internals), `WCP_LIBLOG`.

---

## 12. Build

`build_all.bat` builds every component (AltScreenQ_patch, WCP.jar, `zipget`, libaaproxy, libcpproxy, maneuver_render, librgi_hook, RGI jar, vidbridge, `wcpbt`) and then the pack — use it, or run `create_tar.bat` after any single build, so the pack never falls behind the build. `wcpbt` is the same for 3638 and 5092 (one source, one set of binaries).

`build_wcp.bat` (QNX 6.5.0 SDP in `C:\QNX650`):

```
build_wcp.bat                      DEBUG_LOG=1 (default)
set DEBUG_LOG=0 & build_wcp.bat    release, no log code
```

Output in `build\qnx\`: `libwcpstart.so`, `libbthook.so`, `wcpd`, `wcppaird`; the script checks that `libbthook.so` imports no `__sync` helper (`ntoarmv7-objdump -T libbthook.so | grep -i sync` must print nothing). `wcpopus/libopus_wcp.a` is built first (`make` or `build_win.bat` in `wcpopus/`). A clean build is needed whenever `wcpplist.h` changes. librgi_hook: `build_lib.bat` in its tree. WCP.jar: `build.bat` in `wcp_hmi` (against the `*_final.jar` in `AltScreenQ_patch`).

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

**Firmware 5092** (same hardware; libbthook and libwcpstart pick the build at run time):

| Item | 3638 | 5092 |
| --- | --- | --- |
| `btstack` | SHA-256 `31290e21…` | SHA-256 `bd0068b7…` |
| Start-up check (startBtStack) | `0x11EFDC` `ldrb r3,[r5,#0x75C]` | `0x11ECD0` `ldrb r3,[r5,#0x764]` |
| EIR hook point | `0x12C990` | `0x12A710` |
| `RF_RegisterServerChannel` / `RF_DeregisterServerChannel` | `0x27C0BC` / `0x27C058` | `0x277B98` / `0x277B34` |
| `SDP_AddRecord` / `SDP_RemoveRecord` / EIR refresh | `0x20AE24` / `0x20ADA4` / `0x1DF0A8` | `0x2073C4` / `0x207344` / `0x1DB648` |
| `RF_RespondChannel` / `RF_CloseChannel` / `RF_SendData` / `RF_FrameSize` / `RF_AdvanceCredit` | `0x27B9E0` / `0x27BA9C` / `0x27B89C` / `0x27B718` / `0x27B800` | `0x2774BC` / `0x277578` / `0x277378` / `0x2771F4` / `0x2772DC` |
| `CMGR_RegisterHandler` / `CMGR_CreateDataLink` / `CMGR_GetRemoteDevice` | `0x247C2C` / `0x247BE4` / `0x246D28` | `0x2436F4` / `0x2436AC` / `0x2427F0` |
| `SDP_Query` / `SDP_ParseAttributes` / `RF_OpenClientChannel` | `0x1D4800` / `0x1D3E08` / `0x27BB68` | `0x1D0D88` / `0x1D0390` / `0x277644` |
| `ME_SendHciCommandAsync` | `0x1DF720` | `0x1DBCC0` |
| GOT: trace channels BTSERVICES / JOBS_STARTSERVICE, `bt` | `0x2C6134`, `0x2C6A94`, `0x2C619C` (`bt` = `0x2DA0EC`) | `0x2C112C`, `0x2C1A88`, `0x2C1194` (`bt` = `0x2D5104`) |
| `dio_manager` | cksum 2268931283, 606693 bytes | cksum 1446556070, 691203 bytes |
| vtable `CDIOManager` + 8 / slot of `onEvent_startAirPlay` | `0x191848` / slot 4 `0x191858` | `0x1A4848` / slot 5 `0x1A485C` |
| `onEvent_startAirPlay` / `CAirPlayMainThread` ctor / thread start | `0x150018` / `0x14D3EC` / `0x167D24` | `0x15AF40` / `0x158B10` / `0x176B9C` |
| operator new nothrow PLT / GOT `std::nothrow` / `"carplay0"` | `0x110EB0` / `0x1937A8` / `0x185634` | `0x1129C8` / `0x1A6BF0` / `0x19784C` |
| CDIOManager: AirPlay thread / HID byte / touchpad / screen block | `+0x1B0` / `+0x1BC` / `+0x1B4` / `+0x2C0` | `+0x168` / `+0x174` / `+0x16C` / `+0x224` |
| startup timer: vtable `CAirPlayMainThread` / GOT / handler | `0x191800` / `0x1937A0` / `0x148E0C` | `0x1A4818` / `0x1A6BE8` / `0x1546AC` |
| `libairplay.so` | AirPlay 210.81, 753372 bytes | AirPlay 210.81, 763420 bytes (jitter buffer `+0x5E8/+0x5F0/+0x601` unchanged) |
| iAP2 client start: `CDIOManager::iAP2Connect()` / service connect / config string / key / service offset | — (3638 connects by itself) | `0x155560` / `0x129468` / `0x12E104` / `10` / `CDIOManager+0xE8` |
| mdnsd restart in `initService` | `CSmartphoneLauncherService::initService` → `0x14BBB0` | `CSIService::initService` → `0x157230` |
| libairplay idle check (`ldr r2,[r4,#0x1ec]; ldr r3,[r4,#0x1e8]; cmp r3,r2; ldrne r2,[r4,#0x1f0]`) | `0x259D8` | `0x25F00` |
| libairplay `sessionDied` call / `AirPlayReceiverSessionStart` / `TearDown` | — / `0x24DF0` / `0x265B0` | `0x25FCC` / `0x25278` / `0x26B60` |
| TearDown call sites seen (5092) |  | `+0x30b14` (phone's TEARDOWN of streams), `+0x2ec4c` (session end after `sessionDied`) |