# Wireless CarPlay on MHI2Q QC — Project Status

**Unit:** MHI2Q QC (mmx2qc), rel/CLU7, Harman 2016, QNX 6.5.0 ARMv7 (APQ8064), firmware 3638 / MU0917 and 5092 (MHI2Q_ER_AUG22_P5092) — one set of wireless CarPlay binaries for both **Phone under test:** iPhone, iOS 27 **Goal:** native wireless CarPlay on a head unit that only ships wired CarPlay, keeping the stock CarPlay receiver (AirPlay 210.81 in `dio_manager`), the stock iAP2 client and the stock HMI. **Last update:** 2026-10-27 (end of day) — **firmware 5092 and 3638 initially tested.** 5092: wireless CarPlay running (screen, controls, iAP2 inside the session). Found and fixed today: Wi-Fi channel race (phone sent to the wrong channel), Bonjour (mdnsd) never started on 5092, the car's iAP2 client never started on 5092, session ending 30 s after the car takes the screen, crash-watch false alarms after a reboot, MMI Wi-Fi switch, HMI start-up delay; mods split into three parts; both source trees compared (`wcpbt` 1:1 for both firmwares).

---

## 1. Summary

| Area | State |
| --- | --- |
| **Firmware 3638 (MU0917)** | ✅ initially tested — the platform the project was built on; today's fixes still to run there (tree behind, see §6 "Both firmwares") |
| **Firmware 5092 (MHI2Q_ER_AUG22_P5092)** | ✅ initially tested — wireless session, screen, knob/touch, iAP2 inside the session, HMI bridge; same binaries as 3638 |
| Wi-Fi access point for CarPlay | ✅ verified |
| **Wi-Fi channel sent to the phone** | ✅ fixed and verified (5092) — the running access point's channel, not a config file read too early (finding 27) |
| **Bonjour (mdnsd) in a wireless session** | ✅ fixed and verified (5092) — `dio-up.sh` starts it when the firmware does not (finding 28) |
| **Car's iAP2 client in a wireless session on 5092** | ✅ fixed and verified — started by the hook, "session is up" 13 s after the connect job (finding 29) |
| Session while the car keeps the screen > 30 s | ⏳ fix built (keep-alive counted for the stock idle timer, finding 30), car test pending |
| Crash watch after a reboot | ⏳ fix built (finding 31), car test pending |
| MMI Wi-Fi switch off | ⏳ HMI switches the Wi-Fi on once after install (finding 32), car test pending |
| HMI start-up with CarPlay as last source | ✅ verified — no 20 s wait (`hmi_startup.json`, §6) |
| Bluetooth setup: discovery, iAP2, Wi-Fi handover, session start | ✅ verified — about 1 s from the HMI's offer to the running session |
| **Stock btstack + `libbthook.so`** (no patched binary) | ✅ verified — iAP2 channel, SDP records, CarPlay UUID in the advertisement |
| **Car-initiated iAP2** (cold boot, after a session, after pairing) | ✅ verified — the car opens iAP2 4 s after connecting the phone; retries while the phone or stack is busy |
| Pairing (Pair-Setup / Pair-Verify) and encrypted channels | ✅ verified |
| Main screen (1024×480), knob and touchpad | ✅ verified |
| HMI integration (device list, activation, context switch) | ✅ verified |
| Media audio, navigation prompts over music | ✅ verified — the short music drop just before each prompt is fixed (26 Oct) |
| Calls and Siri (Opus), microphone | ✅ verified — both directions, MMI volume knob active during calls |
| Instrument-cluster map stream | ✅ verified |
| **iAP2 inside the AirPlay session** (now playing, cover art, call lists, favourites, route guidance to the cluster, location, vehicle data) | ✅ verified — same transport as the factory MIB2+ |
| **Bluetooth released during CarPlay**, restored afterwards | ✅ verified — single audio route on the phone |
| Session stability | ✅ verified — dio_manager's 6 s startup timeout handled |
| **Disconnect / reconnect** (CarPlay off and on at the phone) | ✅ verified — with the first test phone and a second, newly paired iPhone (after fix #23) |
| Session drop when touching the controls after a few minutes | ✅ fixed (event-channel pump) — confirmed by a 2 h 30 min session without a drop |
| Recovery after a drop (stale gate, receiver not taking the session) | ✅ verified — a fresh `dio_manager` started on demand, CarPlay back \~14 s after the drop |
| **Phone leaving the Wi-Fi** detected | ✅ verified — Wi-Fi switched off: \~0.25 s (access point event); otherwise 5 s (keep-alive watchdog) |
| PHONE hard key in CarPlay | ✅ accepted as is — a second press opens CarPlay |
| MMI prompt "A password must be entered for this data transfer" | ✅ no longer appears |
| Logging (`DEBUG_LOG` build switch, markers `debug_wificp` and `debug_wificp_raw`) | ✅ in all components; raw dumps separate (they were >80 % of the hook log) |
| `dio_manager` on demand (no permanent instance; USB wins) | ✅ verified — wireless and USB, see "USB and wireless" below |
| **Car's Bluetooth address** for the identification | ✅ verified — libbthook asks the chip / takes the stack's copy (`2C:DC:AD:4C:64:0F` at 10 s); the old hard-coded `…64:CF` was wrong; no per-car setting |
| **Install / boot start: AltScreen.sh, option A** (pack prepared once in `/mnt/ota/altscreen`, boot only creates links; one pack for AltScreen/RGI and wireless CarPlay) | ✅ verified on the car — 31 links, start done in 0 s (3 s after boot; was 4 s). Boot to the first screen ≤ 15 s (was 20–25 s, sometimes 40 s), phone on Bluetooth at \~25 s, CarPlay ≤ 15 s later |
| Start of the wireless CarPlay daemons at boot | ✅ verified — from `AltScreen.sh start` and the btstack wrapper (lock: one start; waits for the MFi bus); nothing started by hand |
| **Long run** | ✅ verified — one CarPlay session of more than 2 h 30 min with music, navigation and controls: no drop, event channel clean (0 requests piling up) |

---

## 2. Architecture — the factory flow

The design follows what an iPhone log from a factory wireless unit (Audi MMI, Alpine MIB2+) shows. **Bluetooth** is used only to set up: the phone and `wcpd` run a short iAP2 session over an RFCOMM channel added to the stock Bluetooth stack, the phone receives the Wi-Fi credentials and is told to start CarPlay. **Wi-Fi** then carries the CarPlay session to the stock receiver in `dio_manager`. **Inside that session** the car's own iAP2 client (Cinemo, the same one used over USB) starts a second iAP2 session with the phone: its packets travel as `iAPSendMessage` commands on the AirPlay event channel (car → phone) and control channel (phone → car). Once that iAP2 session is identified, the phone drops its Bluetooth iAP2 link and the car releases Bluetooth (`disableBluetooth`), so calls and audio run only through CarPlay. When the session ends, `dio_manager` re-enables Bluetooth and exits; it is started again for the next session — by `wcpd` when an iPhone is on Bluetooth, by smartphone_integrator when one is on USB (as stock). Only one runs at a time, and USB wins.

| Component | Runs in | Role |
| --- | --- | --- |
| `libbthook.so` (preloaded into the stock btstack by the `btstack` wrapper) | Bluetooth stack | RFCOMM channel for iAP2, iAP2 and CarPlay SDP records (the CarPlay UUID then appears in the advertisement by itself); bridges the channel to `wcpd` (`127.0.0.1:57342`); opens iAP2 from the car when the car connected the phone. The wrapper also starts `wcp-boot.sh` once per boot. (`btstack.graft` remains as fallback.) |
| `wcpd` | own daemon | Bluetooth iAP2: MFi authentication, identification, Wi-Fi credentials (AP config read when it appears), `CarPlayStartSession` once the receiver listens (`/tmp/wcp_go`); starts `dio_manager` on demand (`dio-up.sh`) and offers CarPlay to the HMI (`/tmp/wcp_session`) once it is ready, never during USB CarPlay; offers again if no receiver comes up within 20 s, never re-offers during a running session; closes the Bluetooth iAP2 link if the phone keeps it open 8 s into a session; follows the access point's station events (`sloginfo -w`) and flags a phone that leaves the Wi-Fi (`/tmp/wcp_phone_gone`) |
| `wcppaird` | own daemon | receiver identity (Ed25519), Pair-Setup / Pair-Verify, MFi coprocessor |
| `libwcpstart.so` | preloaded into `dio_manager` | encryption of all channels, stream and audio adaptation (relay, decoding, pacing), the in-session iAP2 channel for the stock iAP2 client, the event-channel request queue, the startup-timeout redirect, the `/tmp/wcp_go` gate, the phone watchdog, diagnostics |
| `librgi_hook.so` (wcp module) | `dio_manager` | adds the wireless-CarPlay parts to the stock Identify, answers the phone's Wi-Fi request; inside the session it never sends a second `CarPlayStartSession` |
| `AltScreenQ_wcp.jar` | HMI | virtual CarPlay device (ID 200) in the device list, session states `AVAILABLE` / `CONNECTED` / `STARTED` / `DISCONNECTED` |
| `wcp-boot.sh` (`wcp-test4.sh` for tests) | shell | starts `wcppaird` and `wcpd` (settings in `wcp.conf`); no `dio_manager` |
| `dio-up.sh` + insert in the `dio_manager` wrapper | shell | wireless `dio_manager` on demand; the wrapper records `usb`/`wireless` in `/tmp/wcp_dio_mode` and stops a wireless instance when smartphone_integrator starts one for USB |

---

## 3. A session in the logs

| Step | Typical time | Evidence |
| --- | --- | --- |
| Phone connects over Bluetooth, iAP2 authenticated and identified | 0 → 3 s | `wcpd.log`: `authentication SUCCEEDED`, `identification ACCEPTED` |
| Wi-Fi credentials sent, CarPlay offered to the HMI | +3 s | `sent Wi-Fi credentials`, `session status: AVAILABLE` |
| HMI starts the receiver, phone told to start | +0.4–0.6 s | `gate /tmp/wcp_go present`, `sent CarPlayStartSession` |
| Phone joins Wi-Fi, session encrypted, screen up | +4–5 s | `MICRO_AP_EV_ID_STA_ASSOC`, `control channel encrypted`, bridge `STARTED` |
| Stock iAP2 client starts inside the session | +1 s | `iAP2 over AirPlay … iAP2 detect`, `control msg 0x1D02` (accepted), `0xAA05` (authenticated) |
| Startup timeout of `dio_manager` skipped | +6 s | `session startup timeout IGNORED (#1)` |
| Bluetooth released | immediately | `handleSessionControl … disconnection from BT stack`, `updateMode … CARPLAY`; phone drops Bluetooth iAP2 \~13 s after the start (`phone link down`) |
| CarPlay switched off at the phone | — | phone sends `0x4E0D … 00`; `dio_manager`: `exitProcessCallback`, `enableHUBluetoothInterface: Enable 1`, exits; watcher restarts it |

---

## 4. Findings that shaped the session design

| # | Finding | Consequence |
| --- | --- | --- |
| 1 | On the factory MIB2+ the iPhone runs a second iAP2 connection with transport *AirPlay*; message sizes in its log match `{type: iAPSendMessage, params: {data}}` byte for byte (detect 6 → 94 bytes, ACK 9 → 97). The car starts it with the iAP2 detect right after the session comes up. | The hook gives the stock iAP2 client a channel inside the session and carries its packets as `iAPSendMessage`, one per iAP2 packet. |
| 2 | The stock receiver (210.81) knows no `iAPSendMessage`. | The hook answers the phone's commands itself (`200`, stock-style empty body) and never passes them on. |
| 3 | Replies on the event channel carry no CSeq; only their order identifies them. | The stock code's requests and ours are queued in wire order; replies to ours are taken out before the stock code reads the channel. |
| 4 | With iAP2 kept on Bluetooth, the car's Bluetooth phone stayed connected next to CarPlay: two audio routes on the phone, silent call downlink, dead volume knob. | iAP2 moved into the session; `disableBluetooth` goes to the stock code as on the factory unit. |
| 5 | When its iAP2 client connects, `dio_manager` arms a 6 s session-startup timer that only the session start stops. Over Wi-Fi the session starts first, so the timer later ended running sessions. Its code is mapped from flash and cannot be patched. | The timer's callback is taken from `dio_manager`'s GOT; that entry points to the hook, which ignores the timeout while a session with iAP2 inside runs and otherwise calls the stock handler. |
| 6 | `dio_manager` ends itself after every session and re-enables Bluetooth. Over USB, Smartphone Integration starts it again for the next phone. | A watcher restarts it in wireless mode; it is ready before the phone is back on Bluetooth. |
| 7 | After a session the phone ends itself, the receiver may keep listening. | The `/tmp/wcp_go` gate follows the listening socket, not the session. |
| 8 | During a session the iPhone sends a keep-alive on the control channel every \~2 s; the access point driver logs a station leaving at once. | Session ended after 5 s without traffic, or within \~0.25 s of the phone's Wi-Fi logging off. |
| 9 | The Bluetooth iAP2 link keeps the Bluetooth connection busy; the Bluetooth app waits for it before releasing the phone. | The phone normally drops it itself (\~13 s); `wcpd` closes it 8 s into a session if it has not. |
| 10 | btstack's code, like dio_manager's, is mapped from flash and cannot be written at runtime (`mprotect` and `/proc/self/as` refuse, even for a RAM copy). | `libbthook` uses only library calls btstack makes: its trace channel marks the start-up point (the Device-ID message), the advertisement passes through `MsgSendv` to the SDIO chip. |
| 11 | qcc's gcc 4.4 emits a call to `__sync_lock_test_and_set_4` for the atomic exchange on ARM; QNX libc has none, so the runtime linker ends btstack at the first call (core: `exit()` from lazy binding, then an abort in btstack's destructors). | `ldrex`/`strex` with `dmb` in libbthook; the build checks that no `__sync` import is left. |
| 12 | btstack builds its advertisement from the registered SDP records, so the CarPlay record already puts the CarPlay UUID into it. | The advertisement hook only verifies it (logged as `PRESENT`). |
| 13 | The iPhone opens iAP2 only when it made the Bluetooth connection itself; when the car connects (every cold boot, after pairing) it waits for the car. | `libbthook` sees the car's connections in btstack's trace (`ACL to <addr> established` / `already connected …`) and opens iAP2 to the phone after 4 s. |
| 14 | Right after pairing the phone does not answer the channel while its pairing screens are up, and the stack refuses for a moment (`0x13`) while it connects its own profiles. | Unanswered opens are cancelled after 12 s; busy or unanswered attempts are retried 5 s later (3 times); only "no iAP2 service" blocks an address (30 s). |
| 15 | At a cold boot `wcpd` can start before the access point has written its configuration. | The configuration is read again every 2 s and when the phone asks for the credentials. |
| 16 | The stock receiver reads the event channel only while it waits for the reply to one of its own requests. The phone's replies to our iAP2 messages (`iAPSendMessage`) therefore piled up and were taken out \~16 s late; the 64-entry reply queue overflowed and replies reached the wrong owner. On the next touch (`hidSendReport`) the stock code got those replies, closed the event channel, and the phone ended the session (phone log: connection to port 5001 closed, reason -72320). | Event-channel pump in the hook: whenever a stock thread waits in `select()` without the event socket, the hook adds it and reads it itself (our replies consumed at once, the stock's kept and reported readable when it waits); one reader at a time; queue 256. `WCP_NO_EV_PUMP=1` switches it off. |
| 17 | A gate file outlives a dead `dio_manager` (process exit closes no sockets through the hook), so `CarPlayStartSession` was sent with no receiver. | The gate carries the pid; `wcpd` ignores and removes a stale one; `dio-up.sh` clears it; if the receiver takes no session within 25 s of StartSession, the wireless `dio_manager` is restarted. |
| 18 | QNX's ksh has predefined aliases (`stop='kill -STOP'`) that hit `stop() {`; an empty `LD_PRELOAD=` keeps programs from starting; `/tmp` (`/dev/shmem`) has no directories. | Prefixed shell functions, `unset LD_PRELOAD`, previous logs kept as `/tmp/prev_*`. |
| 19 | The car's Bluetooth address in the identification was a hard-coded `2C:DC:AD:4C:64:CF`; the real one (iPhone log, stock Bluetooth service, the chip) is `2C:DC:AD:4C:64:0F`. The stack keeps it at `bt+0x1B4C` (`bt` = 0x2DA0EC), filled at a varying time (10 s or \~41 s). | libbthook sends HCI `Read_BD_ADDR` through the stack's `ME_SendHciCommandAsync` with a token of its own (reply at token `+0x38`: `01 09 10 00` + address), else takes the stack's copy; writes `/tmp/wcp_btmac`; `wcpd` and the `wcp` module read it. `BTMAC` in `wcp.conf` only as an override. |
| 20 | `rename()` of a temp file in `/tmp` (`/dev/shmem`) failed silently on the car. | State files in `/tmp` are written in place with one write. |
| 21 | `AltScreen.sh start` (4 s: unpack 2.3 MB, copy 2 MB of stock binaries, directory scan) ran before the stock service manager, delaying every service. | Option A: unpack and stock copies once at install into `/mnt/ota/altscreen/root` (stock copies as `stock/<name>`, so process names stay stock; reused while unchanged; refreshed if the firmware brings a newer one); boot only links (`links.txt`). Wireless CarPlay files live in the same tree and are linked file by file into `/mnt/ota/wcp`, which keeps only data (`pair/`, `wcp.conf`, markers, logs). |
| 22 | Music dropped briefly just before every navigation prompt, then lowered as expected. The stock's music buffer ran empty (`Main: Re-buffering: 0 ms buffered`) because its audio receive thread, which reads all audio sockets, was blocked \~390 ms: on its first read of the new prompt socket our hook fetched the stream keys from `wcppaird` in that thread (\~195 ms each). Earlier the relay also held its lock during the same fetch, so the music pacer stopped sending for \~400 ms. | Stream keys fetched once, at the SETUP, outside any lock and outside the stock's threads, and kept in a cache. Since then no re-buffering at prompts. The 500 ms prompt lead-in (a workaround for the same wait) is discarded by the stock now and is off by default. RTP sequence to the stock starts at 1. |
| 23 | A newly paired iPhone connected and disconnected every \~20–30 s (after its first session). Each session ended right after the phone's iAP2 inside the session started sending its list updates (call history / favourites, `0x4171`): the hook logged `request too large` and dropped the control connection, the stock code saw `ECONNRESET`. One `iAPSendMessage` carries one whole iAP2 packet — up to 65 535 bytes plus plist and header — and the hook's request buffer was 64 KB. The first test phone's lists are short enough. (The first suspects, the Bluetooth link closing at 8 s and the phone's `disableBluetooth`, only happened at the same moment.) | Request buffer 512 KB; reproduced on the host with a 65 535-byte iAP2 packet (fails with 64 KB, passes now). Kept from the investigation: `wcpd` closes a still-open Bluetooth iAP2 link only 5 s after the iAP2 inside the session is authenticated; holding `disableBluetooth` until then is available as `WCP_HOLD_DISABLE_BT=1` (default: passed at once, as before). |
| 24 | After a clean-up of `/mnt/ota/wcp` the phones connected over Wi-Fi, passed pair-verify, then sent nothing (no SETUP); CarPlay never came. The pairing folder `/mnt/ota/wcp/pair` had been lost with the clean-up: `wcppaird` created a new car identity at the next boot (pi `A229FAB4…` → `B8687833…`), which the phones did not match with the car they knew. | Each phone: Forget This Car (+ Bluetooth), pair again → CarPlay \< 40 s after boot with both phones again. **If `pair/` is ever deleted, every phone must be re-paired.** Never delete it; back it up after pairing a new Apple ID (`tar -czf /mnt/ota/wcp_pair_backup.tgz -C /mnt/ota/wcp pair`). Phones on the same Apple ID share one `peer-…` file. |
| 25 | A second session in the same `dio_manager` (after one ended by the phone watchdog) was ended 0.16 s after it started ("phone silent for 92915 ms"): the watchdog read the last-packet time before its 250 ms sleep and told sessions apart by fd number, which the new session reused. | Watchdog: a session counter, each session counts from when it is first seen, last-packet time read after the sleep. Reproduced and fixed on the host. |
| 26 | The Apple vendor element in `start-ap.sh` was a fixed string with the car Bluetooth MAC `…64:CF` (from early bring-up); libbthook reads the real address `2C:DC:AD:4C:64:0F` from the chip. CarPlay worked anyway, but the element only ever fitted one car. | `start-ap.sh` builds the element at every AP start: Bluetooth MAC from `BTMAC` in `wcp.conf`, else `/tmp/wcp_btmac`, else `/mnt/ota/wcp/btmac.last`; AP MAC from `uaputl sys_cfg_ap_mac_address`, else `ifconfig uap0`. `wcp-boot.sh` saves the address libbthook found (\~10 s, after the first AP start) and installs the element again when it is new or changed. `WCP_APPLE_IE=off` / a fixed `0xdd18…` in `wcp.conf` override. Host-tested; car: check `Apple element:` in `/tmp/start-ap.log`. |
| 27 | The phone never joined the car's Wi-Fi (0 stations; `no CarPlay session 25 s after CarPlayStartSession - the phone is not on the Wi-Fi`). `wcpd` had read the access point configuration once, at 10.3 s, while `start-ap.sh` (started at 10 s) was still writing `/tmp/uaputl_wcp.cfg` (`Channel=6,0`): it took the stock `/tmp/uaputl.cfg` (`Channel=11`) and sent the phone channel 11, while the access point ran on 6 (`uaputl sys_config`: `Channel = 6`, 20 MHz). Earlier runs read it a moment later and got 6. A timing race on both firmwares. | `wcpd` reads the configuration again for every credentials request (`0x5702`) and sends the channel the running access point reports (`uaputl sys_config`); a difference is logged (`access point runs on channel 6 (config said 11)`). `start-ap.sh` keeps a `WCP_CHANNEL` from `wcp.conf` (it was overwritten). Verified on 5092: phone on the Wi-Fi at 12.7 s. |
| 28 | `dio_manager` starts mdnsd (Bonjour) in `initService()`, which smartphone_integrator calls for a USB phone (3638 `CSmartphoneLauncherService::initService`, 5092 `CSIService::initService` → `restartMdnsd`). On 5092 a wireless `dio_manager` never gets it: no mdnsd, `DNSServiceRegister -65563` (service not running), the stock retrying every \~11 s. | `dio-up.sh` starts mdnsd as `dio_manager` would (`/etc/scripts/mdnsd.sh`, `MDNS_DIRECTLINK_IFACE=uap0`, probe count 0, pid file) when none runs; a later `initService()` replaces it through the pid file. `WCP_MDNSD=0` = off. Verified on 5092: `DNSServiceRegister(_airplay._tcp.) -> 0`. The advertised model is `AUDI 4260` when `initService()` ran, `AirPlayGeneric1,1` otherwise. |
| 29 | On 5092 the phone tore every session down right after RECORD: no iAP2 inside the session. The car's iAP2 client (Cinemo, files identical to 3638) is connected by 5092's `dio_manager` only from `CSIService::setupService` → `CDIOManager::iAP2Connect()` (`0x155560`), i.e. for a USB iPhone; 3638 connects it by itself (MCD insert → `initService`). In a wireless 5092 `dio_manager`, `iAP2Connect()` returns 0 (no `CSIService`). | libwcpstart does `iAP2Connect()`'s remaining work itself: reads `iap2.device` from `dio_manager.json` (config key 10, `0x12E104`) and posts the connect job on the iAP2 service (`CDIOManager+0xE8`, `0x129468`) — build-table entries for 5092, zero for 3638. Called when the receiver starts listening, no second job within 30 s. Verified: Cinemo reads the auth chip and opens `/dev/otg-cinemo` 13 s later, `session is up`, Identify accepted, all `iAPSendMessage` answered. `WCP_IAP_DIRECT=0` = off. |
| 30 | A session ended 30.2 s after the car took the screen (`changeModes`, "user action"): the phone closed its screen stream and from then on sent only its UDP keep-alive beacons (every 10 s, to the `keepAlivePort` we add). Stock 210.81 has no keep-alive receiver; its session idle timer compares rxCount / activityCount (session `+0x1e8` / `+0x1f0`), saw nothing and sent `sessionDied`. Same code in the 3638 and 5092 stock `libairplay.so`. | Each beacon adds 1 to activityCount, as any stock activity would. The session is held with `CFRetain` from `AirPlayReceiverSessionStart` until a whole-session TearDown or the control connection closing. Only where the idle-check code is the verified one; `WCP_KA_ACTIVITY=0` = off. Car test pending. |
| 31 | The crash watch counted the same old core file as a new crash at every 10 s poll: it compared file times with a stamp made at its start, and the clock starts at 1 Jan 1970 00:00 at every boot, so an empty `dio_manager.core.gz` from an earlier boot ("00:04") looked newer. Result on 5092: "dio_usb crashed twice" (14 s, 25 s) → RGI and cluster video off (wireless `dio_manager` with `RGI_MODULES=wcp`, cluster empty), "dio_wireless crashed twice" (35 s, 45 s) → no further wireless session. Nothing had crashed (`rgi_dio.log`: one `dio_manager` start). | The watch takes a snapshot of the core files (name, size, time) at its start; a crash is a file that is new or changed afterwards, counted once it stops changing and once per program per poll. Simulated: old file not counted, a core written over two polls counted once. Car test pending. |
| 32 | The MMI's Wi-Fi switch (`DSIWLAN.setRFActive(false)`) is kept by connectionmanager; with it off the access point never starts and wireless CarPlay cannot work. | `WlanAutoOn` in WCP.jar: with `/mnt/ota/app/wcp_wifi_on` (written by `AltScreen.sh install` when the wireless part is installed) the HMI sets role access point and radio on at its next start, as the MMI's Wi-Fi menu does; empty file = once (removed after success), `always` = every start. Log: `/tmp/wcp_hmi.log`. Car test pending. |
| 33 | 5092's `DSISmartphoneIntegration` has one more method (`requestAppConnectContextActive`); a bridge class implementing the 3638 interface does not compile against 5092. | `WirelessCarPlayBridge` filters SI's DSI with a dynamic proxy (only `connectDevice` / `disconnectDevice` for device 200 are taken); one source for both. Verified on 5092: device 200 listed, `connectDevice(200)`, `STARTED`. |
| 34 | Twice a car test ran old code: the build was redone but the pack was not (`AltScreen.tar.gz` older than `build/qnx`). | `build_all.bat` builds every component, including WCP.jar and `zipget`, then the pack; check the pack on the car before testing (§7). |

### Audio findings (unchanged)

| # | Finding | Consequence |
| --- | --- | --- |
| A1 | Over Wi-Fi, iOS accepts an audio type only if a compressed format is offered; PCM-only lists fail. | Opus advertised next to PCM for voice types. |
| A2 | iOS requires stream type 102 (Wi-Fi media) with AAC-LC stereo; stock 210 has no 102 and no AAC decoder. | 102 is shown to the stock code as type 100 PCM; the car decodes AAC itself (Cinemo codec). |
| A3 | Stock 210 rejects Wi-Fi stream keys (`streamConnectionID`, `controlPort`, `spf`) and takes the first object of a binary plist as its root; the phone needs a `controlPort` in the SETUP reply. | Keys hidden from the stock code, plist writer emits the root first, `controlPort` added (points to the relay). |
| A4 | The stock audio socket is fixed at UDP 7070 (the only open audio port); Wi-Fi packets exceed its 1472-byte buffer. | Stock socket moved to 7072, the relay owns 7070 and re-frames into packets of ≤ 1440 bytes. |
| A5 | The phone sends media in bursts; the default UDP buffer dropped \~40 % of packets. | Relay socket buffer 768 KB (`kern.sbmax` 1 MB), relay thread priority 21, decoded audio queued and paced. |
| A6 | Telephony, Siri and alerts use Opus 16 kHz mono; the microphone goes to a port named in the call SETUP. | Fixed-point Opus decoder/encoder on the car; microphone sent where the stock code addresses it. |
| A7 | The stock code reuses one audio socket for every main-audio stream. | A new SETUP replaces the previous stream's relay entry and keys. |
| A8 | The stock jitter buffer holds 55 packets (403 ms) and its audio thread pauses \~360 ms at a prompt start. | The music pacer follows the stock play position (`RTPJitterBufferRead`) and stays 150 ms ahead; drift corrected 1 ms at a time. |
| A9 | The prompt channel opens \~500 ms after the prompt stream starts. | 500 ms of silence before each prompt. |

---

## 5. Verified

On the car, with car logs (`wcpd.log`, `wcphook.log`, `dio_trace.log`, `sloginfo`) and iPhone logs:

| Item | Evidence |
| --- | --- |
| iAP2 inside the session | detect, link SYN/ACK, Identify accepted, authentication passed over `iAPSendMessage`; call lists `recents=12 favorites=3`, cover art saved, now playing, location `0xFFFA/0xFFFB`, RGI `0x5200` |
| Stock reply handling | host test: stock code receives only its own event replies and none of the phone's `iAPSendMessage` requests |
| Startup timeout | `session startup timer now goes through the hook (GOT 0x1937a0)`, `IGNORED (#1)`, session stays |
| Bluetooth release | `updateMode … CARPLAY successfully updated`, Bluetooth gone on the MMI, single route on the phone |
| Call, phone → car | relay level 22 000–26 000; stock reads 48 128 frames per 3 s with full-scale level; HMI `TELEPHONY` ACK in 168 ms |
| Call, car → phone | 992 microphone packets to the phone, peak 9 090 |
| Reconnect | three cycles in a row: receiver up 0.4–0.6 s after the offer each time |
| Phone gone | watchdog `phone silent for 5015 ms`; access point `STA_DEAUTH` logged immediately on Wi-Fi off; host test: session ended 0.21 s after the flag |
| Stock btstack + libbthook | `active without code changes`, `stack start-up reached the graft's hook point`, RFCOMM channel 4 + both records; advertisement `CarPlay UUID PRESENT`; btstack keeps its pid |
| Car-initiated iAP2 | cold boot: car connects the phone 37 s, iAP2 opened 41 s, CarPlay without touching the phone; after Wi-Fi off/on: again within 6 s of the reconnect; fresh pairing: CarPlay offered \~4 s after pairing |
| Logging scheme | release builds without log strings or diagnostic interposers; host tests: no log without the marker, log once it exists; raw dumps only with `debug_wificp_raw` (4.5 KB instead of 40 KB per test session) |
| Event-channel pump | `event pump: reading the event channel while the stock code does not`, 0 requests piling up (768 in the drop run) |
| Car's Bluetooth address | `/tmp/wcp_btmac` = `2C:DC:AD:4C:64:0F` at 10.1 s; `wcpd`: `car Bluetooth address … (from the stack)` in the identification |
| Earlier results still valid | screen, controls, media audio, prompts over music, music ↔ call switching, cluster map |
| **5092: Wi-Fi join** | `sent Wi-Fi credentials (… channel 6)`, `AP: station 66:42:b4:… joined the Wi-Fi` at 12.7 s |
| **5092: Bonjour** | `dio-up: mdnsd was not running - started`, `Bonjour: DNSServiceRegister(_airplay._tcp.) -> 0` |
| **5092: session** | `control channel encrypted`, `STARTED` 1.5–2 s after the connection, `showUI`, knob and touch (`hidSendReport`), sessions of several minutes, a second session in the same boot |
| **5092: iAP2 inside the session** | `iAP2 direct connect: "iap://ffs:///dev/otg-cinemo" -> job …`, `iAP2 client opened its device 13 s after the connect job`, `session is up`; Identify patched by the `wcp` module and accepted (`0x1D02`), authentication (`0xAA05`), 46 / 54 packets, every `iAPSendMessage` answered |
| **5092: HMI bridge** | `/tmp/wcp_hmi.log`: SI DSI proxy wrapped, device 200 `AVAILABLE` → `connectDevice(200)` → `STARTED` |
| **5092: Bluetooth** | `libbthook`: `5092 btstack bd0068b7: active without code changes`, car-initiated iAP2, authentication and identification in `wcpd` |

---

## 6. What is left

| Item | Notes |
| --- | --- |
| **Install with the new AltScreen.sh** | ✅ installed and verified (31 links, start in 0 s). Left: delete the old real files in `/mnt/ota/wcp` that the pack now provides as links or no longer needs (`btstack`, `libopus_wcp.a`, `wcp-test.sh`…`wcp-test3.sh`, `drop.tar`), if not done yet. |
| **Cluster map blink at route start / end** (iOS 26 iPhone) | The phone redraws the whole cluster picture on every scene change (`showUI`); the scene was switched at every route start and \~5 s after every route end. Fix (RGI jar + libcpproxy, built against the v2.2 tree): the scene follows the menu "Route Guidance on Cluster" for the whole session, and the cluster's `initialURL` in /info matches the last scene (`/tmp/cpproxy_scene`). Compile- and host-tested; **car test pending** (both phones: route start / end, menu toggle, session start). |
| Flash | ✅ stock — the btstack wrapper is linked by the overlay only |
| Boot time | ✅ done: ≤ 15 s to the first screen with all mods (stock \~16 s). Optional: shorter wait (1 s) before the car opens iAP2 for a known iPhone; early connect at stack start behind a marker. |
| USB and wireless (behaviour, 26 Oct) | ✅ **Phone in wireless CarPlay, USB plugged in:** the phone charges, CarPlay stays wireless (the car starts USB CarPlay, it ends again after \~8 s while the car's Bluetooth iAP2 is open; the wireless session comes back). **Phone's Bluetooth and Wi-Fi off, USB plugged in:** USB CarPlay. **USB unplugged:** wireless CarPlay resumes by itself — libbthook opens iAP2 3 s after the USB session ended (`bthook_nousbresume` switches that off). Option if USB should always win: no car-initiated iAP2 while a USB session runs. Still to test: a USB-only phone with no wireless. |
| Firewall | ✅ pf stays enabled. The CarPlay ports on `uap0` are passed by a block inserted above the stock `block in quick on $wlan_if from any to ($wlan_if)`, in `pf.conf`, `pf.ecm0.conf`, `pf.mlan0.conf` (verified on the car) and `pf.ppp0.conf` (the mobile-data rule set; `pfctl` can only check it while `ppp0` is up, so it is accepted when the unchanged file fails the same way). Part of `AltScreen.sh fixfw` / `install` / `checkfw`. |
| HMI bridge | ✅ the logging scheme (`DEBUG_LOG` constant + marker) is in `WirelessCarPlayBridge` of the v2.2 tree (AltScreenQ_patch). |
| Microphone quality | Raised to 32 kbit/s, complexity 8 (was 24 kbit/s, 5); the slowest encode per 500 packets is logged. `WCP_MIC_BITRATE` / `WCP_MIC_COMPLEXITY` set other values (old: 24000 / 5). Car test pending (a call: voice at the other end, CPU). |
| Session recovery (25 s) | Now depends on the access point: `wcpd` tracks the stations on the car's Wi-Fi (`uaputl sta_list` + STA_ASSOC / DEAUTH events). Phone not on the Wi-Fi → no `dio_manager` restart, it waits; phone joined late → the 25 s count from the moment it joined; state unknown → as before. Car test pending (e.g. phone Wi-Fi off, phone locked at the first connection). |
| Crash watch | `AltScreen.sh` follows the dumper's core files (`/mnt/ota/system/core`): two crashes of btstack, dio_manager (USB / wireless separately), gal, maneuver_render or altscreen_present within 10 min → our part in it off until reboot (its existing `/tmp` off switch); `j9` (HMI) → `.sf_disable` + overlay stopped at once. Host-tested; car test pending (`AltScreen.sh check` shows it running). |
| start-ap.sh | In the pack now (linked over `/eso/telephone/start-ap.sh`); the stock script goes back on flash. |
| Alerts on type 100 | Only Opus 48 kHz **mono** is offered as compressed format for `alert`/`default` (not seen in use); AAC-LC stereo could be added. |
| `IPOD_AP2_PPSSERVICE` | `enqueueSingleMessage failed … thread not available` at every connect; check whether the MMI's own media screens and the cluster show titles outside CarPlay. |
| One-off | Once, on the first connection of a run, CarPlay ended together with Bluetooth; starting it from the MMI worked, not reproduced since. Capture the hook and `dio_manager` trace if it recurs. |
| Bluetooth app | Crashed once earlier (NULL string in its OBEX authentication handling) after a session drop; reproduce and guard. |
| Cosmetic | The HMI shows the phone twice during start-up (Bluetooth phase, then session phase). |
| Release build | Once stable: `set DEBUG_LOG=0` in `build_wcp.bat` (no log code at all). |
| **Slow boot when the MMI slept on CarPlay** (5092, 27 Oct) | First screen at 35.8 s instead of \~16 s: the HMI's startup config (`hmi_startup.json`, inside its jar) makes the `TerminalMode` component wait synchronously for the media domain at `0x0D00`; with CarPlay as the last audio source this is on the path to the first screen, the media domain reaches it only at \~54 s, so the start waits the full 20 s (`startup.max.domain.wait`) while holding the domain lock, then continues anyway. Fix: a copy of the stock file with that one dependency `\"start_asynchron\": true` (as the stock file already does for six others), at `/mnt/app/eso/hmi/lsd/hmi_startup.json` - the path stock `lsd.sh` already checks first (`-Dipl.config.dir.hmi_startup=$BASE_DIR/lsd`). **Confirmed on the car 27 Oct.** `AltScreen.sh` makes it on the unit from the firmware's own `/ifs/lsd.jxe/resources/hmi_startup.json` (at install/prepare, and again at start whenever that file's cksum changed, e.g. after a firmware update), only if the stock file looks exactly as expected (TerminalMode's `0x0D00` found once, not yet asynchronous); linked like the pack files, so flash stays stock and `.sf_disable` / uninstall revert it; no copy in the packs; off: `hmi_startup_off`. Host-tested (identical to the verified file, firmware change, LF-only file, already asynchronous, missing source, off switch). |
| **First session after a fresh pairing drops once** (5092 unit, 27 Oct) | Session ran 90 s, then the hook's watchdog ended it: "phone silent for 5136 ms"; before that three `iAPSendMessage` requests went \~4 s without a reply. The access point shows the phone associated the whole time (one STA_ASSOC, no DEAUTH), no crash cores, the second session is fine. Diagnostics added: at a silence the hook logs per connection the last bytes / last frame, bytes waiting unread (FIONREAD) and not yet acked, keep-alive and audio times, and whether the phone is on the Wi-Fi; wcpd adds `uaputl sta_list` ("AP snapshot"). Behaviour: any bytes from the phone count (screen data did not); unread data waiting = receiver behind, session kept; phone still on the Wi-Fi = up to `WCP_PHONE_TIMEOUT_WIFI_MS` (15 s) instead of 5 s, "the phone is back after N ms" when it resumes. Also fixed: `pi -` in StartSession when `pair/pairid` was created after wcpd started (fresh unit). Host-tested; car test pending. |
| **Session ends 30 s after the car takes the screen** (27 Oct, 5092; same code in 3638) | Finding 30. Test: CarPlay running without music, take the screen with a car button for \~1 min, back to CarPlay; `wcp-logcheck.sh` section "stock idle timer", no `sessionDied`. Details: car `changeModes` ("user action", screen) -> phone TEARDOWN of the screen stream -> from then on only UDP keep-alive beacons every 10 s (to our keepAlivePort). Stock 210.81 has no keep-alive receiver: its session idle timer (rxCount / activityCount at session+0x1e8 / +0x1f0, verified identical in the 5092 and 3638 stock libairplay) saw nothing and sent `sessionDied` 30.2 s later. Fix (wcphook.c): each beacon adds 1 to activityCount; the session is held with CFRetain from `AirPlayReceiverSessionStart` until a whole-session TearDown or the control connection closing (a stream TearDown's "done" only means no stream is left). Only where the idle-check code matches; `WCP_KA_ACTIVITY=0` = off. Car test pending. |
| **Both firmwares, one `wcpbt`** (27 Oct) | The two source trees compared file by file: `wcpbt` has no firmware-specific difference. The only firmware data are the build tables — `bthook.c` `builds[]` (btstack `31290e21` / `bd0068b7`), the `dio_manager` table in `wcpstart.c` (cksum `2268931283` / `1446556070`, the iAP2 connect fields 0 for 3638) and the two idle-check places in `wcphook.c` — and each picks its entry at run time; an unknown build is left stock. Same in both trees: `rgi_hook_Q`, `libcpproxy`, `libaaproxy`, `vidbridge`, `maneuver_render_HQ`, `wcp_runtime`, `manifest_alt` / `manifest_wcp`, `create_tar.ps1`. **5092 tree: current. 3638 tree: behind** — `wcphook.c`, `wcpstart.c`, `dio-up.sh`, `start-ap.sh`, `wcp-logcheck.sh`, `AltScreen.sh`, `wcp_hmi` older; `build/qnx` and both packs from the morning; an old `WirelessCarPlayBridge` left in `AltScreenQ_patch/src` (puts a second, older bridge into AltScreen.jar next to WCP.jar's); `upload.bat` uploads a file that does not exist and not `wcp.tar.gz`. `sync_3638.zip` (5092-tree files + delete list) makes `wcpbt` identical (checked). Next: `build_all.bat` on 3638 and a regression run there (session; car takes the screen > 1 min). Per firmware by design: `AltScreenQ_patch`, `rgi_java_Q`, `manifest_rgi.txt`, the `rgi_java_Q` argument in `build_all.bat`. Feature differences to decide: `CallStateTapModule` only in 3638's RGI.jar, `AaClusterTheme` only in 5092's AltScreen.jar. Option: keep `wcpbt` once, shared by both trees (like vidbridge). |
| **MMI Wi-Fi switch** (27 Oct) | Finding 32: `WlanAutoOn` (WCP.jar) + `/mnt/ota/app/wcp_wifi_on` from `install`. WCP.jar built against 3638; car test pending (switch the Wi-Fi off in the MMI, reboot: `Wi-Fi: radio switched on` in `/tmp/wcp_hmi.log`). |
| **Crash watch false alarms after a reboot** (27 Oct, 5092) | The crash watch compared core file times with a stamp made at its start. The clock starts at 1 Jan 1970 00:00 at every boot, so an (empty) `dio_manager.core.gz` from an earlier boot with time "00:04" was newer than the stamp and counted again at every 10 s poll: "dio_usb crashed twice" (14 s, 25 s) -> `/tmp/rgd_disable` + `/tmp/cpproxy_disable` (wireless dio_manager ran with `RGI_MODULES=wcp`, cluster empty), "dio_wireless crashed twice" (35 s, 45 s) -> `/tmp/wcp_dio_off`. Nothing had crashed. Fix: snapshot of the core files (name, size, time) at the start; a crash is a file that is new or changed afterwards, counted once it stops changing, once per program per poll. Simulated: stale file not counted, file written over two polls counted once. |
| **Three parts, two packs** (27 Oct) | `create_tar.bat` makes one `AltScreen.tar.gz` with all three parts by default (`both` = two packs as below). `wcp.tar.gz` = RGI + wireless (RGI arrow over the stock cluster map, no phone map in the cluster); `AltScreen.tar.gz` = AltScreen + RGI; both = everything. Manifests `manifest_alt` / `_rgi` / `_wcp`; switches `altscreen_off` / `rgi_off` / `wcp_off`; `/tmp/.sf_features` = `v3 <parts>`. Without AltScreen: `GALHandler.isSmartphoneClusterEnabled()` false (new `SfParts`), "Smartphone Cluster" menu item not added (NaviScreenBag8), ClusterSceneLink silent; wrapper: libcpproxy with AltScreen, librgi_hook + renderer with RGI. `AltScreen.jar` linked while AltScreen or RGI is on, `/mnt/app/eso/hmi/lib` while RGI or wireless is on. Host-tested (wrapper, all pack/switch combinations); car test pending. |
| **Two separate parts** | AltScreen CarPlay (`AltScreen.tar.gz`) and wireless CarPlay (`wcp.tar.gz`) can be installed alone or together (`split.zip`, `README_SPLIT.md`). Java: shared `TerminalModeActivator` in both jars, bridge in the new WCP.jar; wrapper and librgi_hook shared and feature-aware; switches `altscreen_off` / `wcp_off`. Also fixes: `/tmp/rgd_disable` no longer removes the wireless iAP2 module from a wireless session. Host-tested (wrapper preloads in every combination, AltScreen.sh with each pack, both, and each switch). Left: car test of each install variant; PowerShell pack builder not run here. |
| Prompt start delay (optional) | The SETUP reply for a prompt waits \~0.4 s for its two stream keys from `wcppaird` (\~195 ms each). Acceptable as is; could be cut by a faster key request in `wcppaird` or by deriving the keys in the hook from the session secret. |

### Audio quality over Wi-Fi

| Channel | Over Wi-Fi | Compared with USB |
| --- | --- | --- |
| Music (stream 102) | AAC-LC 48 kHz stereo from the phone (its log: 128 kbit/s CBR or 192 kbit/s VBR), decoded to PCM 48 kHz stereo | compressed by the phone — inherent to wireless CarPlay; nothing lowered by us |
| Calls, Siri (stream 100) | Opus 16 kHz mono → PCM 16 kHz | same bandwidth: the stock receiver offers only 16 kHz mono for voice |
| Navigation prompts (stream 101) | Opus 16 kHz mono → PCM 16 kHz | same: the stock alt-audio list is 16 kHz mono only |
| Microphone (car → phone) | our Opus encoder 16 kHz mono, 32 kbit/s, complexity 8 | the one setting chosen by us; was 24 kbit/s, complexity 5 |

---

## 7. Test procedure and switches

```sh
sh /mnt/ota/app/AltScreen.sh check      # overlay, prepared tree, stock copies, wrappers, processes
sh /mnt/ota/wcp/wcp-boot.sh status      # what runs (wcpd, wcppaird, dio_manager and its mode), logging
sh /mnt/ota/wcp/wcp-test4.sh            # restart the daemons for a test (old logs kept as /tmp/prev_*)
sh /mnt/ota/wcp/wcp-logcheck.sh [prev]  # the lines that matter from the logs
touch /mnt/ota/app/debug_wificp         # logs on (DEBUG_LOG=1 builds); rm to switch off
touch /mnt/ota/app/debug_wificp_raw     # + raw dumps (hex, every iAP2 packet)
```

Build: `build_all.bat` (every component, then the pack) or `build_wcp.bat` (`set DEBUG_LOG=0` for a release without log code) → `libwcpstart.so`, `libbthook.so`, `wcpd`, `wcppaird`; **then always `create_tar.bat`** → `AltScreen.tar.gz` (all mods). Before a car test, check that the car runs the new code:

```sh
grep -c "count as session activity" /mnt/ota/wcp/libwcpstart.so   # 1 or more = idle-timer fix in
grep -c "access point runs on channel" /mnt/ota/wcp/wcpd           # 1 = channel fix in
grep -c MDNSD= /mnt/ota/wcp/dio-up.sh                              # 1 = mdnsd start in
```

| Marker | Effect |
| --- | --- |
| `/mnt/ota/app/debug_wificp` | every component writes its log (DEBUG_LOG=1 builds) |
| `/mnt/ota/app/debug_wificp_raw` | with the above: raw dumps too |
| `/mnt/ota/app/.sf_disable` | boot hook starts nothing (all mods off; `sf_disable` on SD/USB creates it) |
| `/mnt/ota/app/bthook_off` | btstack runs stock, no daemons at boot |
| `/mnt/ota/app/bthook_test` | libbthook only logs, registers nothing |
| `/mnt/ota/app/bthook_noask` | libbthook does not ask the chip for the address (stack's copy only) |
| `/mnt/ota/app/bthook_nousbresume` | libbthook does not open iAP2 when a USB CarPlay session ends |
| `/mnt/ota/app/wcp_noboot` | daemons not started at boot |
| `/mnt/ota/app/wcp_wifi_on` | HMI switches the car's Wi-Fi on (empty: once at the next start, then removed; `always`: every start) |

All control files are in `/mnt/ota/app` (full list: technical reference, section 10); `AltScreen.sh check` lists the ones that are set, each with what it is for.

| Switch | Default | Effect |
| --- | --- | --- |
| `WCP_IAP_AIRPLAY` | 1 (set by `dio-up.sh`) | stock iAP2 client runs inside the AirPlay session |
| `WCP_DIO_UP` | `dio-up.sh` (set by `wcp-boot.sh`) | `dio_manager` on demand; unset = `wcpd` never starts it |
| `WCP_KEEP_BT` | 0 | 1: the hook answers `disableBluetooth` itself (Bluetooth stays) |
| `WCP_DIO_TIMER` | — | `keep`: leave `dio_manager`'s startup timer untouched |
| `WCP_DIO_TRACE` | off | `n`: all `dio_manager` trace channels at level n → `/tmp/dio_trace.log` (debug builds, with the marker) |
| `WCP_PHONE_TIMEOUT_MS` | 5000 | end the session after this long without traffic from the phone; 0 = off |
| `WCP_AP_WATCH` | on | 0: `wcpd` does not follow the access point's station events |
| `WCP_BT_DROP_MS` | 8000 | `wcpd` closes a Bluetooth iAP2 link still open this long into a session; 0 = off |
| `WCP_REOFFER_MS` | 20000 | `wcpd` offers CarPlay to the HMI again if no receiver came up |
| `WCP_102_TARGET`, `WCP_102_BUFFER`, `WCP_102_OPENLOOP`, `WCP_101_LEADIN`, `WCP_102_BOOST` | 150 ms, 600 ms, off, 0 ms, 0 ms | music pacing, prompt lead-in, extra music margin around a prompt's SETUP |
| `WCP_IAP_DIRECT` | on | 0: no direct iAP2 connect job when `iAP2Connect()` returns 0 (5092) |
| `WCP_MDNSD` | on (`dio-up.sh`) | 0: `dio-up.sh` does not start mdnsd |
| `WCP_KA_ACTIVITY` | on | 0: keep-alive beacons do not count as session activity for the stock idle timer |
| `WCP_CHANNEL` | 6 (`start-ap.sh`) | access point channel (1 / 6 / 11, 0 = automatic, empty = connectionmanager's); settable in `wcp.conf` |

Logs (with the marker): `/tmp/wcpd.log` (Bluetooth iAP2, Wi-Fi setup, on-demand start), `/tmp/bthook.log` (Bluetooth stack), `/tmp/wcphook.log` (session, iAP2 inside it, audio relay), `/tmp/wcpstart.log`, `/tmp/wcppaird.log`, `/tmp/dio_trace.log` (`dio_manager`), `/tmp/wcp_hmi.log` (HMI bridge), `/tmp/wcp_dio_up.log` (dio_manager starts, USB hand-over), `/tmp/wcp_boot.log`. `/tmp/rgi_hook.log` (Identify) follows the RGI framework (`debug_hook`).

---

## 8. Approach

1. **Keep the stock receiver, iAP2 client and HMI.** Everything the car already does for wired CarPlay is reused; the project adds only what wireless needs and adapts the stock code at its boundaries.
2. **Follow the factory unit.** The iPhone log of a factory wireless MIB2+ was the reference for the transport of iAP2, the Bluetooth release and the order of events.
3. **Adapt at the socket and library boundary.** A preloaded library interposes on socket calls and the stock libraries' exports; where `dio_manager` itself had to change, an address table (GOT) entry is redirected instead of patching code; btstack is handled the same way (`libbthook`), so no stock binary is modified.
4. **Evidence first.** Car logs, `dio_manager`'s own trace and iPhone logs are read together; hypotheses are tested with switches before defaults change.
5. **Host tests before car tests.** Every change runs against a fake stock receiver and a scripted phone on the PC and is cross-compiled for ARM before a car run.
6. **Small, reversible steps.** New behaviour comes with a switch to turn it off and log lines that show it working.

---

## License

This project is licensed under the **PolyForm Noncommercial License 1.0.0**.
See the [`LICENSE`](LICENSE) file for the complete license terms.

In summary, the license permits use, modification, and redistribution for noncommercial purposes, subject to the full license terms. Commercial use or distribution requires separate permission from the copyright holder. This summary does not replace the license text.

**Copyright:** Replace the placeholder notice in `LICENSE` with your name or project copyright holder before publishing.

This is an independent community project and is not affiliated with, endorsed by, or officially supported by Audi AG.
