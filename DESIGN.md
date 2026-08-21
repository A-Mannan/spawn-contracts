# Milestone Launchpad — Design Specification

A generic token fundraising launchpad on Uniswap v4 hooks. Core USP: **fundraising milestones modeled as v4 liquidity positions** — a protocol-owned ladder of one-sided sell-limit bands at ascending market-cap levels, harvested automatically when the market reaches them, with configurable routing of the harvested value.

Inspired by Virtuals Protocol's Automated Capital Formation (team allocation locked until FDV milestones, auto-executed limit-sells, proceeds to founders) and validated by Pumpkin's single-sided milestone positions on Solana. None of the existing launchpads in this monorepo (sa1t, flaunch, Clanker/Liquid, Zora, Doppler, Liquidity Launcher) implement milestone harvest events with configurable routing — the ladder is the differentiator.

Target chain: **Base**. Solidity `0.8.26+`, EVM `cancun` (transient storage required). Stack: v4-core / v4-periphery per Clanker/Liquid pins (`5f00c84` / `9628c36`) or sa1t's imports, Foundry.

---

## 1. Thesis

The milestone ladder is a **continuous, retroactive fundraiser**: instead of raising a fixed amount once at launch (LBA) or never (instant AMM), a project raises in lockstep with its token's performance. Each milestone band is a single-sided token position at a target market cap. When the market pushes price into a band, the core AMM fills it — the band's tokens convert to ETH, "harvesting" the milestone. No oracle, no keeper: **the price reaching the level IS the trigger**, mechanically self-executing via real v4 positions.

Three properties make this worth building:
- **Protocol-owned inventory** — no external LP exposure, no rug surface, no JIT-LP manipulation during fundraising.
- **Self-executing walls** — a stepped price-discovery profile where each level is a committed, auditable sell wall.
- **Configurable harvest routing** — proceeds flow through one global split (creator / buyback / protocol / LP / milestone fund), extensible to airdrop, treasury, staking (v2).

---

## 2. Lifecycle (two phases, one pool, one hook)

```
BONDING_CURVE (multicurve curves, demand-driven)
   │   curves minted once at launch; price rises as buyers fill them
   │   NOT time-bound; buyers can always sell back (curves are real two-sided liquidity)
   ▼
graduate()  — permissionless, when tick reaches farTick (top of curves)
   │   burn curves → split proceeds → mint full-range LP
   ▼
GRADUATED (full-range LP + milestone ladder)
   │   ladder bands JIT-deployed above spot; harvested on completion; routed per config
   │   fee-funded bands extend the ladder indefinitely
   ▼
mature pool (full-range LP locked forever, ladder active or exhausted)
```

Key architectural decisions (from design session):

| Decision | Choice | Rationale |
|---|---|---|
| Pre-graduation mechanism | **Multicurve** (Doppler/Zora pattern) | Demand-driven, no time-decay dump pressure; proven on Base (Zora). Dynamic Dutch Auction deferred to v2. |
| Graduation architecture | **In-place morph**, single hook | No migration exploits, no second pool/hook, no Airlock machinery; sa1t-proven pattern. |
| Custody | **Direct hook balance** (flaunch-style) | No ERC-6909 claims primitive needed; ladder needs real positions anyway. |
| LP lock | **Code-locked, hook-held** full-range | No removal code path; hard `LPLocker` is the v2 upgrade. |
| Failure branches | **None in v1** | No minimum proceeds, no refund window, no duration — those were DDA baggage. Dead tokens trade on curves indefinitely (v2: time-based fallback). |
| Anti-snipe | **Dynamic fee decay** 99%→1% over creator-chosen window | `DYNAMIC_FEE_FLAG` + `updateDynamicLPFee` block-step decay; no per-swap delta accounting. |

---

## 3. System obligations & reference decomposition

### Binding obligations

The implementation must satisfy these capabilities regardless of how the code is organized:

| Obligation | Requirements |
|---|---|
| Permissionless launch entry | Validate launch config against §9 bounds; deploy token, hook (mined address), and pool; execute optional dev buy. |
| Single-hook protocol core | One hook owns the entire lifecycle: phase state machine, multicurve curves, ladder bands, JIT deployment, harvest settlement, fee collection/routing, vesting, anti-snipe. In-place graduation — no second pool/hook, no migration path. |
| Transferable creator revenue NFT | Pull-based claims on the creator's share of harvests, swap fees, and bonding curve proceeds. Transferable — the revenue stream itself trades (flaunch FeeNFT pattern). |
| Standard token | Plain ERC20 (Permit2 optional); full supply minted to the hook at launch. |

### Reference decomposition (illustrative, non-normative)

One viable shape is four contracts — `MilestoneFactory`, `MilestoneHook`, `CreatorFeeNFT` (`tokenId = poolId`), `MilestoneToken`. **This is an example, not a prescription.** Use your own names, file layout, and separation of concerns; extract libraries, merge or add contracts freely wherever it improves gas, performance, clarity, auditability, or **security** (e.g., smaller attack surface, fewer external entry points, custody kept in the hook). The only requirements: every obligation above holds, the invariants of §1/§2/§10 are preserved, and no decomposition choice may widen the trust surface beyond what this document describes.

### Hook permissions (flags)

`beforeInitialize`, `afterInitialize`, `beforeSwap`, `afterSwap`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `DYNAMIC_FEE_FLAG`. Hook address mined via `HookMiner`.

---

## 4. Hook state machine

```solidity
enum Phase { NONE, BONDING_CURVE, GRADUATED }
```

| Callback | BONDING_CURVE | GRADUATED |
|---|---|---|
| `beforeInitialize` | Revert unless self/factory | — |
| `afterInitialize` | Mint multicurve fan positions (`[startingTick_i, farTick]` per curve, log-normal distribution); execute optional dev buy | — |
| `beforeSwap` | Anti-snipe: `updateDynamicLPFee` decay step (99%→1% over window) | **JIT deploy trigger**: if pre-swap tick ∈ `[band.lower − K, band.lower)` and the swap moves toward the band, mint the band |
| `afterSwap` | Track nothing critical (curves are passive positions) | **Harvest detection**: post-swap tick ≥ `band.upper` && deployed && !completed → collect band, route proceeds, execute buyback behind a transient-storage lock |
| `beforeAddLiquidity` / `beforeRemoveLiquidity` | Revert unless sender is the hook (no external LPs; curves hook-owned) | Same; full-range and bands hook-owned |

Transient-storage locks (`tstore`/`tload`, StoreKeys pattern from flaunch) guard all settlement paths against reentrancy from nested swaps.

---

## 5. Pre-graduation: multicurve curves

Direct port of Doppler's `Multicurve` production system (as used by Zora):

- `Curve[]` — each curve: `tickLower`, `tickUpper`, `numPositions`, `shares` (sum = WAD). Slopes configurable per launch (phased pricing: early discount → steeper later).
- Positions distributed via `Multicurve.calculatePositions` — log-normal fan `[startingTick_i, farTick]` per curve, `LiquidityAmounts.getLiquidityForAmount0/1`.
- Pool initialized at the lowest curve boundary; **no rebalancing, no epochs, no duration** — "positions set once and held" (Doppler's words).
- **Graduation**: permissionless `graduate()` when current tick ≥ `farTick` (negate for token1 orientation). The crossing is verified at call time — a flash pump can technically trigger graduation mid-tx, but the protection is **cost-based**: the attacker pays the full curve spread (buys through curves at rising prices, holds real token), and the proceeds remain in the pool. Graduation cannot be forced cheaply or profitably (residual risk documented in §10).

### Graduation flow

1. Burn all curve positions; collect balances + accrued fees.
2. Split bonding curve proceeds: **40% LP seed / 55% creator accrual (NFT) / 5% protocol** (LP-seed share configurable, floor 20%).
3. Mint the **full-range LP**: 40%-share ETH + 10% of supply, at the graduation price. Code-locked: no removal path exists in the hook. Its swap fees accrue to the hook-owned position and are collected via the permissionless `collectFees` path (§7).
4. Phase → `GRADUATED`. Ladder live.

**Dead tokens (v1)**: if price never reaches `farTick`, the pool trades on its curves indefinitely. Buyers are never trapped — curves are real two-sided liquidity, sells always possible. v2: time-based fallback (force-graduate after N days with partial raise; ladder inventory reclaim rules then apply).

---

## 6. Milestone ladder — mechanics

### 6.1 Geometry

- **Bands = narrow tick ranges (limit-order semantics)**, width ≈ 5–10% of the band gap. Price entering a band partially fills it; crossing above `band.upper` completes it (position now 100% ETH — harvested).
- **Spacing: uniform tick offsets.** A 2× market-cap step is a constant 6,931 ticks (`ln2 / ln1.0001`) — uniform in tick space = geometric in mcap space. Config: `{ bandCount, bandTickSpacing, bandWidthTicks, ladderSupplyShare }` — **one setting for all bands**.
- **Default template**: 8–10 bands from the graduation price, 2× mcap per band, even inventory split of **65% of supply** (25% bonding curve / 65% ladder / 10% full-range LP).

### 6.2 JIT deployment

Bands are **not** deployed at graduation. `beforeSwap` mints the next band when the pre-swap tick enters the deploy window `[band.lower − K, band.lower)`, `K ≈ 2–5% of the band gap`:

- Atomic with the approaching swap — even a candle that sweeps the whole band fills it correctly (the trigger fires pre-crossing).
- A band jumped entirely in one tx (pre-swap tick already above it) is skipped benignly: inventory stays in hook custody, re-targeted at the next band.
- Trigger fires only on swaps moving toward the band (buys); sells entering the deploy window do not mint (no wasted mints, no premature exposure).
- JIT keeps launch gas cheap (no 10 mints at init) and no idle position state. Note: band geometry is fully deterministic from launch config — observers can compute every band's ticks and size; "hidden" means not deployed, not unknown.
- Bands below spot never deploy (they'd be empty ETH positions).
- **No swap gating**: all swaps flow freely in both directions at every price — the hook never reverts a swap. In-band oscillation is possible (a trader can churn a partially-filled band's conversion state), but every churn cycle pays the spread twice, and the milestone completes the instant price exits the band's top — harvest is atomic in the crossing swap's `afterSwap`. Harvest-at-crossing, not swap blocking, is the anti-stall mechanism.

### 6.3 Harvest settlement (atomic in `afterSwap`)

1. Tick crosses `band.upper` → mark completed → burn the band position (collect token remainder → ETH + accrued swap fees, which fold into the harvest).
2. Route per the **global split config**: `{ creatorWad, buybackWad, protocolWad, lpWad }` (sum = WAD):
   - `creator` → NFT claimable balance (pull-based)
   - `protocol` → protocol claimable balance (pull-based)
   - `buyback` → nested `poolManager.swap` (ETH→token) behind the transient lock → burn
   - `lp` → re-minted into the full-range position
3. MILESTONE_FUND token-fee accrual (§8.1) is credited to the next band's inventory.

### 6.4 Reclaim (permissionless)

A deployed band unfilled for **30 days** can be reclaimed by anyone: burn the position, inventory returns to hook custody and **re-targets the next-in-line band** (consistent with jumped-band handling above). No burning, no repricing in v1. v2 options for dead inventory: reprice, burn, or route to the airdrop destination.

---

## 7. Fees

### 7.1 Swap fee

Pool fee **1%** (default; milestone-completion decay per §8.2 when enabled), routed at fee collection:
- **60% LP** — stays in the full-range position (compounds); ladder bands also earn fees while in range, folding into their harvests
- **30% creator** — NFT claimable
- **10% protocol** — pull-based

Collection: v4 has no standalone `collect` — the hook burns a sliver of the full-range position and re-adds it (net position unchanged, fees harvested). Permissionless `collectFees` trigger.

### 7.2 Anti-snipe

Creator-chosen window (0s / 60s / 10 min / 98 min): dynamic fee decays **99% → 1%** in block steps via `updateDynamicLPFee` (LaunchFi/Zora pattern). The windfall lands in LP and flows through the standard 60/30/10 split — no special accounting.

### 7.3 Bonding curve proceeds

40% LP seed / 55% creator (NFT) / 5% protocol — §5.

---

## 8. Novel mechanisms

### 8.1 Token-fee recycling into the ladder (`MILESTONE_FUND`)

Sell-side swap fees accrue in **token**; buys accrue in ETH. A configurable slice (≤ **20%** of collected fees, default 20%) of the token-denominated fees is diverted from LP compounding into the **next-in-line band's inventory**:

- No swap, no spread, no directional bet — tokens arrive free from seller fees.
- **Counter-cyclical**: sell pressure funds future walls; rallies consume them.
- At JIT deploy time, band inventory = protocol supply share + accrued MILESTONE_FUND (capped at **2×** the protocol share; overflow carries to the next band).
- **Indefinite extension**: after the fixed core bands (8–10) are exhausted, fee-accrued tokens mint new bands at the same tick step — the fundraiser never ends while the token trades. Protocol cap: **30 fee-funded bands**, then fees revert to LP.

This is the BidWall inversion: flaunch spends fees buying *support* below spot; we spend fees loading *walls* above spot.

### 8.2 Milestone-completion dynamic fee

Base fee steps down as milestones complete — "trust earned" pricing that rewards surviving tokens with cheaper trading. Schedule is a **launch parameter** (default off): e.g., **1.5% → 1.0% → 0.5%** at cumulative completions **0 → 2 → 4**. Precedence: the anti-snipe window runs first (99% → base over the chosen window, §7.2); milestone steps apply to the base fee only, applied in `afterSwap` at each harvest via `updateDynamicLPFee`. Bounds: start ≤ 1.5%, floor ≥ 0.25%, max 2 steps.

### 8.3 Milestone dividends (v2)

The routing enum's `airdrop` destination: a completed milestone's creator share can optionally distribute pro-rata to holders at snapshot (merkle). "Your token crossed a milestone, and you got paid for holding." Reserved in the enum from day one.

---

## 9. Launch parameters & guardrails

| Parameter | Default | Protocol bounds |
|---|---|---|
| Band count | 8–10 | 3–15 |
| Band spacing | 2× mcap (6,931 ticks) | ≥ 1.5× |
| Band width | 5–10% of gap | config, validated |
| Ladder supply | 65% | ≤ 65%, per-band ≤ 15% |
| Dev buy | off | ≤ 20% supply, at initial price; consumes **bonding curve inventory**; cap bounded **below the bonding curve share** so the public raise always retains a minimum share (e.g., bonding curve 25% / dev cap 20%) |
| Dev buy vesting | none | 0–12 months linear, hook-held |
| Milestone fee decay | off | start ≤ 1.5%, floor ≥ 0.25%, ≤ 2 steps |
| Harvest split | 60/20/10/10 (creator/buyback/protocol/lp) | protocol min 5%, buyback max 40% |
| MILESTONE_FUND share | 20% of collected fees | ≤ 20%, ≤ 30 bands, ≤ 2× per-band |
| Anti-snipe window | 60s | 0s/60s/10min/98min |
| Bonding curve LP-seed share | 40% | ≥ 20% |
| Reclaim period | 30 days | configurable |

**Dev buy** (Virtuals Team Initial Buy pattern, capped): creator buys at the initial price during launch, executed by the hook against the **bonding curve like any buyer** — consuming bonding curve inventory, so the public raise shrinks proportionally; the cap is bounded below the bonding curve share so the public always retains a minimum share. Tokens vest linearly if chosen; purchases are on-chain transparent at launch. No free creator allocation — creators earn through harvest routing and the fee NFT.

---

## 10. Edge cases & risk assessment

| Vector | Exposure | Mitigation |
|---|---|---|
| JIT deploy race (candle jumps band before mint) | Missed harvest — inventory stays in custody, benign | Pre-swap-tick trigger fires before the crossing; missed bands re-target at next band |
| Band-boundary sandwiching | Seller is the protocol; worst case fill at band prices — bounded, no griefing | Bands single-sided and hook-owned; no external mint/remove path |
| Band oscillation dumping | Band conversion state churned in-band (buy low end, dump back) | No swap gating; each churn cycle pays the spread twice, and harvest-at-crossing is atomic — a genuine crossing completes the milestone the instant price exits the band's top; churn cannot prevent that |
| Flash-loan sweep through multiple bands | Milestones "complete" into a pump that crashes; harvests routed, inventory gone | Accepted: harvest-at-price is the design; holders' risk, not protocol's |
| Graduation manipulation (flash-buy to hit farTick) | Early graduation with thin real demand | Cost-based: attacker pays the full curve spread and proceeds stay in the pool; `graduate()` verifies tick at call time — residual risk documented, accepted |
| Buyback reentrancy | Nested swap recursion during settlement | Transient-storage lock (`tstore`/`tload`) around all settlement paths |
| LP extractability | Full-range removal | Code-locked (no removal path); v2 hard `LPLocker` |
| NFT claim griefing (buy NFT → claim → sell) | Revenue-claim theft | Current-holder claims (flaunch pattern); documented, accepted |
| Stale/unfilled bands | Dead inventory locked in positions | 30-day permissionless reclaim to custody; v2: reprice/burn/airdrop |
| Creator degenerate config (bands at absurd mcaps, oversized dev buy) | Cheap harvests, wash-trade surface | Protocol bounds on every launch parameter (§9); dev buy on-chain transparent at launch |
| Fee-collect griefing | Permissionless sliver burn+re-add spam | Bounded per-call cost; net position unchanged |

---

## 11. Monorepo integration map

Borrow directly from the vendored protocols in this repo:

| What | From | Where |
|---|---|---|
| Phase enum + in-place graduation pattern | sa1t | `sa1t-contracts/src/Sa1tHookV2.sol` (phase enum L42, `graduate` L563) |
| Multicurve curves: `Curve[]`, `adjustCurves`, `calculatePositions`, log-normal fan, `farTick` graduation | Doppler | `doppler/src/libraries/Multicurve.sol`, `doppler/src/initializers/DopplerHookInitializer.sol` |
| Anti-snipe fee decay | Zora / LaunchFi | `zora-coins/packages/coins/src/libs/CoinDopplerMultiCurve.sol` (launch fee 99%→1%), `launchfi-launchpad` (`updateDynamicLPFee`) |
| Transient-storage locks, FeeNFT, fee waterfall | Flaunch | `flaunchgg-contracts/src/contracts/PositionManager.sol` (`StoreKeys`, `_distributeFees` L931), `Flaunch.sol` (ERC721 revenue streams) |
| Nested pool swaps inside callbacks | Flaunch | `PositionManager.sol` `beforeSwap` (InternalSwapPool) |
| Hook address mining | LaunchFi / Liquidity Launcher | `launchfi-launchpad/uniswap/test/utils/HookMiner.sol` |
| Token factory / Permit2 token | uerc20-factory | `uerc20-factory/src/tokens/UERC20.sol` |
| Dev buy precedent | sa1t (optional dev buy), Clanker `Univ4EthDevBuy`, Virtuals Team Initial Buy (≤45%, we cap at 25%) | `sa1t-contracts/src/Sa1tFactoryV2.sol`, `v4-contracts/src/extensions/` |
| Fee routing matrix / LP reinvestment (v2 inspiration) | Doppler Rehype | `doppler/src/dopplerHooks/RehypeDopplerHookInitializer.sol` (2×4 routing matrix, binary-search balancing) |

**What does NOT exist anywhere in the monorepo** (and is the USP): milestone harvest *events* with configurable routing, JIT-deployed sell-limit bands, fee-recycling into ladder inventory, and the milestone-completion fee curve.

---

## 12. v2 roadmap

- Routing destinations: **airdrop** (milestone dividends), **treasury/vault**, **staking rewards** — enum slots reserved in v1.
- Hard `LPLocker` for full-range LP (external revert-lock).
- Dynamic Dutch Auction launch mode (high-value assets).
- Optional minimum-proceeds with cancel + full refund (serious-project guarantee).
- Dead-token fallback: force-graduate after N days below `farTick`.
- Weighted band inventory (front-load or back-load the ladder).
- Per-milestone routing overrides (beyond the single global split).
- Dead inventory options: reprice, burn, or holder airdrop.