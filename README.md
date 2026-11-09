# $2,500 Minecraft Server — Forge 1.20.1, Villager Recruits + Villager Workers, 30 Players

**Short answer:** Ryzen 7 9800X3D · 32 GB DDR5-6000 CL30 · 2× 2 TB PCIe 4.0 NVMe + 4 TB HDD · 750 W Gold · 1500 VA UPS · **Ubuntu Server 26.04 LTS** + **Temurin Java 21** · **$2,476** as specced (Nov 2026 prices).

This document is the build sheet *and* the tuning guide, because with these two mods the tuning is worth more than the last $500 of hardware.

### What's in this repo

| Path | Purpose |
|---|---|
| `README.md` | This build + distro + tuning guide |
| `config/server.properties` | Drop-in `server.properties` tuned for 30 players |
| `config/recruits-server.toml` | Villager Recruits per-world config: recruit caps, claims, sieges |
| `config/workers-server.toml` | Villager Workers config: claim-scoped work areas, pen/animal limits |
| `systemd/minecraft.service` | Run the server as a hardened systemd service with a 16 GB heap |
| `scripts/setup-ubuntu-server.sh` | Ubuntu/Debian provisioning: Java 21, sysctl, governor, ufw, swap, logrotate |
| `scripts/backup-world.sh` | Quiesced, verified, immutable world archives with retention |
| `scripts/rotate-backups.py` | 24 hourly / 7 daily / 4 weekly retention |
| `scripts/rcon.py` | Stdlib-only RCON client (used by the backup + stop path) |
| `tests/run-tests.sh` | Verification suite for everything above (`./tests/run-tests.sh`) |

---

## 1. What you are actually buying hardware for

Villager Recruits (talhanation) and Villager Workers (same author, an extension that **requires** Recruits) are not normal "add a mob" mods. Both add **custom pathfinding entities with their own AI, inventories, morale, payment/upkeep, faction ownership, sieges and block-breaking/placing behaviours**.

That produces four distinct loads, and they do not scale the same way:

| Load | What drives it | Scales with | Hardware answer |
|---|---|---|---|
| **Main tick loop** | Every recruit/worker runs AI + navigation goals every tick; work areas scan nearby containers for items | **Single-thread speed + L3 cache**, not core count | Fastest single-thread CPU you can afford (9800X3D) |
| **Entity tracking / packets** | 30 players × 20–30 recruits each = 600–900 tracked entities; recruit GUI/state sync | Upload bandwidth + one core for netty | 2.5 GbE, decent upload, network tuning |
| **Chunk gen + block changes** | Workers mine/farm/build → chunk loads; fresh world generation | Multi-core + fast NVMe | 8 Zen 5 cores is plenty; pregen with Chunky |
| **Memory churn** | Entity NBT, AI memory modules, per-tick allocations → GC pauses | Fast RAM + right heap + GC choice | 32 GB DDR5, 16 GB heap, G1 or ZGC |

Three consequences that shape the whole build:

1. **You are buying single-core performance, not cores.** An 8-core 9800X3D beats a 16-core Xeon/EPYC in Minecraft because the tick loop is one thread and the 96 MB 3D V-Cache helps exactly the kind of pointer-chasing, entity/block-heavy workload this mod creates.
2. **RAM capacity is not your bottleneck, and in 2026 it is terrible value.** 30 players on Forge 1.20.1 with ~15–20 mods wants a **12–16 GB heap**. 32 GB physical leaves ~16 GB for the OS, page cache and backups. A 64 GB kit costs ~$900+ right now (DDR5 is up 170–500% since 2025). Spending $470 more on RAM buys you nothing measurable here; spending it on a second NVMe and a UPS buys you uptime.
3. **30 players with hundreds of villagers is tick-bound no matter what you buy.** A 9800X3D gives you the headroom to run ~20 recruits/workers per player at a stable 20 TPS. It will not run 100 per player (the mod's default cap) at 20 TPS. Section 7 is the part that actually keeps you at 20 TPS.

---

## 2. The build — $2,476

Prices verified from Nov 2026 retail listings/deal trackers; treat them as ±10% because DDR5 and NAND are volatile right now.

| # | Part | Pick | Price | Why this one |
|---|---|---|---|---|
| 1 | **CPU** | AMD Ryzen 7 9800X3D (8C/16T, 96 MB L3) | **$399** | Top-tier single-thread + 3D V-Cache; the single best Minecraft-server CPU per dollar. Newegg has been running it at $399 through early Nov 2026. |
| 2 | **Cooler** | Thermalright Peerless Assassin 120 SE | **$37** | Way overkill for a 120 W part, quiet at low RPM, cheap. A server runs 24/7 — silence and bearing life matter. |
| 3 | **Motherboard** | MSI MAG B650 Tomahawk WiFi (ATX, AM5) | **$200** | Strong VRM, **2.5 GbE** (Realtek 8125), 2× M.2 (one CPU-attached), 6× SATA, BIOS Flashback. No need for X670/X870 PCIe lanes on a game server. |
| 4 | **RAM** | 32 GB (2×16 GB) DDR5-6000 **CL30**, EXPO | **$430** | 6000 CL30 is the AM5 sweet spot (1:1 FCLK). V-Color Manta XSky has been the cheapest CL30 kit at $429; Corsair/G.Skill equivalents run $460–500. **Do not** populate 4 DIMMs — AM5 drops to ~4800–5200 with 4 sticks. |
| 5 | **OS/mods SSD** | 2 TB PCIe 4.0 NVMe (WD SN850X / Samsung 990 Pro class) | **$400** | OS, Java, mods, server jar, logs, snapshots of configs. DRAM-cached TLC only — no QLC/DRAM-less for a server. |
| 6 | **World SSD** | 2 TB PCIe 4.0 NVMe (same class) | **$400** | World + region files + restore staging on a **separate device**, in the CPU-attached M.2 slot. A dying OS drive can't take the world with it, and `save-all` I/O never contends with the OS. |
| 7 | **Backup HDD** | 4 TB CMR 3.5" (WD Red Plus / IronWolf) | **$160** | Rotating cold backups + off-box copies. CMR, not SMR. |
| 8 | **PSU** | 750 W 80+ Gold, ATX 3.1 (MSI MAG A750GL / Corsair RM750e) | **$100** | ~400 W peak system draw; 750 W keeps the fan off and the caps cool. Single-rail, 10-year warranty class. |
| 9 | **Case** | Fractal Design Pop Air / Define 7 Compact | **$95** | Filtered front intake, room for a 3.5" HDD, no glass needed. Dust filters matter for a box that runs for years. |
| 10 | **Fans** | 2× 120 mm PWM (Arctic P12) | **$25** | Positive pressure so the filters actually work. |
| 11 | **UPS** | 1500 VA / 1000 W pure sine (CyberPower CP1500PFCLCD) | **$230** | A modded world writing region files + a hard power cut = corruption. Pure sine + USB → clean auto-shutdown via NUT. This is the highest-ROI $230 in the list. |
| | | **Total** | **$2,476** | |

**Nothing is left over, and nothing is wasted.** No GPU is needed — the 9800X3D's RDNA2 iGPU drives the BIOS/installer, then the box runs headless. Onboard audio and WiFi get disabled in BIOS.

### Where the money goes if you disagree with a choice

| Change | Delta | Verdict for *this* workload |
|---|---|---|
| 64 GB (2×32) instead of 32 GB | **+$480** | Not worth it. 16 GB heap is the right size for 30 players; buy this in 2028 when DRAM normalizes. |
| Single 2 TB NVMe instead of two | **−$400** | Fine if you snapshot the world to the HDD every 30 min. You lose OS/world failure isolation. |
| Ryzen 9 9950X3D instead of 9800X3D | **+$225** | Only if you'll also run a proxy + test server + CI on the same box. For one world it's ~0–3% in tick time. |
| ECC path: ASUS ProArt B650-Creator + 32 GB DDR5 ECC UDIMM | **+$250–300** | Defensible engineering choice (silent bit-flip protection on a 24/7 box). It does **not** make the server faster. Needs the ECC kit to be on the QVL or it may train poorly. |
| Value box: Ryzen 7 9700X, one 2 TB NVMe, 1000 VA UPS | **≈ −$780 ($1,697)** | ~10–15% slower ticks, same player count if you cap recruits. Best pick if $2,500 is a ceiling, not a target. |
| Downgrade to 16 GB (2×8) | **−$200** | Don't. You'd be at 10 GB heap and GC pressure at 30 players. |

---

## 3. Assembly and BIOS checklist

1. **Mount the world NVMe in the CPU-attached M.2 slot** (usually M2_1, directly under the CPU). Chipset-attached is fine for the OS drive.
2. **Install RAM in A2/B2** (2nd and 4th slots) — required for 6000 EXPO stability on AM5.
3. **First boot: be patient.** AM5 memory training can take 60–120 s on the first POST with EXPO. Do not panic-clear CMOS.
4. BIOS settings that matter:
   - **EXPO I / EXPO Tweaked** → DDR5-6000 CL30, then verify with `dmidecode -t memory` and a MemTest86 pass (one full pass is enough, overnight ideally).
   - **Restore on AC Power Loss = Power On** — the box comes back by itself after an outage.
   - Disable **onboard WiFi, onboard audio, serial/parallel** — a watt and an interrupt each.
   - **PBO: leave at Auto** for a 24/7 server. An undervolt/CO −15 is a nice-to-have, not a need; stability > 200 MHz.
   - Fan curve: target ~55–65 °C CPU under load, near-silent at idle.
   - If the board offers **"Power Supply Idle Control = Typical Current Idle"**, set it — fixes rare low-load shutdowns on some AM5 + Gold PSU combos.
5. Leave the CPU **iGPU enabled** (default). Headless Linux uses it for the console if you ever need a display; it costs ~1 W.
6. Cable the **HDD on a separate SATA power lead** and mount it on rubber grommets — it's the only moving part in the box.

---

## 4. Which Linux distro — and why

**Use Ubuntu Server 26.04 LTS ("Resolute Raccoon"), 64-bit, minimal/headless install, no GUI.**

| Candidate | Verdict |
|---|---|
| **Ubuntu Server 26.04 LTS** | ✅ **Recommended.** Released 23 Apr 2026; security support to 2031; kernel 7.0 (mature Zen 5 / AM5, `amd_pstate` EPP, modern NVMe); `openjdk-21-jre-headless` in the archive plus Adoptium packages; by far the largest body of Forge/Minecraft server documentation; `systemd`, `ufw`, `unattended-upgrades`, `tuned`, `node_exporter` all one `apt` away. |
| Debian 13 "Trixie" | ✅ Excellent alternative. Lighter default install, no Canonical snaps, several months more hardening than 26.04. Slightly older kernel/Java packaging. Pick it if you specifically dislike Ubuntu's snap/Pro direction. |
| Proxmox VE 9 (Debian + KVM) | ✅ If you want the server in a VM with snapshots and a web console. Give the VM 8 vCPU / 20 GB RAM, CPU type `host`, and pass the world disk through. ~2–4% overhead — acceptable, and the snapshots are genuinely useful before mod updates. |
| Rocky / AlmaLinux 9–10 | ⚠️ Works, but older userspace, extra steps for modern Java, no advantage here. |
| Arch / Fedora Server | ❌ Rolling or 13-month lifecycle on a box you want to leave alone for years. |
| Windows Server / Windows 11 | ❌ Slower tick times, worse GC behaviour under memory pressure, license cost, forced reboots. No. |
| Ubuntu **Desktop** | ❌ GNOME eats ~1 GB RAM and pulls a GUI stack you'll never use. Server ISO only. |

**Java runtime:** install **Eclipse Temurin 21 (LTS)** and pin it. Forge 1.20.1 (Forge 47.x) requires Java 17 minimum; 21 is the well-tested recommended runtime and gives you Generational ZGC. Java 25 ships in 26.04's archive and current Forge 47.x builds do run on it — but test before switching. 21 is the safe default for mod compatibility.

```bash
# Java 21, headless, from Adoptium (Ubuntu 26.04 / Debian 13)
sudo apt install -y wget apt-transport-https gpg
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
  | sudo gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo $VERSION_CODENAME) main" \
  | sudo tee /etc/apt/sources.list.d/adoptium.list
sudo apt update && sudo apt install -y temurin-21-jre
java -version   # expect: openjdk version "21.0.x"
```

### OS-level tuning (run once)

The script `scripts/setup-ubuntu-server.sh` in this repo does all of this; the reasoning:

| Setting | Value | Why |
|---|---|---|
| CPU governor | `performance` (or `tuned-adm profile latency-performance`) | Removes frequency ramp latency — the classic "first join after idle is laggy" symptom. Costs ~8–10 W at idle. |
| `vm.swappiness` | `10` | Keep the JVM heap in RAM; swap only as an emergency. |
| Swap | 8 GB zram **or** small NVMe swapfile | Insurance against a GC spike, not a working set. |
| THP | `madvise` | G1/ZGC ask for huge pages explicitly; `always` causes latency spikes. |
| File limits | `nofile 65535` for the service user | 30 players × chunk packets will exhaust 1024. |
| `net.core.rmem_max`/`wmem_max` | `16 MB` | 30 concurrent players, more if you peer over the internet. |
| Time sync | `systemd-timesyncd` | Backups and logs you can trust. |
| Firewall | `ufw allow 25565/tcp`, SSH rate-limited | Don't expose anything else. |
| Updates | `unattended-upgrades` (security only) | Patch without surprise restarts. |

---

## 5. JVM flags and heap sizing

For **30 players / 15–20 mods / 12–16 GB heap**, Aikar's G1GC flags are the proven default. ZGC is the alternative once you're above ~20 GB heap.

```bash
# 16 GB heap, Aikar's flags (recommended)
java -Xms16G -Xmx16G \
  -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \
  -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch \
  -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M \
  -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 \
  -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 \
  -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 \
  -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 \
  -Dusing.aikars.flags=https://mcflags.emc.gs \
  -jar forge-1.20.1-47.4.0-shim.jar --nogui
```

```bash
# Alternative for a bigger heap (24 GB+) or if you see GC pauses > 100 ms: Generational ZGC
java -Xms16G -Xmx16G -XX:+UseZGC -XX:+ZGenerational -XX:+AlwaysPreTouch \
  -Dusing.aikars.flags=https://mcflags.emc.gs -jar forge-1.20.1-47.4.0-shim.jar --nogui
```

Rules that matter more than the flag list:

- **`-Xms` == `-Xmx`** and **`AlwaysPreTouch`** — no heap growth stalls mid-fight.
- **Never** allocate more than ~60% of physical RAM. 16 GB heap on 32 GB is correct.
- **One JVM, one world.** Don't run two servers in one JVM.
- **Don't** `-XX:+UseParallelGC`: its stop-the-world full GCs are what produce 5-second freezes with 900 entities.
- Measure, don't guess: `/spark tps`, `/spark profiler --timeout 300`, then read the report. Target **MSPT ≤ 35 ms** at 30 players (20 TPS = 50 ms budget).

---

## 6. Forge server + the performance mods that actually matter

1. Install Forge **1.20.1 – 47.4.x** with the official installer (`java -jar forge-1.20.1-47.4.0-installer.jar --installServer`).
2. First run to generate configs, accept `eula=true`, then stop.
3. Drop in **Villager Recruits** + **Villager Workers** (Workers requires Recruits), then add these **server-side** performance mods — all have real 1.20.1 Forge builds:

| Mod | Effect on this workload |
|---|---|
| **Spark** | Profiler. Install first, always. Non-negotiable. |
| **ModernFix** | Startup time, memory use, several vanilla bottlenecks. Biggest single win on 1.20.1 Forge. |
| **FerriteCore** | Cuts blockstate/model and NBT duplication → materially lower heap per entity. Big with hundreds of villagers. |
| **Canary** (Lithium port) | Server-side AI/physics/POI/game-logic optimizations. |
| **Radium Reforged** | Forge port of Lithium's other half — pairs with Canary. |
| **Saturn** | Memory/GC micro-optimizations. Skip if it ever misbehaves with your mod set. |
| **Krypton Reforged** | Netty/network stack tuning — directly helps 30-player packet load. |
| **Clumps** | Merges XP orbs (workers killing mobs/farms generate piles). |
| **Noisium** | Faster chunk generation — matters while workers carve new terrain. |
| **Chunky** (Forge) | **Pre-generate the map before opening it to players.** Biggest TPS win available. |
| **AI Improvements** (optional) | Bounds some vanilla goal lookups; test — custom recruit AI may not benefit. |

Client-side only (do **not** put on the server): Embeddium, EntityCulling, ImmediatelyFast, Oculus.

> Reality check: these mods optimize *vanilla* systems. Recruit/worker AI is custom code and is **not** made cheaper by Canary/Lithium. The only real lever for that AI is the caps in section 7.

---

## 7. Mod-side tuning — this is what actually keeps you at 20 TPS

Hardware buys headroom. Configs decide whether you use it.

### 7.1 Villager Recruits

Config lives in two places:

- `<server>/config/recruits-common.toml` — global, mod defaults
- `world/serverconfig/recruits-server.toml` — **per-world, this is the one that applies on a server**

Keys that matter on a 30-player world:

| Key | Suggested | Why |
|---|---|---|
| `MaxRecruitsForPlayer` | **15–20** (default is ~100) | The single biggest TPS lever in the whole setup. 30 players × 20 = 600 recruits, which the 9800X3D handles. 30 × 100 = 3000 and no CPU on the market holds 20 TPS. |
| `RecruitsPayment` / `RecruitCost` / `RecruitCurrency` | keep on, meaningful cost | Payment forces players to choose a small standing army instead of hoarding. Economic caps beat config caps — they don't feel arbitrary. |
| `AllowClaiming` | on | Claims are what stop two players' armies from pathing into each other constantly. |
| `MaxClaimChunks` | small (e.g. 9–16) | Each claimed chunk is a place a player will park workers. Bounds total load. |
| `SiegeRequiresOwnerOnline` | **true** | Prevents sieges escalating against offline owners, which is where the AI pile-ups happen. |
| `SiegeClaimsRecruitsAmount` / `SiegeClaimsConquerTime` | keep defaults (10 units / 10 min) or raise | Bigger sieges = more entities pathing at once. |
| `OverrideIronGolemSpawn` | your call | Fewer iron golems = fewer entities, slightly less village defence. |

Also: group assignment targets **all loaded recruits within 100 blocks** — a 100-block radius around a base is your real entity budget, so keep bases apart rather than letting everyone build in one valley.

### 7.2 Villager Workers

Workers are Recruits under the hood, so every cap above applies. Their own config adds:

| Key | Suggested | Why |
|---|---|---|
| `ShouldWorkAreaOnlyBeInFactionClaim` | **true** | Stops work areas (and therefore workers) sprawling across the map. |
| `ShouldOnlyPlacingBuildingsBePossible` | true if you can live with it | Cuts builder-driven block churn, the most expensive worker behaviour. |
| `BuildMode` | `Preset` | Free-form building = constant block updates + chunk activity. |
| `AnimalPenMaxAnimals` | low (e.g. 8–16) | Animal pens multiply pathing and entity counts silently. |
| `FarmerPickup`, `LumberjackPickup`, `MinerPickup`, `FishermanPickup`, `AnimalFarmerPickup` | **false** where it doesn't hurt gameplay | Pickup behaviours generate item-entity churn and extra pathing per action. |
| `MinerIgnore` | add stone/deepslate variants you don't care about | Fewer block-break events and item spawns. |
| `VillagerBreedMixinEnabled` | keep on | Breeding only with enough saturation keeps villager counts from exploding. |

Practical rules for players:

- A **Crop Farm work area is 9×9**; several small farms near a storage beat one giant operation. Workers scan nearby containers for items — **more chests = more scanning**. Keep storage areas compact.
- **Give workers homes** (bed + chest, walled, roofed). Morale-driven thrash — workers walking back and forth failing to find storage or a home — is pure wasted tick time.
- **Never** let workers run in an unclaimed, unloaded frontier. Mining/farming out there forces chunk generation during play, which is the one thing that will spike MSPT above 50 ms with 30 players online.

### 7.3 The three rules that matter most

1. **Pre-generate** a 5,000-block radius with Chunky *before* launch (`chunky radius 5000`, `chunky start`).
2. **Cap recruits per player at 15–20** and keep claims small.
3. **Spread bases out.** 30 players in one village is a self-inflicted DDoS on the tick loop.

---

## 8. `server.properties` for this workload

| Key | Value | Reasoning |
|---|---|---|
| `max-players` | `30` | Match reality, not 100. |
| `view-distance` | `6` | 30 players × 6 chunks is still a lot of chunk data; 8+ is a waste for gameplay. |
| `simulation-distance` | `4` | **The** server-side performance knob. 4 keeps entities ticking only near players. |
| `entity-broadcast-range-percentage` | `80` | Fewer far-away entity packets; villagers look the same at 80%. |
| `network-compression-threshold` | `256` (try `-1` for modpacks) | Modded packets are large and irregular; test both, watch CPU vs bandwidth. |
| `sync-chunk-writes` | `false` | Faster saves; safe **because** you have a UPS and backups. |
| `max-tick-time` | `60000` | Let a slow tick recover instead of watchdog-killing the server mid-siege. |
| `enable-command-block` | `false` | Unless you need it. |
| `spawn-protection` | `0` | Claim/faction system handles protection. |
| `online-mode` | `true` | Unless you're behind a proxy with its own auth. |
| `difficulty` | `normal` | More mobs = more pathfinding. Hard is fine if TPS holds. |

A ready-to-use file with these values is in `config/server.properties`.

---

## 9. Network and bandwidth

Modded servers are upload-bound, and this one is worse than most because every recruit's state (equipment, orders, GUI data, morale) is synced.

| Item | Guidance |
|---|---|
| **Upload** | Budget **1–1.5 Mbps per active player** at peak (fighting, sieges, many villagers in view) → **≥ 50 Mbps upload** for 30 players with headroom. 20 Mbps will work until the first big siege. |
| **Latency** | What players feel. Wired fibre, no bufferbloat (enable SQM/cake on the router if you can). |
| **NIC** | Onboard 2.5 GbE → any gigabit switch is fine; the internet link is the limit. |
| **Exposure** | Port-forward **only 25565/tcp**. Never expose RCON (25575) to the internet. |
| **CGNAT / no port forward** | Use a tunnel: Tailscale (private, best for friends), playit.gg, or a cheap VPS running `ssh -R`/WireGuard. |
| **DDoS** | Home IPs get hit. Either accept it, front with a cheap VPS + firewall, or use a tunnel provider that absorbs it. |
| **Router** | Set a **static DHCP lease** for the server so port forwards survive reboots. |

---

## 10. Running it: systemd, backups, monitoring, UPS

**Service.** Run Forge under `systemd` (not `screen`), so it restarts on crash and starts on boot. Unit file: `systemd/minecraft.service` in this repo.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now minecraft@forge   # or minecraft.service
journalctl -u minecraft -f                    # live log
```

**Backups — the part everyone regrets skipping.** `scripts/backup-world.sh` does the sequence that is actually crash-consistent, which is *not* `cp -r` and *not* hardlink snapshots:

1. `save-off` → `save-all flush` over RCON (quiesced region files)
2. wait for the flush to reach disk
3. stream `world/` into a **compressed, immutable archive** (`zstd`, `gzip` fallback) with a `.sha256` sidecar, then `zstd -t` / `gzip -t` verify it
4. `save-on` immediately after the archive is on disk
5. rotate: **24 hourly + 7 daily + 4 weekly**, then optionally `restic`/`rclone` off-site

Why archives and not `rsync --link-dest`: Minecraft truncates and rewrites region files in place, so a hardlinked "unchanged" file in an old snapshot mutates along with the live world — the corruption shows up exactly when you need the backup. Immutable archives cost a little space and remove the failure mode. Restore is one command, printed by the script:

```bash
zstd -t world-20261109T203000Z.tar.zst && \
  tar -C /opt/minecraft -xf <(zstd -dc world-20261109T203000Z.tar.zst)
```

Schedule with cron/systemd timer **every 30 minutes**. A modded world with worker block changes is functionally irreplaceable — no seed gets it back. If you'd rather have instant, zero-copy snapshots, format the world SSD as **btrfs** and use `btrfs subvolume snapshot` instead; keep the archive script pointed at the 4 TB HDD either way.

**Monitoring.**
- In-game: `/spark tps`, `/spark health`, `/spark profiler --timeout 300` — the only numbers that matter are **MSPT** and **TPS**.
- Host: `node_exporter` + Prometheus/Grafana, or the simplest thing that works: `sudo apt install prometheus-node-exporter` and a Grafana Cloud free tier. Watch CPU per-core, load average, NVMe `%util` and `temperature`, and RAM used vs heap.
- Alert on **TPS < 19 for 5 min** and **CPU temp > 85 °C**.

**UPS.** With the CyberPower + NUT:

```bash
sudo apt install -y nut
# /etc/nut/ups.conf:  [cyberpower]  driver=usbhid-ups  port=auto
# /etc/nut/upsmon.conf: MONITOR cyberpower@localhost 1 upsmon <pass> primary
sudo systemctl enable --now nut-server nut-monitor
```
Set `upsmon` to trigger a clean shutdown at ~20% battery. This is what prevents the one failure mode that actually loses a world.

**Power and heat (real numbers).**

| State | Wall power |
|---|---|
| Idle (server up, 2–3 players) | 45–60 W |
| 30 players, heavy AI | 160–210 W |
| Boot / world load spike | ~250 W |

At 200 W average and $0.17/kWh: **≈ $300/year** to run. Idle-dominant servers sit nearer $90–120/year. A 1500 VA UPS gives ~8–12 minutes at 200 W — plenty for a clean save-and-stop.

---

## 11. Validation plan (do this before you invite 29 friends)

1. **Burn-in the hardware:** MemTest86 one full pass, then 30 min of `stress-ng --cpu 8 --vm 4` watching temps (target < 85 °C, no throttling).
2. **Install + boot Forge bare** (no world) — confirm Java 21, mods load, no missing dependencies.
3. **Pre-generate** with Chunky: `chunky radius 5000`, `chunky start`, wait it out. Expect several hours; run it overnight.
4. **Baseline:** with 1 player, `/spark tps` → should be 20.0 TPS, MSPT < 10 ms at spawn.
5. **Ramp test:** bring players on 10 → 20 → 30, each stage 15 min with real activity (a siege, workers running, players fighting). Record MSPT at each stage.
6. **Acceptance criteria:** **MSPT ≤ 35 ms and TPS ≥ 19.9 at 30 players** with caps in section 7 applied. If you're above 35 ms, in order: lower `MaxRecruitsForPlayer`, lower `simulation-distance` to 3, reduce `view-distance` to 5, lower `AnimalPenMaxAnimals`, then add a second physical server. Hardware is the *last* lever, not the first.
7. **Profile before you buy anything else:** `/spark profiler --timeout 300`, then look for the top entries — `RecruitEntity`/`WorkerEntity` tick will dominate, which confirms the fix is caps, not silicon.

---

## 12. Honest expectations

| Player count × recruits | What a 9800X3D does |
|---|---|
| 30 × 5–10 | Comfortable 20 TPS, lots of headroom |
| **30 × 15–20** | **~20 TPS with view-distance 6 / simulation-distance 4 — this is the design point** |
| 30 × 30–40 | 16–19 TPS with dips during sieges; playable but noticeable |
| 30 × 50+ | Sub-15 TPS. No consumer CPU fixes this — it's single-thread-bound AI |

Two things worth saying plainly:

- **No $2,500 box runs 3,000 custom-AI villagers at 20 TPS.** If someone tells you otherwise, they haven't profiled these mods. The build above is the right hardware for the job; the config is what makes the job possible.
- **The GPU in the budget is $0 and that is correct.** A Minecraft *server* does no rendering. Every dollar belongs in single-thread CPU, fast RAM, storage redundancy and power protection.

---

## 13. Sources

- Villager Recruits (CurseForge, talhanation) — mod description, claim/siege mechanics, per-world `serverconfig` split; wiki: group assignment = loaded recruits within 100 blocks
- Villager Workers (CurseForge/Modrinth) — requires Recruits; work-area and config option list (`AnimalPenMaxAnimals`, `BuildMode`, `ShouldWorkAreaOnlyInFactionClaim`, pickup toggles); 9×9 crop farm; storage-area scanning
- Villager Recruits config keys (`MaxRecruitsForPlayer`, `MaxClaimChunks`, `SiegeRequiresOwnerOnline`, …) — hosting-provider documentation + `recruits-common.toml` / `recruits-server.toml`
- Forge 1.20.1 runtime requirements — Java 17 minimum, Java 21 recommended; Java 25 support in current 47.x builds
- Ubuntu 26.04 LTS release (23 Apr 2026, kernel 7.0, Java 25); Debian 13 stable (Aug 2025)
- Nov 2026 pricing: Ryzen 7 9800X3D $399 (Newegg), 32 GB DDR5-6000 CL30 $429–460, 2 TB PCIe 4.0 NVMe ~$380–450, DDR5/NAND shortage coverage (TrendForce, Tom's Hardware, GamersNexus)
