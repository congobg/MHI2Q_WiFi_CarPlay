# Wireless CarPlay on MHI2Q QC — Technical Reference

Companion to `PROJECT_STATUS.md`: components, ports, session flow, build, test procedure and switches.

---

## 1. Components

| Component | Runs in | Role |
| --- | --- | --- |
| `start-ap.sh` overlay | AP start by connection manager | HT20, channel 6, Apple vendor element |
| `btstack` graft | stock Bluetooth stack | RFCOMM ch 4 (iAP2), CarPlay SDP/EIR, bridge to `wcpd` |
| `wcpd` | own process | iAP2: identification, Wi-Fi handover, `CarPlayStartSession` (gated) |
| `wcppaird` | own process | Pair-Setup / Pair-Verify, receiver identity, MFi coprocessor |
| `libwcpstart.so` | preloaded into `dio_manager` | start order, interface swap, encryption, `/info` and Bonjour, audio relay, AAC decode |
| `AltScreenQ_wcp.jar` | HMI (Java) | virtual CarPlay device, connect/disconnect, session state to HMI |

`libwcpstart.so` is built from:

| File | Content |
| --- | --- |
| `wcpstart.c` | constructor, start order (waits for the HMI), interface `carplay0 → uap0`, Bonjour TXT, USB trace switch |
| `wcphook.c` | socket interposers, encryption, request/reply adaptation, `/info`, keep-alive, audio relay + pacer, diagnostics |
| `wcpaead.c` | ChaCha20-Poly1305 |
| `wcpplist.c / .h` | binary plist reader / writer (root-first layout) |
| `wcpaac.c / .h` | AAC-LC → PCM through the unit's Cinemo codec |

---

## 2. Ports (`uap0`, 10.173.189.1)

| Port | Proto | Owner | Use |
| --- | --- | --- | --- |
| 5000 | TCP | stock receiver (+ adapter) | AirPlay control, encrypted |
| 5001 | TCP | stock receiver (+ adapter) | event channel, encrypted |
| 6030 | TCP | stock receiver (+ adapter) | main screen stream (110) |
| 6031 | TCP | cluster proxy (+ adapter) | cluster stream (111) |
| 7070 | UDP | adapter relay | all audio streams from the phone (data + control) |
| 7071 | UDP | adapter | keep-alive |
| 7072 | UDP | stock receiver (moved from 7070) | stock audio socket, fed by the relay on 127.0.0.1 |

---

## 3. Session flow

1. Phone connects over Bluetooth; `wcpd` completes iAP2 and writes `AVAILABLE` to `/tmp/wcp_session`.
2. HMI bridge lists virtual device 200; the user accepts CarPlay.
3. Bridge reports `CONNECTED`; the HMI calls `DSICarplay.startService` with display, HID and audio parameters, which starts the stock receiver.
4. Receiver listens on 5000; adapter creates `/tmp/wcp_go`.
5. `wcpd` sends `CarPlayStartSession`; phone joins Wi-Fi and connects to 5000.
6. Pair-Verify, encrypted control, `/info`, session `SETUP`, screen streams; bridge reports `STARTED`; HMI switches to the CarPlay context.
7. Audio streams are set up on demand (play, call, Siri) through the relay.

---

## 4. Audio path

### 4.1 Advertised formats (Wi-Fi)

| Stream / audio type | In | Out |
| --- | --- | --- |
| 100 default | Opus 16 + PCM 16 mono | Opus 48 + PCM 48 stereo + PCM 16 mono |
| 100 media | – | same as default |
| 100 telephony | Opus 16 + PCM 16 mono | Opus 16 + PCM 16 mono |
| 100 speechRecognition | Opus 16 + PCM 16 mono | Opus 16 + PCM 16 mono |
| 100 alert | – | same as default |
| 101 default | Opus 16 + PCM 16 mono | Opus 16 + PCM 16 mono |
| 102 default / media | – | AAC-LC 48 stereo + Opus 48 + PCM 48 stereo |

Features: bit 38 added; bits 20 and 22 cleared.

### 4.2 Stream handling

| Phone sends | Stock receiver sees | Relay does |
| --- | --- | --- |
| 102 media, AAC-LC 48 kHz stereo | type 100, PCM 48 kHz stereo, latency 100 ms | decrypt → decode → queue → paced 256-frame packets |
| 100 / 101, Opus 16 kHz mono | type 100 / 101, PCM 16 kHz mono | decrypt; **dropped until an Opus decoder exists** |
| 100 / 101, PCM | type 100 / 101, same PCM | decrypt → re-frame ≤ 1440 bytes |
| microphone (stock → phone) | — | encrypted by the send hook, forwarded to the phone |

Request adaptation for the stock receiver: stream type 102 → 100, AAC/Opus → PCM, `streamConnectionID` / `controlPort` / `spf` removed. Reply adaptation for the phone: type 100 → 102 where mapped, `dataPort` and `controlPort` → 7070.

---

## 5. Build

```sh
qcc -Vgcc_ntoarmv7le -shared -fPIC -o libwcpstart.so \
    wcpstart.c wcphook.c wcpaead.c wcpplist.c wcpaac.c
```

Copy to `/mnt/ota/wcp/`. A clean build is needed whenever `wcpplist.h` changes.

---

## 6. Test procedure

```sh
sh /mnt/ota/wcp/wcp-test2.sh          # start (Wi-Fi mode)
# accept CarPlay on the MMI, play music / call
sh /mnt/ota/wcp/wcp-test2.sh stop     # stop
```

| Log | Content |
| --- | --- |
| `/tmp/wcpd.log` | Bluetooth / iAP2, gate, `CarPlayStartSession` |
| `/tmp/wcphook.log` | pairing, encryption, `/info`, audio adaptation, relay statistics |
| `/tmp/wcpstart.log` | start order, HMI parameters |
| `/tmp/wcp_hmi.log` | HMI bridge |
| `sloginfo` | stock receiver (`[AirPlay]`, `Main audio`, `Buffering issues`) |

Useful checks:

```sh
grep -E "relay|stream type 10|Opus" /tmp/wcphook.log | tail -30
grep -E "last 500 packets|playing|stream 102 closed" /tmp/wcphook.log | tail -8
sloginfo | grep -E "###|Main audio|Buffering issues" | tail -10
```

USB reference trace (wired session, nothing modified): `touch /tmp/wcp_trace`, replug the phone, `grep TRACE /tmp/wcphook.log`; remove `/tmp/wcp_trace` afterwards. Requires the trace block in the `dio_manager` wrapper.

---

## 7. Switches

| Variable | Default | Effect |
| --- | --- | --- |
| `WCP_EARLY=1` | off | old start order (adapter starts the receiver) |
| `WCP_102_BUFFER` | 600 | ms queued before media playback starts |
| `WCP_102_LATENCY` | 100 | latency given to the stock receiver for media |
| `WCP_102_NOPACE=1` | off | media without the pacer (direct re-framing) |
| `WCP_102_STRIP=1` | off | (experiment) remove extra keys from the media SETUP |
| `WCP_RELAY_PORT` | 7070 | relay port |
| `WCP_KA_PORT` | 7071 | keep-alive port |
| `WCP_AF_<NAME>_IN/_OUT` | — | override one advertised format entry (`DEF`, `MEDIA`, `TEL`, `SIRI`, `ALERT`, `ALT`, `HIGH`) |
| `WCP_AF_PCM_ONLY=1` | off | PCM-only format list (USB-style) |
| `WCP_AUDIO_STOCK=1` | off | stock audio list and feature bits untouched |
| `WCP_CINEMO_PLUGIN_DIR` | `/mnt/app/armle/usr/lib/cinemo` | codec plugin directory |
| `WCP_DEBUG_CF=1` | off | log the stock receiver's dictionary / property / setup calls |
| `WCP_DIO_TRACE=1` | off | USB trace mode (set by the wrapper when `/tmp/wcp_trace` exists) |

---

## 8. Key addresses (stock `dio_manager`, cksum 2268931283)

| Symbol | Address |
| --- | --- |
| `AirPlayReceiverServerCreate` PLT | `0x111660` |
| `CDSICarplayImpl::startService` | `0x15D658` (screen params at CDIOManager `+0x2C0..+0x2DC`) |
| `CAirPlayMainThread` ctor | `0x14D3EC` |
| `onEvent_startAirPlay` | `0x150018` |

Stock `libairplay.so` locations used during analysis:

| Function | Offset | Note |
| --- | --- | --- |
| `AirPlayReceiverSessionSetup` | `0x26D48` | session and stream setup |
| `_requestProcessSetupPlist` | `~0x2E4F8` | parses the SETUP body (`CFCreateWithPlistBytes`) |
| `AirPlayReceiverSessionMakeModeStateFromDictionary` | `0x22EE4` | mode changes (string lookups fall back to numbers — harmless `kTypeErr`) |
| `_AudioStreamSetProperty` | `0x4A0C0` | audio output properties |