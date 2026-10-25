# Wireless CarPlay on MHI2Q QC — Project Status

**Unit:** MHI2Q QC (mmx2qc), rel/CLU7, Harman 2016, QNX 6.5.0 ARMv7 (APQ8064), firmware 3638 / MU0917 **Phone under test:** iPhone, iOS 27 **Goal:** native wireless CarPlay on a head unit that only ships wired CarPlay, keeping the stock CarPlay receiver (AirPlay 210.81 in `dio_manager`), the stock iAP2 client and the stock HMI. **Last update:** 2026-10-25 (later) — stock btstack with `libbthook.so` (no patched binary), the car opens iAP2 itself (cold boot, reconnect, pairing), one logging scheme for all components, `dio_manager` on demand and a boot start (both new, to be verified on the car).

---

## 1. Summary

| Area | State |
| --- | --- |
| Wi-Fi access point for CarPlay | ✅ verified |
| Bluetooth setup: discovery, iAP2, Wi-Fi handover, session start | ✅ verified — about 1 s from the HMI's offer to the running session |
| **Stock btstack + `libbthook.so`** (no patched binary) | ✅ verified — iAP2 channel, SDP records, CarPlay UUID in the advertisement |
| **Car-initiated iAP2** (cold boot, after a session, after pairing) | ✅ verified — the car opens iAP2 4 s after connecting the phone; retries while the phone or stack is busy |
| Pairing (Pair-Setup / Pair-Verify) and encrypted channels | ✅ verified |
| Main screen (1024×480), knob and touchpad | ✅ verified |
| HMI integration (device list, activation, context switch) | ✅ verified |
| Media audio, navigation prompts over music | ✅ verified |
| Calls and Siri (Opus), microphone | ✅ verified — both directions, MMI volume knob active during calls |
| Instrument-cluster map stream | ✅ verified |
| **iAP2 inside the AirPlay session** (now playing, cover art, call lists, favourites, route guidance to the cluster, location, vehicle data) | ✅ verified — same transport as the factory MIB2+ |
| **Bluetooth released during CarPlay**, restored afterwards | ✅ verified — single audio route on the phone |
| Session stability | ✅ verified — dio_manager's 6 s startup timeout handled |
| **Disconnect / reconnect** (CarPlay off and on at the phone) | ✅ verified — works every time |
| Session drop when touching the controls after a few minutes | ✅ fixed (event-channel pump) — first car test stable: pump active, no requests piling up; long-run check still open |
| Recovery after a drop (stale gate, receiver not taking the session) | ✅ verified — a fresh `dio_manager` started on demand, CarPlay back \~14 s after the drop |
| **Phone leaving the Wi-Fi** detected | ✅ verified — Wi-Fi switched off: \~0.25 s (access point event); otherwise 5 s (keep-alive watchdog) |
| PHONE hard key in CarPlay | 🟡 only the first press opens CarPlay (nice to have) |
| MMI prompt "A password must be entered for this data transfer" | ✅ no longer appears |
| Logging (`DEBUG_LOG` build switch, markers `debug_wificp` and `debug_wificp_raw`) | ✅ in all components; raw dumps separate (they were >80 % of the hook log) |
| `dio_manager` on demand (no permanent instance; USB wins) | ✅ wireless verified on the car (started at Bluetooth link-up, offered when ready); USB hand-over still to test |
| Start at boot (btstack wrapper → `wcp-boot.sh`) | 🔵 implemented, car test pending |

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
| Logging scheme | release builds without log strings or diagnostic interposers; host tests: no log without the marker, log once it exists |
| Earlier results still valid | screen, controls, media audio, prompts over music, music ↔ call switching, cluster map |

---

## 6. What is left

| Item | Notes |
| --- | --- |
| USB hand-over | Needs the insert `dio_manager.wcp.inc` in the `dio_manager` wrapper. Car tests: USB phone with no wireless (stock), USB plugged in during wireless (wireless instance gives way), wireless after a USB session. |
| Start at boot | Car test of the btstack wrapper starting `wcp-boot.sh`; `kern.sbmax` is now set there. Alternative: start from the runQC / RGI-Q overlay instead. |
| Firewall | A proper rule set for the CarPlay ports on `uap0` (no disabling of the packet filter). |
| HMI bridge | Rebuild `AltScreenQ_wcp.jar` with the logging change (`DEBUG_LOG` constant). |
| Microphone quality | Our Opus encoder runs at 24 kbit/s, complexity 5 (CPU choice); 32 kbit/s / complexity 8 would cost \~2–3 ms per 20 ms frame. |
| Alerts on type 100 | Only Opus 48 kHz **mono** is offered as compressed format for `alert`/`default` (not seen in use); AAC-LC stereo could be added. |
| PHONE hard key | Stock (USB): the key opens the MMI's phone app, which says to use CarPlay. Wireless now: the first press opens CarPlay, later presses the MMI's phone app. Nice to have: with CarPlay active, always open CarPlay. Needs the HMI's `de.audi.app.terminalmode.smartphone.HardKeyDSIListener` (from `lsd.jar`). |
| `IPOD_AP2_PPSSERVICE` | `enqueueSingleMessage failed … thread not available` at every connect; check whether the MMI's own media screens and the cluster show titles outside CarPlay. |
| One-off | Once, on the first connection of a run, CarPlay ended together with Bluetooth; starting it from the MMI worked, not reproduced since. Capture the hook and `dio_manager` trace if it recurs. |
| Bluetooth app | Crashed once earlier (NULL string in its OBEX authentication handling) after a session drop; reproduce and guard. |
| Long-run checks | Pacer drift over 30+ minutes, memory, many reconnect cycles, ignition cycles. |
| Cosmetic | The HMI shows the phone twice during start-up (Bluetooth phase, then session phase). |
| Release build | Once stable: `set DEBUG_LOG=0` in `build_wcp.bat` (no log code at all). |

### Audio quality over Wi-Fi

| Channel | Over Wi-Fi | Compared with USB |
| --- | --- | --- |
| Music (stream 102) | AAC-LC 48 kHz stereo from the phone (its log: 128 kbit/s CBR or 192 kbit/s VBR), decoded to PCM 48 kHz stereo | compressed by the phone — inherent to wireless CarPlay; nothing lowered by us |
| Calls, Siri (stream 100) | Opus 16 kHz mono → PCM 16 kHz | same bandwidth: the stock receiver offers only 16 kHz mono for voice |
| Navigation prompts (stream 101) | Opus 16 kHz mono → PCM 16 kHz | same: the stock alt-audio list is 16 kHz mono only |
| Microphone (car → phone) | our Opus encoder 16 kHz mono, 24 kbit/s, complexity 5 | the one setting chosen by us (CPU); can be raised |

---

## 7. Test procedure and switches

```sh
sh /mnt/ota/wcp/wcp-boot.sh status      # what runs (wcpd, wcppaird, dio_manager and its mode)
sh /mnt/ota/wcp/wcp-test4.sh            # restart the daemons for a test (old logs removed)
touch /mnt/ota/app/debug_wificp         # logs on (DEBUG_LOG=1 builds); rm to switch off
```

Build: `build_wcp.bat` (`set DEBUG_LOG=0` for a release without log code) → `libwcpstart.so`, `libbthook.so`, `wcpd`, `wcppaird`.

| Marker | Effect |
| --- | --- |
| `/mnt/ota/app/debug_wificp` | every component writes its log (DEBUG_LOG=1 builds) |
| `/mnt/ota/wcp/bthook_off` | btstack runs stock, no daemons at boot |
| `/mnt/ota/wcp/bthook_test` | libbthook only logs, registers nothing |
| `/mnt/ota/wcp/wcp_noboot` | daemons not started at boot |

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
| `WCP_102_TARGET`, `WCP_102_BUFFER`, `WCP_102_OPENLOOP`, `WCP_101_LEADIN` | 150 ms, 600 ms, off, 500 ms | music pacing and prompt lead-in |

Logs (with the marker): `/tmp/wcpd.log` (Bluetooth iAP2, Wi-Fi setup, on-demand start), `/tmp/bthook.log` (Bluetooth stack), `/tmp/wcphook.log` (session, iAP2 inside it, audio relay), `/tmp/wcpstart.log`, `/tmp/wcppaird.log`, `/tmp/dio_trace.log` (`dio_manager`), `/tmp/wcp_hmi.log` (HMI bridge), `/tmp/wcp_dio_up.log` (dio_manager starts, USB hand-over), `/tmp/wcp_boot.log`. `/tmp/rgi_hook.log` (Identify) follows the RGI framework (`debug_hook`).

---

## 8. Approach

1. **Keep the stock receiver, iAP2 client and HMI.** Everything the car already does for wired CarPlay is reused; the project adds only what wireless needs and adapts the stock code at its boundaries.
2. **Follow the factory unit.** The iPhone log of a factory wireless MIB2+ was the reference for the transport of iAP2, the Bluetooth release and the order of events.
3. **Adapt at the socket and library boundary.** A preloaded library interposes on socket calls and the stock libraries' exports; where `dio_manager` itself had to change, an address table (GOT) entry is redirected instead of patching code; btstack is handled the same way (`libbthook`), so no stock binary is modified.
4. **Evidence first.** Car logs, `dio_manager`'s own trace and iPhone logs are read together; hypotheses are tested with switches before defaults change.
5. **Host tests before car tests.** Every change runs against a fake stock receiver and a scripted phone on the PC and is cross-compiled for ARM before a car run.
6. **Small, reversible steps.** New behaviour comes with a switch to turn it off and log lines that show it working.