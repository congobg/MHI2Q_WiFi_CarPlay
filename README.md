# Wireless CarPlay on MHI2Q QC — Project Status

**Unit:** MHI2Q QC (mmx2qc), rel/CLU7, Harman 2016, QNX 6.5.0 ARMv7 (APQ8064), firmware 3638 / MU0917 **Phone under test:** iPhone, iOS 27 **Goal:** native wireless CarPlay on a head unit that only ships wired CarPlay, keeping the stock CarPlay receiver (AirPlay 210.81 in `dio_manager`) and the stock HMI.

---

## 1. Summary

| Area | State |
| --- | --- |
| Wi-Fi access point for CarPlay | ✅ verified |
| Bluetooth discovery + iAP2 + Wi-Fi handover | ✅ verified |
| Pairing (Pair-Setup / Pair-Verify) and encrypted control | ✅ verified |
| Main screen (1024×480) | ✅ verified |
| HMI integration (menu entry, activation, context switch) | ✅ verified |
| MMI controls (knob, touchpad) | ✅ verified |
| Audio format negotiation over Wi-Fi | ✅ verified |
| Media audio (music) | ✅ verified — continuous, no loss |
| Calls / Siri / navigation prompts (Opus) | ✅ calls verified both ways; Siri and prompts to be checked |
| Microphone | ✅ verified (far end hears the car's microphone) |
| Instrument-cluster map stream | 🟡 frames decrypted, display not confirmed |
| Automatic start / production packaging | ⬜ manual test script only |

---

## 2. What we did

### 2.1 Wi-Fi access point

- Overlay for the stock AP start script: HT20 instead of HT40, fixed channel 6, Apple vendor element in beacons and probe responses.
- AP: Marvell 88W8787, interface `uap0`, `10.173.189.1/24`.

### 2.2 Bluetooth (btstack graft)

- Code grafted into the stock `btstack` binary: an RFCOMM server on channel 4 for iAP2, CarPlay SDP record and EIR data.
- The RFCOMM channel is bridged to a local TCP socket (`127.0.0.1:57342`) served by `wcpd`.

### 2.3 iAP2 daemon (`wcpd`)

- Identification, authentication via the car's MFi coprocessor, Wi-Fi credential handover.
- Sends `CarPlayStartSession (0x4301)` with receiver address, device ID, pairing identifier and source version.
- **Gating:** the start message is held until the stock receiver is actually listening (`/tmp/wcp_go`), so the HMI can start the receiver in the same order as a USB session.
- Writes the session state (`AVAILABLE`) for the HMI bridge.

### 2.4 Pairing helper (`wcppaird`)

- Persistent receiver identity (Ed25519) and pairing identifier.
- Pair-Setup / Pair-Verify for the phone; MFi coprocessor on `/dev/i2c8`, address `0x11`.

### 2.5 Receiver adapter (`libwcpstart.so`, preloaded into `dio_manager`)

- **Start order:** waits for the HMI to start the receiver (`DSICarplay.startService`) so the HMI supplies display, HID and audio parameters, exactly as over USB.
- **Interface:** receiver and Bonjour moved from `carplay0` (USB) to `uap0`.
- **Encryption layer** (socket level, invisible to the stock code):
  - control channel (port 5000) and event channel (5001): ChaCha20-Poly1305 framing after Pair-Verify;
  - screen streams 110 / 111: frame-by-frame decryption, stock legacy AES bypassed;
  - keep-alive receiver on UDP 7071.
- **Advertisement:** `/info` and Bonjour TXT get feature bit 38, pairing identifier `pi`, public key `pk`, correct display geometry, and a Wi-Fi-capable audio format list (see §5).
- **Audio adaptation and relay** (see §5).
- **Session state** for the HMI bridge: `CONNECTED`, `STARTED`, `DISCONNECTED`.

### 2.6 HMI bridge (`AltScreenQ_wcp.jar`)

- Adds a virtual device (ID 200) to the HMI's smartphone device list when the phone is ready over Bluetooth.
- Intercepts connect/disconnect for that device; reports `CONNECTED` / `STARTED` / `DISCONNECTED` to the HMI device manager.
- Configurable connection type (`/mnt/ota/wcp/hmi.conf`).

### 2.7 Diagnostics built along the way

- **USB trace mode:** logs a wired session's requests and replies without changing anything; used as the reference for "what the stock receiver accepts".
- **CF debug trace:** watches the stock receiver's own dictionary, property and setup calls (with caller offsets) to locate stock-side errors.
- **Host test harness:** a fake stock receiver plus a scripted phone run every change on the PC before it goes to the car.

---

## 3. What worked

- End-to-end session: Bluetooth → iAP2 → Wi-Fi join → AirPlay control → screen.
- Pairing and all encrypted channels.
- HMI: CarPlay offered in the device list, single activation, automatic switch to the CarPlay context, return to the HMI and back.
- Controls: the HMI now passes HID inputs `0x9` (knob + touchpad, 256×256) and the stock receiver registers `Eso_Knob` and `Eso_TrackPad`.
- Audio negotiation: the phone builds its CarPlay audio output (no format errors, CarPlay audio port present).
- Media audio: AAC-LC is received, decrypted, decoded on the car (Cinemo codec), handed to the stock audio path and **plays continuously**.
- The stock receiver's own buffering problem is solved by pacing (rebuffers went from 41–170 per track to 1).
- Packet loss in the car's network stack is solved: a large relay socket buffer and a higher relay thread priority took losses from \~40 % to 0.
- Calls: phone → car Opus is decoded for the stock voice path, and the car's microphone is encoded to Opus and sent to the phone; a full phone call works in both directions.
- Calls: the stock receiver sets up a telephony stream (`PCM/16000/16/1 for telephony, input yes`); the session no longer drops.

---

## 4. What is verified

Verified on the car, with car-side logs and iPhone logs:

| Item | Evidence |
| --- | --- |
| AP, Bonjour on `uap0` | Bonjour registration on port 5000, phone discovers the receiver |
| iAP2 handover | `CarPlayStartSession` sent after the receiver listens; phone joins Wi-Fi |
| Pairing / encryption | Pair-Verify succeeds; control channel decrypted |
| Screen | stream 110 decoded on the MMI, 1024×480 |
| HMI flow | bridge log `AVAILABLE → CONNECTED → STARTED`, context 78 with the smartphone displayable, no second activation prompt |
| Controls | knob and touchpad usable in CarPlay |
| Audio format acceptance | iPhone log: no `APCarPlayAudioFormatsCreate` error, CarPlay audio port created |
| Stock accepts the audio stream | `Main audio setting up PCM/48000/16/2 for media` |
| Decoding | relay counts packets in, 4 PCM packets out per AAC unit |
| Pacing | stock summary `Rebuffers=1` |
| Continuous music | 16 windows of 500 packets: 0 lost, 0 silence, decoded time = RTP time, queue steady at 380–740 ms; `dropped due to full socket buffers` unchanged |
| Phone call, phone → car | Opus decoded (`320 frames` per packet), stock `Late=0 Missing=0 Gaps=0`, caller heard |
| Phone call, car → phone | microphone peak level up to 30 726 / 32 767, 1000+ Opus packets sent, far end hears the car |
| Music → call → music | call → music → call → music in one session: each stream closed on TEARDOWN, socket re-keyed, both directions clear in every call, music resumes |
| Navigation prompts over music | prompt on stream 101 alongside music on 102; prompt complete from the start; music locked 150–156 ms ahead of the stock play position, no gap storms, one short dip per prompt |

Verified on the host test harness only:

- PCM stream + microphone path through the relay (microphone packets encrypted and returned to the phone correctly).
- Plist writer output identical in structure to Apple's.

---

## 5. Audio: findings that shaped the design

| # | Finding | Consequence |
| --- | --- | --- |
| 1 | Over Wi-Fi, iOS accepts an audio type only if a **compressed** format is offered; PCM-only lists fail (`Error in creating formats for type 100 / telephony`). | Advertise Opus next to PCM for voice types. |
| 2 | iOS also requires **stream type 102** (Wi-Fi media) and insists on **AAC-LC stereo** there. | Advertise AAC-LC 48 kHz on 102. |
| 3 | Stock 210 has **no stream type 102** and cannot decode AAC. | 102 is presented to the stock code as type 100 PCM; the car decodes AAC itself. |
| 4 | Stock 210 rejects Wi-Fi-style stream keys (`streamConnectionID`, `controlPort`, `spf`). | Hidden from the stock code (kept by the adapter for the stream keys). |
| 5 | Stock plist parser takes the **first object** in a binary plist as the root. | Plist writer emits the root first, 1-byte references. |
| 6 | Over Wi-Fi the phone needs a **`controlPort`** in the SETUP reply. | Added (points to the relay; RTCP is dropped). |
| 7 | The stock audio socket is fixed at **UDP 7070**, the only audio port open in the firewall. | Stock socket moved to 7072; the relay owns 7070. |
| 8 | Stream packets are larger than the stock 1472-byte receive buffer. | Relay re-frames into packets of ≤ 1440 bytes (4 × 256 frames). |
| 9 | The phone sends media in **bursts** (it assumes a 1 s receiver buffer). | Relay queues decoded audio and paces it to the stock code at 48 kHz on the car's clock. |
| 10 | iPhone uses **Opus 16 kHz mono** for telephony, Siri and alerts. | Needs an Opus decoder (and encoder for the microphone). |
| 11 | The default UDP socket buffer (41 600 bytes ≈ 20 datagrams) overflows on the phone's bursts; \~40 % of media packets were dropped (`dropped due to full socket buffers`). | Relay socket buffer raised (768 KB with `kern.sbmax` = 1 MB), relay thread at priority 21. |
| 12 | The phone receives the microphone on a port named in the call SETUP, not on the port it sends from. The stock code knows it; the relay does not. | The relay sends the encoded microphone to the destination the stock code addresses. |
| 13 | The stock code reuses one audio socket for every main-audio stream (music, then call, then music). | On TEARDOWN the relay stream is closed (its pacer stops); a new SETUP replaces the previous stream's entry and keys for that socket. |
| 14 | The stock jitter buffer holds only 55 packets (403 ms with 352-frame packets); its audio thread pauses \~360 ms when a navigation prompt starts, while its output keeps playing. A clock-driven pacer overfilled it and caused rebuffer cascades. | The music pacer reads the stock's play position (via `RTPJitterBufferRead`) and stays a fixed 150 ms ahead of it; queue drift is corrected 1 ms at a time. |
| 15 | The stock code opens the prompt channel \~500 ms after the prompt stream starts. | 500 ms of silence before each prompt; the prompt starts complete. |

---

## 6. What is left

### 6.1 Media audio — *done, two follow-ups*

- Make the `kern.sbmax` raise permanent (set in the start script before `dio_manager` starts).
- Long-run check of the pacer against clock drift (queue level over 30+ minutes).

### 6.2 Voice audio (calls, Siri, navigation prompts)

- Done: fixed-point Opus built for the car (encode 1.1 ms, decode 0.12 ms per 20 ms frame); phone calls work in both directions, with loss concealment on the downlink.
- Left: Siri; tuning of the short music dip at the start of a prompt (stock thread pause, \~0.1–0.2 s).

### 6.3 Instrument cluster

- Cluster frames (stream 111) arrive decrypted at the cluster proxy; its own legacy AES step must be skipped in wireless mode.
- Confirm the map on the virtual cockpit.

### 6.4 Bluetooth

- The car's Bluetooth application crashed once (NULL string in its incoming OBEX authentication handling) after a session drop — needs reproduction and a guard.
- Confirm the phone's `disableBluetooth` request results in A2DP/HFP being released while CarPlay is active.

### 6.5 Production readiness

- Remove the debug watchers from the production build (keep them behind a build flag).
- Automatic start at boot instead of the test script; reconnect after ignition cycles and after phone/session drops.
- Firewall: a proper rule set for the CarPlay ports on `uap0` (no disabling of the packet filter during tests).
- Long-run checks: clock drift of the pacer, memory, repeated sessions.
- Cosmetic: the HMI shows the phone twice during start-up (Bluetooth phase, then session phase).

---

## 7. Approach

1. **Keep the stock receiver and HMI.** Everything the car already does for wired CarPlay (decoding, audio routing, HID, HMI contexts) is reused. The project only adds what wireless needs and adapts the stock code at its boundaries.
2. **Adapt at the socket and library boundary, not inside the binary.** A preloaded library interposes on socket calls and on the stock library's exported functions: it decrypts/encrypts, rewrites requests and replies, and relays streams. The only binary change is the Bluetooth graft.
3. **Make Wi-Fi look like USB to the stock code.** Every difference is translated at the edge: transport encryption, stream types, request keys, plist layout, ports, packet sizes, timing.
4. **Evidence first.** Each step was driven by three log sources read together: the car (`sloginfo`, adapter logs), the iPhone (device console) and, when needed, a wired-session trace as the reference of what the stock code accepts. Hypotheses were tested with switches (environment variables) before changing defaults.
5. **Host tests before car tests.** Each change ran against a fake stock receiver and a scripted phone on the PC (encryption, plist round-trips, relay framing, pacing), and was cross-compiled for ARM, before being sent for a car run.
6. **Small, reversible steps.** New behaviour comes with a switch to turn it off and with log lines that show it working, so a car run always produces a clear answer.