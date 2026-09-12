# Integration Guide — Frontend & Data Layer

This is the handoff document for teams integrating with the Spawn launchpad: the frontend
(trading terminal, launch flow, claims) and the data layer (substreams-based indexer feeding a
Bloomberg-terminal-style launchpad view).

Companion artifacts:

| Artifact | Source | Contents |
| --- | --- | --- |
| `deployments/<chainId>.json` | written by `script/Deploy.s.sol` on broadcast | every deployed address, hook salt, canonical payout plan, template + economics snapshot |
| `abi/*.json` | `make abis` | curated ABIs (see section 10) |
| this document | `docs/technical/integration.md` | flows, formulas, event catalog, gotchas |

Normative sources if anything here looks wrong: `src/` (the code), `DESIGN.md`, and the
`openspec/changes/*/specs/` requirement blocks. When doc and code disagree, the code wins — file an
issue against this document.

---

## 1. Contract map

One deployed hook serves every launch; per-launch state is keyed by `PoolId`. There is **no
factory**, and **no migration**: each launch is one pool that morphs in place from bonding curve to
graduated.

| Contract | Role | Who calls it |
| --- | --- | --- |
| `MilestoneHook` | The protocol core. Launch entry, graduation, fee collection, flush, all three claim paths, every view. Holds all per-pool state. | Everyone, for everything |
| `LaunchSupport` | Read-only observers for the signed-launch flow (`launchDigest`, `predictToken`, `validate`, `configHash`, `domainSeparator`). Also the CREATE2 deployer of every launch token. | Frontend, relayers |
| `MilestoneToken` | Per-launch plain ERC20 (`burn(uint256)` extra). Whole supply mints to the hook at launch. | Token pages |
| `RevenueNFT` | One per launch, minted to the creator. **Current holder** holds the direct creator revenue claim right; transferring it transfers the unclaimed stream. | Claims pages |
| `PayoutPluginRegistry` | Append-only payout plugin registry, stable indices 0-255. Registration/suspension through governance. | Plugin pages, launch form |
| `ProtocolController` | Timelocked governance (economics tuple, plugin registration/suspension, protocol recipient, delay). | Governance UI |
| `BuybackAndBurnPlugin` | The reference `PAYOUT` plugin, registered at registry index 0 (the canonical plan). | Plugin devs |

Uniswap v4 addresses on Base:

- `PoolManager`: `0x498581fF718922c3f8e6A244956aF099B2652b2b` (pinned in `test/fork/ForkFixtures.sol`).
- `StateView` and `V4Quoter` (from `v4-periphery`): use Uniswap's published Base deployments and
  verify the codehash before trusting quotes. Record them in the deployment manifest once confirmed.

### The one rule that prevents broken integrations

`MilestoneColdPaths` and `MilestonePayoutPaths` are **delegatecall implementations**, not contracts
with an address you can call. Every state-changing entry they own is guarded by `onlyDelegated` and
reverts when called directly. Ship **only the hook's ABI** to signers; the satellite ABIs exist for
source verification, not interaction. Everything below routes through the hook address.

---

## 2. Orientation: `level = -tick`

This is the single most error-prone part of the protocol. Read it twice.

Native ETH is `address(0)`, so it is always `currency0`, and the launch token is always `currency1`.
Pool price in raw v4 terms is therefore **token-per-ETH** (`1.0001^tick` token-wei per ETH-wei):

- Token price up => raw price down => **tick down**.
- The protocol's own coordinate is `level = -tick`, which **rises** as the token pumps. Every
  user-facing number — opening level, far level, band geometry, "current milestone" — is a level.
- Convert exactly once at the pool boundary: read `tick` (`StateView.getSlot0`), negate it, and do
  all display/geometry arithmetic in level space.

Derived formulas (exact, no decimal handwaving — everything in wei):

```
ethPerTokenWei = 1.0001^level                  // ETH-wei per token-wei
fdvEthWei      = totalSupplyWei * 1.0001^level // FDV in ETH-wei, decimals cancel
```

For an 18-decimal token, human price in ETH equals `1.0001^level` numerically.

Useful level distances (template constants):

| Distance | Levels | Meaning |
| --- | --- | --- |
| `LEVELS_PER_DOUBLING` | 6931 | 2x market cap |
| `BAND_FIRST_STEP_LEVELS` / `BAND_STEP_DECAY_LEVELS` | 6932 / 391 | the first rung sits **2x** the graduation valuation; each successive gap shrinks by 391 levels |
| `BAND_LEVEL_SPACING` | 2235 | the ladder's spacing **floor**: **1.2504x** market cap, where the schedule locks |
| `BAND_WIDTH_LEVELS` | 447 | one band's wall: ~4.5% of price |

---

## 3. Lifecycle

`Phase` enum (0-indexed): `NONE = 0`, `BONDING_CURVE = 1`, `GRADUATED = 2`. It advances one way and
never reverts back. Read it via `poolPhase(poolId)` or from `poolState(poolId)`.

### 3.1 Bonding curve

- The launch mints curve **position 0 only** at genesis; positions 1-31 (template: 32 total) deploy
  just-in-time as a buy's simulated path approaches them.
- Position `i` spans levels `[opening + i * span/32, far]` holding only token. Curve supply is 25%
  of total supply (`curveSupplyShareWad`).
- `opening` is derived from supply so every launch opens at the template FDV:
  `openingLevel = log_1.0001(openingFdvWei / totalSupplyWei)` (template: 2 ETH FDV on the pinned
  1,000,000,000 supply; any other declared supply reverts `SupplyNotFixed`).
- `far = opening + curveSpanLevels` (template: +13,862 levels = **4x the opening FDV**, two 2x spans).

### 3.2 Graduation

- Trigger condition: live `level >= farLevel`, evaluated at call time — a pool that touched the far
  level and fell back has **not** graduated.
- Two racing paths, both permissionless: the **next buy's `beforeSwap` auto-graduates**, or anyone
  calls `graduate(key)` deliberately. Both are idempotent; the second one reverts having changed
  nothing.
- Graduation burns all curve positions. Quote proceeds split 20% LP seed / 70% creator / 10%
  protocol, and two code-locked positions are seeded — no removal path exists, and the hook rejects
  every third-party liquidity operation anyway (see 4.2). The **full-range** position is funded by
  the 20% seed (ETH-limited, ~72.77M of the 650M graduation tokens) and bounded to a market-cap
  range of ~$5,100 to ~$150B FDV. A **wall** position absorbs the remaining ~577.23M tokens as a
  single-sided, token-only reserve spanning the 880,000 levels above graduation at zero ETH cost —
  deep buy-side liquidity with a hard price floor.

### 3.3 Milestone ladder (the differentiator)

- Protocol-owned, one-sided **sell-limit bands** at ascending market caps. The schedule decays:
  band `i+1` starts `max(2235, 6932 - 391*i)` levels above band `i` (first step **2x** the
  graduation valuation, locking at the 2,235-level **1.2504x** floor), and
  `levelUpper(i) = levelLower(i) + 447`.
- 22 core bands (10% of supply, ~4,545,454.5 tokens each) reach roughly **2,900x** the graduation
  valuation (~$58M FDV at the $2,500/ETH reference); up to 30 fee-funded extensions (funded by the
  token-fee stream) continue above that at the floor spacing.
- Bands deploy JIT as a buy's path approaches them, and are **harvested** (burned into the pot) the
  moment a swap crosses a band's top. Harvests fund the payout pot that later flushes to plugins.
- Live set is `deployedBands & ~completedBands` and may hold several bands at once. Work per swap is
  capped at 8 deploys / 8 harvests; anything left settles on a later swap.
- A band whose lower bound is already behind spot when its turn comes is **skipped**
  (`BandSkipped`): its token share moves to carried inventory and the next band draws on it. This is
  a normal, specified outcome — display it as "milestone bypassed", not as an error.

---

## 4. Launching a token

### 4.1 The configuration

```solidity
struct LaunchConfig {
    address creator;          // declared; vouched for by the operator, or proven as sender
    string name;
    string symbol;
    string uri;               // off-chain metadata, stored as the token's tokenURI
    uint256 totalSupply;      // pinned to 1,000,000,000; any other value reverts (SupplyNotFixed)
    uint64  devBuyShareWad;   // <= 0.1e18 (10% of supply, hard cap)
    uint256 payoutPlan;       // bitset of registry indices
    uint256 deadline;         // unix seconds, checked against block.timestamp
}
```

`payoutPlan` rules (validated by `LaunchSupport.validate` against live registry state):

- Bit `i` selects registry index `i`.
- At most **8** selected entries, each currently active (`isSelectable(index)`).
- Sum of selected entries' `takeWad` must be `<= 1e18`.
- The **creator is the mandatory remainder**: whatever the selected takes do not consume of the pot
  accrues to creator-path entitlement. Selecting nothing (plan `0`) is valid and sends everything to
  the creator path.
- Index 0 is the canonical buyback-and-burn plugin; the canonical plan is bit 0 only.

Frontend flow: build the config -> `LaunchSupport.validate(config)` (view; checks bounds AND the
plan against the registry) -> `LaunchSupport.predictToken(config, hook)` to display the
knowable-before-launch token address -> ask for the signature.

### 4.2 Signing (EIP-712)

Domain:

```
name:              "SpawnLaunchpad"
version:           "1"
chainId:           <chain>
verifyingContract: <hook address from the manifest>
```

Struct (typehash string, exact — copy verbatim):

```
LaunchConfig(address creator,string name,string symbol,string uri,uint256 totalSupply,uint64 devBuyShareWad,uint256 payoutPlan,uint256 deadline)
```

viem example:

```ts
const domain = { name: "SpawnLaunchpad", version: "1", chainId, verifyingContract: hookAddress };
const types = {
  LaunchConfig: [
    { name: "creator", type: "address" },
    { name: "name", type: "string" },
    { name: "symbol", type: "string" },
    { name: "totalSupply", type: "uint256" },
    { name: "devBuyShareWad", type: "uint64" },
    { name: "payoutPlan", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};
const digest = await signTypedData({ domain, types, primaryType: "LaunchConfig", message: config });
// cross-check on-chain: LaunchSupport.launchDigest(config, hook) === digest
```

Properties the UI can lean on:

- **A relayer cannot alter a single field.** Any edit changes the digest and fails with
  `CreatorMismatch`. Validate nothing about tampering client-side; the protocol reverts.
- **Re-signing without moving the address.** `deadline` is inside the struct hash but outside the
  config hash that derives the CREATE2 salt, so a lapsed signature can be re-signed with a fresh
  deadline and the token address stays put.
- The signature is a plain 65-byte `(r, s, v)` — no smart-signature support in v1; creators must use
  an EOA-capable signer.

### 4.3 Token address prediction

`LaunchSupport.predictToken(config, hook)` returns the token address from the **configuration
alone** — no signature needed, so a launch form can display the deterministic address before the
user signs. Internally: salt = `keccak256(abi.encode(configHash, creator))`, deployed by
`LaunchSupport` itself via CREATE2. Display it as "reserved for this creator + config": a different
creator publishing byte-identical economics gets a different address.

### 4.4 Sending the transaction

`MilestoneHook.launch(config, signature)` is **payable**. Two modes:

- **Creator self-send** (identity = `msg.sender`): attach `msg.value` = the ETH budget for the dev
  buy, **no signature**. The creator receives exactly `totalSupply * devBuyShareWad` tokens and pays
  whatever the fresh curve charges; **unused ETH refunds automatically**. Emits `DevBuyExecuted`.
- **Relayed** (any third party, **operator signature required**): attach no value. The protocol's
  trusted operator — an on-chain, governance-rotatable address — signs the digest; a signature
  recovering to any other address reverts. The dev-buy share stays curve inventory and
  `DevBuySkipped` records the skip. Any attached value is refunded — the relay path never spends the
  relayer's ETH on the creator's behalf.

Returns `(poolId, tokenAddress, poolKey)`. Emits, in order: `Launched` (poolId, creator, token, name,
symbol, uri, totalSupply, openingLevel, farLevel, configHash), `LaunchConfigured` (payoutPlan, devBuyShareWad),
then the dev-buy event.

### 4.5 Pre-launch dev-buy quote

The pool does not exist before the launch tx, so this quote is pure math. The dev buy is a **fixed
token amount** (`devBuyTokens = totalSupply * devBuyShareWad`) whose ETH cost the protocol computes
on execution — the frontend needs the same number to size `msg.value`:

1. `L = CurveLib.positionLiquidity(opening, far, 32, 0.25 * totalSupply, 0)` — position 0's
   liquidity (reproduce the pure library math client-side; it is deterministic from the config).
2. The buy moves spot from `level = opening` upward. Standard Uniswap liquidity math (v4-sdk
   `SqrtPriceMath` / `getAmount0Delta`/`getAmount1Delta` equivalents) gives: find the end level `L'`
   such that crossing it consumes exactly `devBuyTokens` of position 0's token, then
   `ethCost = amount0Delta(sqrtP(-opening), sqrtP(-L'), L)`.
3. Attach `ethCost + headroom` (e.g. +5%) as `msg.value`. Exact-input semantics bound the spend at
   the attached budget and the unused remainder refunds; the dev buy cannot overspend the budget.

---

## 5. Trading

### 5.1 The pool

Every launch creates exactly one pool; build the key once and derive the id:

```
currency0:   address(0)          // native ETH
currency1:   <token>
fee:         10000               // literal 1%, in hundredths of a bip, forever
tickSpacing: 1
hooks:       <hook address>
poolId:      keccak256(abi.encode(key))   // PoolId.toId()
```

The fee is **static** — no dynamic-fee flag, no governance knob. Quote-ledger math can hardcode 1%.

### 5.2 Swap direction and fee side

- **Buy = `zeroForOne = true`** (ETH in, token out). **Sell = `false`**.
- A buy's trading fee is paid in **ETH**; a sell's fee is paid in **token**. This matters when you
  display "fee paid" and when attributing fee revenue by direction (see section 7.1).
- v4 requires `sqrtPriceLimitX96`. For a plain market order use the extreme bound (`MIN_SQRT_PRICE`/
  `MAX_SQRT_PRICE`) and rely on exact-input semantics; for bounded buys into the curve use the band
  target levels (note: v4 may stop one tick short at an initialized boundary — treat the target
  level as `>=`).

### 5.3 Execution paths

- **v4 SDK** (`@uniswap/v4-sdk`) for quotes/encoding against the pool, via the PoolManager's
  `unlock`/`swap`/`settle` flow. This is the normal trading path.
- **`hook.flushTo(poolId, tipTo)`** flushes one pool; the tip goes to `tipTo` (pass `msg.sender` to
  keep it), so bundlers and batch relays that accept no bare ETH (Multicall3) work directly.
  **`hook.flushBatch(pools, tipTo)`** flushes many pools under one shared redemption unlock and one
  combined tip transfer — all-or-nothing: any pool's unrecoverable failure reverts the whole batch,
  so use multicall over `flushTo` when you need per-pool isolation.
  **`hook.claimCreatorPathBatch(pools)`** claims several pools' creator-path entitlements under one
  shared redemption; the caller must hold every pool's RevenueNFT, and any ownership change reverts
  the batch. A single `claimCreatorPath(poolId)` flushes first and pays the holder everything,
  retained tip included.
  Before batching, read `hook.flushGasCeiling(poolId)` / `hook.creatorPathGasCeiling(poolId)` (and
  the `flushBatchGasCeiling` / `creatorPathBatchGasCeiling` sums): worst-case outer gas per
  operation, so a batch can be sized against the block gas budget. A zero tip recipient reverts; a
  rejecting recipient still reverts the whole flush atomically.
- Users **cannot provide liquidity**: the hook's `beforeAddLiquidity`/`beforeRemoveLiquidity` reject
  every position except the protocol's own. Trading is the only external pool interaction.
- Curve empty space: until graduation nothing provides liquidity above the far level, so an
  unbounded buy sweeps the curve and parks spot at the extreme. Terminals should show "graduation
  on next trade" once `level >= farLevel - 1` and route the next trade through `graduate` first for
  a deliberate, quoted graduation.

---

## 6. Quoting & simulation

| Situation | Tool |
| --- | --- |
| Post-launch trade quote | `V4Quoter.quoteExactInputSingle` against the hook pool, or v4-sdk simulation over `StateView` state |
| Bonding-curve progress (tokens out for ETH in, current curve bitmap) | same quoter — it runs the hook's real `beforeSwap`, so JIT curve/band deploys are included in the math; the simulation unwinds them afterwards |
| Pre-launch dev buy | pure math, section 4.5 |
| Fee accrual display | `collectFees` is stateful; do not call it to quote. Simulate it (it is permissionless and a no-op at zero accrual) or read position fee state via `StateView` |
| Registry / plan / take math | `PayoutPluginRegistry.entry(index)`, `isSelectable(index)`, hook `payoutPlan(poolId)` |

Simulation notes:

- During a quote the hook may **deploy** curve positions and bands inside `beforeSwap`. The
  quoter's unwind discards the deployment, but the price math already included the liquidity, so
  quotes are correct even when they cross undeployed rungs. Gas estimates taken from a quote are
  NOT — real swaps pay for those deploys.
- Quote results are single-swap: they do not account for another tx landing first. Re-quote on
  submission errors rather than padding.

---

## 7. Claims, flush, keeper incentives

### 7.1 Where value flows

- **Harvest** (a crossed band burns): gross quote = milestone proceeds. Default 10% service fee
  (cap 20%) to the protocol's claim-backed ledger; the **net** funds the pool's payout pot. The pot
  is held as a PoolManager ERC-6909 claim until a flush redeems it.
- **Quote swap fees** (ETH side, realized from the full-range position by `collectFees`): default
  75% to the pool's direct creator ledger, remainder to protocol (cap 90% creator share).
- **Token swap fees**: default 100% (cap 100%) funds the next not-yet-created fee-funded band's
  inventory, clamped to the remaining extension capacity; every token not admitted to that capacity
  **burns** immediately. At zero remaining extension capacity, 100% burns.
- **Graduation**: 70% of curve proceeds to the creator's direct ledger, 10% to protocol (raw ETH);
  the 20% LP seed funds the full-range position.
- **Flush tip**: 1% of a new pot (`pot / 100`, floor) to the flush caller.

### 7.2 The claim matrix

| Ledger | Read via | Claim via | Authorized caller | Backing |
| --- | --- | --- | --- | --- |
| Direct creator revenue (graduation + quote fees) | `creatorClaimable(poolId)` | `claimCreator(poolId)` | **current RevenueNFT holder only** (`msg.sender` check) | raw ETH |
| Creator-path entitlement (flush remainder + permanent redirects) | `creatorPathClaimable(poolId)` | `claimCreatorPath(poolId)` | anyone can trigger; pays the current NFT holder | raw ETH |
| Payout pot + plugin carry | `payoutPot(poolId)`, `carryBitmap(poolId)`, `pluginCarry(poolId, i)` | `flush(poolId)` | anyone; **1% tip** on a new pot only | claim-backed, redeemed inside the flush |
| Global protocol revenue | `protocolClaimable()` | `claimProtocol()` | `protocolRecipient` only | raw + claim-backed |

Behaviors to encode in the UI:

- `claimCreatorPath` **flushes first** (retaining the tip for the final payment), rechecks NFT
  ownership mid-flight, then attempts the full entitlement. Returns
  `(bool success, uint256 attemptedAmount)`; `success == false` means the holder's recipient
  rejected the transfer and the entitlement was restored — not a loss.
- `flush` on a **new pot**: redeems exactly the pot, pays the tip, then allocates to selected
  plugins in ascending index order. `flush` on **carry only**: no redemption, no tip. Empty pot +
  empty carry: silent no-op.
- A plugin **revert is a successful flush outcome**: the attempted value becomes carry
  (`PluginPayoutCarried`) and later entries still run. An inactive/suspended/codehash-mismatched
  entry is **redirected permanently** to creator-path entitlement (`PluginPayoutRedirected`).
- Zero-amount claims do not revert: `claimCreator` emits `CreatorClaimed(poolId, holder, 0)` and
  succeeds as long as the caller is the current NFT holder. `claimProtocol` at zero also succeeds.
- Transient settlement locks reject a claim racing a graduation/launch/flush. Retry; nothing is
  lost.

### 7.3 Keepers and batching

Keeper-rewardable actions and their economics:

| Action | Incentive | Poll signal |
| --- | --- | --- |
| `flush(poolId)` | floor **1%** of the new pot | `payoutPot(poolId) > 0 \|\| carryBitmap(poolId) != 0` |
| `collectFees(key)` | **none** (still permissionless) | simulate, or track `FeesCollected`-absence vs fee events |
| `graduate(key)` | none (gas-cost race vs the next swap's auto-graduation) | `poolPhase == BONDING_CURVE && level >= farLevel - 1` |

Batch multiple pools with **Multicall3** on Base (`0xcA11bde05977b3631167028862bE2a173976CA11`,
`aggregate3`). All the above entry points are safe to batch: zero-value claims and empty flushes are
no-op successes rather than reverts, so `aggregate3.allowFailure = false` is fine. Gate each call on
its view predicate to avoid paying for no-ops. A creator dashboard "claim all" =
`creatorClaimable(p) > 0 || creatorPathClaimable(p) > 0` per pool -> batch
`claimCreator`/`claimCreatorPath`; the creator-path variant performs its own flush, so no separate
`flush` is needed on that page.

---

## 8. Data layer (substreams)

### 8.1 Sources

Index two event sources and join them on `poolId`:

1. **The hook** — lifecycle events (all catalogued below). Filter on the hook address from the
   deployment manifest.
2. **The PoolManager** — `Swap` and `ModifyLiquidity`. OHLCV, trade tape, and liquidity depth live
   **here**, not in hook events. Map `poolId -> launch` from `Initialize` (its `hooks` field equals
   the hook address) or directly from the hook's `Launched` event, which carries the poolId.

Event ordering inside one tx is deterministic: manager events for the swap body (`Swap`) emit
**before** the hook's `afterSwap` work, so a milestone-crossing buy produces `... Swap` ->
`MilestoneHarvested` -> `PayoutPotFunded` in that order. A graduation tx produces the burn/
`ModifyLiquidity` pair, `Graduated`, then the split accruals.

### 8.2 Derived metrics

- `level = -tick` from `Swap.tick` (or `StateView.getSlot0`). Compute price/FDV with the section 2
  formulas: `fdvEthWei = totalSupplyWei * 1.0001^level`.
- **Direction**: `Swap.amount0 < 0` => buy (ETH in), `amount0 > 0` => sell. Signed amounts are
  caller-perspective deltas **including the 1% fee on the input side**: a buy's ETH volume is
  `-amount0`, a sell's token volume is `-amount1`.
- Supply is constant per launch (`totalSupply`) and only ever falls via explicit token `burn`s —
  no rebases, no mint hooks.
- Curve progress for "raised X of Y": curve supply = 25% of total supply; position `i` covers
  `[opening + i*13862/32, far]` levels; `CurvePositionsDeployed.deployed` is the **cumulative
  bitmap**. Position of spot within the curve: `(level - opening) * 32 / 13862`.
- Milestone progress: band `i` geometry from `BandDeployed` (carries `levelLower`/`levelUpper`
  explicitly — never recompute from a possibly-stale graduation level), completion from
  `MilestoneHarvested.completedMilestones` (cumulative count).

### 8.3 Hook event catalog

All indexed fields are marked `(ix)`. "Cumulative" fields are snapshots, not increments — store them
verbatim, never accumulate.

**Launch**

| Event | Fields | Notes |
| --- | --- | --- |
| `Launched` | poolId (ix), creator (ix), token (ix), totalSupply, openingLevel, farLevel, configHash | Genesis. `openingLevel`/`farLevel` are the curve anchors for everything derived later |
| `LaunchConfigured` | poolId (ix), payoutPlan, devBuyShareWad | The immutable plan; decode the bitset against registry entries for plugin attribution |
| `DevBuyExecuted` | poolId (ix), tokensBought, ethSpent | Creator's own launch |
| `DevBuySkipped` | poolId (ix), relayer (ix), tokensRequested | Relayed launch; share stayed curve inventory |

**Curve & ladder**

| Event | Fields | Notes |
| --- | --- | --- |
| `CurvePositionsDeployed` | poolId (ix), minted, deployed, tokenSettled | JIT curve mints. `deployed` = full cumulative bitmap |
| `BandDeployed` | poolId (ix), index (ix), levelLower, levelUpper, liquidity, tokenInventory | Full band geometry — the terminal should store it, not derive it |
| `BandSkipped` | poolId (ix), index (ix), carriedInventory | Price outran an undeployed band; share moved to carried inventory (post-skip total) |
| `MilestoneHarvested` | poolId (ix), index (ix), quoteProceeds, tokenResidue, completedMilestones | Band retired. `quoteProceeds` = gross (principal + accrued band fees). `tokenResidue` = dust, already carried |
| `Graduated` | poolId (ix), graduationLevel, quoteProceeds, lpSeedQuote, creatorQuote, protocolQuote, fullRangeLiquidity, wallLiquidity | The 20/70/10 split, realized. `graduationLevel` is the **live** level observed, and anchors all band geometry. Both seeded positions' liquidity rides the event; their tick bounds are the derived constants (`Bounds.FULL_RANGE_TICK_LOWER/UPPER`, wall = graduation level +1 to +880,000) |

**Payout delivery**

| Event | Fields | Notes |
| --- | --- | --- |
| `PayoutPotFunded` | poolId (ix), milestoneIndex (ix), grossQuote, serviceFee, netQuote, economicVersion | One per harvest. `economicVersion` = the tuple actually applied |
| `PayoutPotRedeemed` | poolId (ix), amount | The ERC-6909 claim became raw ETH (new-pot flush only) |
| `PayoutTipPaid` | poolId (ix), flusher (ix), amount | Keeper reward, 1% floor of a new pot |
| `PluginPayoutDelivered` | poolId (ix), pluginIndex (ix), plugin (ix), currentShare, previousCarry, delivered | Successful plugin call |
| `PluginPayoutCarried` | poolId (ix), pluginIndex (ix), plugin (ix), currentShare, previousCarry, carried | Plugin reverted; value retained as carry and retried on the next flush |
| `PluginPayoutRedirected` | poolId (ix), pluginIndex (ix), currentShare, previousCarry, redirected | Entry inactive/suspended/codehash-changed; value moved **permanently** to creator path |
| `CreatorPathAccrued` | poolId (ix), amount | Creator-path credit (flush remainder + redirects) |
| `CreatorPathClaimed` | poolId (ix), holder (ix), amount | |
| `CreatorPathClaimFailed` | poolId (ix), holder (ix), amount | Recipient rejected; entitlement restored, nothing lost |

**Revenue & claims**

| Event | Fields | Notes |
| --- | --- | --- |
| `CreatorAccrued` | poolId (ix), amount, source, economicVersion | `source` enum: `CURVE_PROCEEDS = 0`, `SWAP_FEES = 1`, `MILESTONE_HARVEST = 2` |
| `ProtocolAccrued` | same shape | |
| `CreatorClaimed` | poolId (ix), holder (ix), amount | Direct path (NFT-gated). Amount 0 emission = no-op claim |
| `ProtocolClaimed` | recipient (ix), amount | |
| `FeesCollected` | poolId (ix), caller (ix), quoteFees, tokenFees | Gross, **before** routing. Zero-accrual collection emits **nothing** |
| `FeesRouted` | poolId (ix), creatorQuote, protocolQuote, divertedToNextBand, tokensBurned, economicVersion | Where one collection went. `FeesCollected` + `FeesRouted` account for every wei |

**Governance (hook-emitted, controller-driven)**

| Event | Fields |
| --- | --- |
| `EconomicConfigSet` | version (ix), harvestServiceFeeWad, quoteCreatorShareWad, tokenMilestoneFundShareWad | The full tuple, version-indexed |
| `ProtocolRecipientSet` | recipient (ix) | |

Registry/protocol-controller events to index for governance pages: `PluginRegistered`,
`PluginSuspensionSet`, `OperationScheduled/Cancelled/Executed`, `EconomicConfigUpdated`,
`ProtocolRecipientUpdated`, `GovernanceDelayUpdated`, `AdministratorProposed/Accepted` (both
controller and registry), `ProtocolTargetBound`. `RevenueNFT.MinterSet` and ERC-721
`Transfer` events give the creator->buyer trail for claim rights.

### 8.4 What events do NOT cover — read these via views

| Need | Read |
| --- | --- |
| Live slot0 (price/tick), in-range liquidity | `StateView.getSlot0(poolId)`, `getLiquidity(poolId)` |
| Accrued-but-uncollected full-range fees | simulate `collectFees` (stateless call, permissionless) or `StateView` position fee growth |
| Current ledgers (pot, carry, claimables) | hook views (section 7.2) |
| Selected plugin metadata | `PayoutPluginRegistry.entry(i)` per `payoutPlan(poolId)` bit |
| Band existence timestamps | `bandDeployedAt(poolId, index)` |

---

## 9. Constants sheet

From `Bounds.defaultTemplate()` / `Bounds` (`src/types/LaunchTypes.sol`) — **immutable** for a
deployment generation; read `template()` for the live values rather than trusting this table:

| Constant | Value |
| --- | --- |
| `openingFdvWei` | 2e18 ETH FDV, every launch |
| Total supply | Pinned to 1,000,000,000 (`FIXED_TOTAL_SUPPLY`); any other value reverts `SupplyNotFixed` |
| `curvePositions` | 32 |
| `curveSpanLevels` | 13,862 (4x opening, two 2x spans) |
| `bandLevelSpacing` | 2235 (1.2504x floor) |
| `bandFirstStepLevels` / `bandStepDecayLevels` | 6,932 (2x first step) / 391 |
| `bandWidthLevels` | 447 |
| `coreBandCount` / `maxFeeFundedBands` | 22 / 30 |
| Supply split (curve / ladder / graduation LP + wall) | 25% / 10% / 65% |
| Graduation split (LP / creator / protocol) | 20% / 70% / 10% |
| `tradingFeeHundredthsBip` | 10 000 (1%) |
| `POOL_TICK_SPACING` | 1 |
| `MAX_DEV_BUY_SHARE_WAD` | 0.1e18 |
| `maxDeploysPerSwap` / `maxHarvestsPerSwap` | 8 / 8 |

Economic tuple (`EconomicConfig`, governance-mutable **prospectively** — always read
`economicConfig()` live):

| Field | Default | Immutable cap |
| --- | --- | --- |
| `harvestServiceFeeWad` | 0.10e18 | 0.20e18 |
| `quoteCreatorShareWad` | 0.75e18 | 0.90e18 |
| `tokenMilestoneFundShareWad` | 1.00e18 | 1.00e18 |
| `version` | 1 | increments per replacement |

Flush tip: `pot / 100` (floor), new pot only.

Enum encodings (for decoding events): `Phase {NONE, BONDING_CURVE, GRADUATED}`,
`AccrualSource {CURVE_PROCEEDS, SWAP_FEES, MILESTONE_HARVEST}`,
`PluginRole {INVALID, PAYOUT, CREATOR_SYSTEM, UTILITY}`.

## 10. ABI inventory

`make abis` writes `abi/<Contract>.json` for:

`MilestoneHook`, `LaunchSupport`, `MilestoneToken`, `RevenueNFT`, `PayoutPluginRegistry`,
`ProtocolController`, `BuybackAndBurnPlugin`, `IPayoutPlugin`,
plus `StateView` and `V4Quoter` from `lib/v4-periphery`.

Deliberately excluded: `MilestoneColdPaths` and `MilestonePayoutPaths` (delegatecall
implementations — direct calls revert), libraries (`CurveLib`, `LadderLib`, `LaunchSignature`,
`Orientation`, `LaunchConfigLib` — pure math, reproduce client-side or read via the hook's
convenience views).
