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
graduate()  — permissionless (or auto-triggered by the next swap), when level reaches farLevel (top of curves)
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
| Pre-graduation mechanism | **Nested curve** (Doppler Multicurve algorithm), fixed template, JIT-minted | 32 nested positions staircase liquidity toward the far level: scarcer cheap supply at genesis, higher average execution. Position 0 at genesis, the rest deploy ahead of the price. |
| Graduation architecture | **In-place morph**, single hook | No migration exploits, no second pool/hook, no Airlock machinery; sa1t-proven pattern. |
| Custody | **Direct hook balance** (flaunch-style) | No ERC-6909 claims primitive needed beyond mid-swap settlement; ladder needs real positions anyway. |
| LP lock | **Code-locked, hook-held** full-range | No removal code path; hard `LPLocker` is the v2 upgrade. |
| Launch shape | **Fixed protocol template** + anchored opening FDV | Uniform terms for every launch (Virtuals posture); the validator guards only the per-launch knobs; opening FDV anchored in ETH. |
| Launch model | **Signed config, permissionless relay** | Creator pays nothing (EIP-712 config + deadline); anyone relays; creator = recovered signer; dev buy only on creator self-launch. |
| Failure branches | **None in v1** | No minimum proceeds, no refund window, no duration — those were DDA baggage. Dead tokens trade on curves indefinitely (v2: time-based fallback). |
| Anti-snipe | **None — structural mitigation** | Nested JIT thin books, whale-paid deploy gas, creator dev buy; sniping accepted (pump.fun posture). The 99%→1% decay wall is removed. |

---

## 3. System obligations & reference decomposition

### Binding obligations

The implementation must satisfy these capabilities regardless of how the code is organized:

| Obligation | Requirements |
|---|---|
| Permissionless launch entry | Validate launch config against §9 bounds; deploy token, hook (mined address), and pool; execute optional dev buy. |
| Single-hook protocol core | One hook owns the entire lifecycle: phase state machine, nested bonding curve, ladder bands, simulated deployment, harvest settlement, fee collection/routing, vesting, launch-signature verification. In-place graduation — no second pool/hook, no migration path. |
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
| `beforeSwap` | **Simulated deployment**: walk the swap's price path with v4 swap math; mint every undeployed curve step it crosses before it fills. Auto-graduate if the level is already at or above `farLevel` (Decision: the crossing swap's own `afterSwap` cannot graduate — its proceeds are unsettled mid-swap) | **Simulated deployment**: same walk over the ladder — mint every undeployed band the path crosses (cap 8/swap, overflow skips benignly). Auto-graduate check first |
| `afterSwap` | Track nothing critical (curves are passive positions) | **Harvest loop**: every deployed band whose top the post-swap level has crossed is completed and routed, up to 8 per swap; fee step-down applied at template thresholds |
| `beforeAddLiquidity` / `beforeRemoveLiquidity` | Revert unless sender is the hook (no external LPs; curves hook-owned) | Same; full-range and bands hook-owned |

Transient-storage locks (`tstore`/`tload`, StoreKeys pattern from flaunch) guard all settlement paths against reentrancy from nested swaps.

---

## 5. Pre-graduation: nested bonding curve

The Doppler Multicurve algorithm (Adams, Czernik, Kulkarni, Kunz, April 2025 — eqs. 3.1–3.2), reimplemented in level space with attribution; the vendored implementation is BUSL-licensed and is reference, not dependency:

- **Fixed template**: 32 nested single-sided token positions, position *i* spanning `[openingLevel + i·span/32, farLevel]`, each holding an equal share of the 25% curve supply. Liquidity staircases upward — thin at the opening, dense at the far level — so cheap supply is scarce at genesis and average execution rises with demand (the paper's anti-snipe finding).
- **Opening FDV anchored**: the pool opens at the level where the launch's total supply is valued at the protocol's ETH-denominated opening FDV (125 ETH template default). Every launch opens at the same valuation regardless of supply.
- **JIT-minted**: position 0 mints at genesis (pool tradable in the launch tx); positions 1–31 mint just before price reaches them via the same simulation path that deploys ladder bands. Launch gas is independent of position count.
- **No rebalancing, no epochs, no duration** — deployed positions are held; the only liquidity change is the protocol deploying its own next template position.
- **Graduation**: when the level reaches `farLevel`, the next swap's `beforeSwap` graduates automatically; permissionless `graduate()` races it. The crossing is verified at call time — protection is cost-based (the attacker pays the full curve spread; residual risk in §10).

### Graduation flow

1. Burn all curve positions; collect balances + accrued fees. Unbought inventory and curve token fees return to hook custody as ladder inventory.
2. Split bonding curve quote proceeds: **40% LP seed / 55% creator accrual (NFT) / 5% protocol** (template-fixed).
3. Mint the **full-range LP**: 40%-share ETH + 10% of supply, at the graduation price. Code-locked: no removal path exists in the hook. Its swap fees accrue to the hook-owned position and are collected via the permissionless `collectFees` path (§7).
4. Phase → `GRADUATED`. Ladder live.

**Dead tokens (v1)**: if price never reaches `farLevel`, the pool trades on its curves indefinitely. Buyers are never trapped — curves are real two-sided liquidity, sells always possible. v2: time-based fallback (force-graduate after N days with partial raise).

---

## 6. Milestone ladder — mechanics

### 6.1 Geometry

- **Bands = narrow tick ranges (limit-order semantics)**, width = 20% of the band gap (≈4.5% of price). Price entering a band partially fills it; crossing above `band.upper` completes it (position now 100% ETH — harvested).
- **Spacing: uniform level offsets from the fixed template.** 2,235 levels per band = a 1.25× market-cap step; 30 core bands + up to 30 fee-funded extensions; reach ≈ 807× graduation mcap. Geometry is identical for every launch — no per-launch or per-band overrides.
- **Inventory: even split of the 65% ladder supply** (~2.2% per band), topped from the milestone fund (≤2× cap) and carried residue.

### 6.2 Simulation-driven deployment

Bands are **not** deployed at graduation. On each buy, `beforeSwap` walks the swap's price path with v4's own swap math over the pool's fully deterministic, protocol-owned liquidity profile, and mints **every undeployed band the path crosses before the swap executes** — so the swap fills them as real liquidity.

- A deployed band cannot be jumped without filling: exiting a band's top requires consuming its entire inventory, which is completion by definition. The legacy deploy-window straddle deadlock (an undeployed band straddling spot) cannot occur.
- Deployments are capped at 8 bands per swap; a buy crossing more carries the excess forward benignly (skip-and-carry fallback). Sells never deploy.
- Simulation/rounding mismatches can only *under*-deploy — the fallback is the legacy carry, never over-selling.
- Whales pay the deploy gas for the positions they consume. Geometry is deterministic from the template — observers can compute every band; "hidden" means not yet deployed, not unknown.
- **No swap gating**: all swaps flow freely in both directions at every price — the hook never reverts a swap. In-band oscillation is possible, but every churn cycle pays the spread twice, and the harvest is atomic in the crossing swap's `afterSwap`.

### 6.3 Harvest settlement (atomic in `afterSwap`, bounded loop)

1. Post-swap level at or above a deployed band's upper tick → mark complete → burn the band (collect quote + accrued band fees; any token residue to carried inventory).
2. The harvest **loop** repeats for every band completed by the same swap, up to 8; deeper sweeps settle on the next swap.
3. Route per the **global split config** (`creatorWad, buybackWad, protocolWad, lpWad`, sum = WAD, per-launch within template bounds):
   - `creator` → NFT claimable balance (pull-based)
   - `protocol` → protocol claimable balance (pull-based)
   - `buyback` → nested `poolManager.swap` (ETH→token) behind the transient lock → burn
   - `lp` → re-minted into the full-range position
4. MILESTONE_FUND token-fee accrual (§8.1) is credited to the next band's inventory.

### 6.4 Abandoned bands

Reclaim is **removed**. A deployed band the market never completes is a permanent standing limit order: a returning market fills it at its level (folding its accrued fees into the normal harvest); a dead token leaves its inventory and fee accrual parked in the position — accepted leakage, recorded in the risk register.

---

## 7. Fees

### 7.1 Swap fee

Pool fee **1% flat from genesis** (no launch window; milestone-completion step-down per §8.2 when thresholds are crossed), routed at fee collection:
- **60% LP** — stays in the full-range position (compounds); ladder bands also earn fees while in range, folding into their harvests
- **30% creator** — NFT claimable (ETH-denominated)
- **10% protocol** — pull-based (ETH-denominated)

**Token-denominated fees are never paid to a person**: the 20% MILESTONE_FUND diversion applies first, and the remainder compounds into the full-range position (paired with the quote-side LP share; unpairable remainder carries to the next collection).

Collection: a zero-delta `modifyLiquidity` is v4's collect — it realises accrued fees while leaving the position untouched. Permissionless `collectFees` trigger.

### 7.2 Milestone-completion dynamic fee

Base fee steps down as milestones complete — "trust earned" pricing that rewards surviving tokens with cheaper trading. Thresholds and steps are **template constants** scaled to the band count (default: 1.0% → 0.75% at 8 completions → 0.5% at 16; floor 0.25%, max 2 steps), applied in `afterSwap` at each harvest via `updateDynamicLPFee`. There is no launch-window decay: the fee can only decrease, at most twice, ever.

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

Covered in §7.2: template-fixed step-down thresholds (completions 8 and 16 on the 30-band template), permanent, floored at 0.25%, applied via `updateDynamicLPFee` at the crossing harvest. `DYNAMIC_FEE_FLAG` exists solely for this.

### 8.3 Milestone dividends (v2)

The routing enum's `airdrop` destination: a completed milestone's creator share can optionally distribute pro-rata to holders at snapshot (merkle). "Your token crossed a milestone, and you got paid for holding." Reserved in the enum from day one.

---

## 9. Launch parameters & guardrails

**Fixed protocol template** (hook constructor argument — immutable, identical for every launch):

| Parameter | Value |
|---|---|
| Curve shape | 32 nested positions (Doppler algorithm), 2× span, position 0 at genesis |
| Opening FDV | 125 ETH (ETH-denominated anchor; start level derived from supply) |
| Curve supply share | 25% |
| Ladder | 2,235-level spacing (1.25×), 30 core bands, 447-level walls (≈4.5% of price) |
| Ladder supply share | 65% (~2.2%/band) |
| Full-range LP share | 10% |
| Milestone-fund share | 20% of token fees (≤2× per band, ≤30 fee-funded bands) |
| Base fee | 1% flat; step-downs at completions 8/16 → 0.75%/0.5% (floor 0.25%) |
| Graduation split | 40/55/5 (LP seed/creator/protocol) |
| Fee routing | 60/30/10 (LP/creator/protocol) |
| Deploy / harvest caps | 8 bands per swap each |
| Fee-funded extension | ≤30 bands |

**Per-launch configuration** (the entire validator surface):

| Parameter | Bounds |
|---|---|
| Token metadata, total supply | standard; opening level derived from supply + template FDV anchor |
| Dev buy | off by default; ≤10% of supply, vesting 0–12 months, creator-self-launch only |
| Harvest split | 60/20/10/10 default (creator/buyback/protocol/LP); creator ≤70%, buyback ≥10%, protocol ≥5% |

**Dev buy** (Virtuals Team Initial Buy pattern, capped): executes only when the creator relays their own launch; buys at the initial price against the curve like any buyer; on-chain transparent at launch. No free creator allocation — creators earn through harvest routing and the fee NFT.

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
| Stale/unfilled bands | Standing limit orders hold inventory and fee accrual indefinitely | Accepted (reclaim removed): a returning market fills the band naturally; stranding is conditional on permanent death and is fee-sized, not principal |
| Launch-relay signature risks | Relayed deployments on stolen/stale signatures | EIP-712 over the full config + deadline; CREATE2 config-hash salt makes replay fail on the existing deployment; relayer cannot alter economics |
| Creator degenerate config (bands at absurd mcaps, oversized dev buy) | Cheap harvests, wash-trade surface | Protocol bounds on every launch parameter (§9); dev buy on-chain transparent at launch |
| Fee-collect griefing | Permissionless sliver burn+re-add spam | Bounded per-call cost; net position unchanged |

---

## 11. Monorepo integration map

Borrow directly from the vendored protocols in this repo:

| What | From | Where |
|---|---|---|
| Phase enum + in-place graduation pattern | sa1t | `sa1t-contracts/src/Sa1tHookV2.sol` (phase enum L42, `graduate` L563) |
| Multicurve curves: `Curve[]`, `adjustCurves`, `calculatePositions`, log-normal fan, `farTick` graduation | Doppler | `doppler/src/libraries/Multicurve.sol`, `doppler/src/initializers/DopplerHookInitializer.sol` — **algorithm only** (BUSL-1.1 licensed; reimplemented in level space with attribution, per §5) |
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
- Dead inventory options: reprice, burn, or holder airdrop.والے