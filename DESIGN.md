# Spawn Launchpad — Payout Plugin Design

A singleton Uniswap v4 hook launchpad for Base. Its differentiator is a protocol-owned ladder of
one-sided token sell bands at ascending valuation levels. Crossing a band's top retires real liquidity
and funds an asynchronous payout pot; it never executes a destination on the trader's swap.

Target: Solidity `0.8.26`, Cancun EVM, Foundry, v4-core `5f00c84`, v4-periphery `9628c36`.

## 1. Product thesis and invariants

The ladder is a continuous fundraiser tied to market performance. Each band is a committed sell wall;
reaching its top converts inventory to native quote without an oracle or keeper. The design preserves:

- one pool and one immutable hook generation for the complete lifecycle;
- hook-owned curves, bands, and permanently locked graduation liquidity;
- a literal 1% pool fee for the pool's complete lifetime;
- ordinary swaps independent of plugin availability or destination behavior;
- exact liability-class backing for every claim, pot, carry, and creator entitlement;
- signed, immutable per-pool payout plans whose registry indices never change meaning.

There is no vesting, dynamic-fee capability, post-graduation LP compounding, LP fee carry, inline
buyback, per-pool protocol ledger, arbitrary-call governance, or mutable historical plugin term.

## 2. Lifecycle

```text
BONDING_CURVE
  position 0 at genesis; positions 1–31 deploy just ahead of demand
  permissionless or automatic graduation once live price reaches farLevel
        |
        v
GRADUATED
  immutable 40/55/5 graduation split; one code-locked full-range position
  ladder bands deploy just ahead of buys and retire after crossing their tops
  harvests fund claim-backed pots; permissionless flushes deliver them later
```

Launch is creator-direct or relayed from an EIP-712 signature. The signed `LaunchConfig` binds creator,
metadata, supply, immediate dev-buy share, exact `uint256 payoutPlan`, and deadline. The CREATE2 identity
binds the deadline-independent configuration hash and creator. A dev buy is at most 10% of supply,
executes completely only during a creator-direct launch, and transfers bought tokens immediately.
Relayed launches skip it and leave that inventory on the curve.

Graduation burns deployed curves, credits undeployed and returned token inventory to the ladder, splits
quote proceeds 40% locked-LP seed / 55% direct creator revenue / 5% global protocol revenue, and seeds
the sole full-range position with 10% of supply. No code path later adds to or removes from that position.

## 3. Contract architecture

`MilestoneHook` is the mined-address core. It owns callbacks, simulation-driven curve/band deployment,
band retirement, public claim/configuration wrappers, and every pool's state at the hook address.

Two immutable delegatecall targets move cold logic outside its EIP-170 budget:

- `MilestoneColdPaths`: launch, graduation, fee collection, and PoolManager unlock dispatch;
- `MilestonePayoutPaths`: pot redemption, plugin delivery, carry retry, and creator-path claiming.

`MilestoneBase` is the sole mutable-storage declaration point for all three implementations. A satellite
executes as the hook, in hook storage, with the original `msg.sender`; every mutating satellite entry is
`onlyDelegated`. All three receive matching PoolManager, RevenueNFT, LaunchSupport, controller, registry,
and template dependencies. Layout checks do not prove immutable parity, so deployment verifies both.
Changing either satellite means mining and deploying a new hook—there is no upgrade path.

`LaunchSupport` owns registry-dependent plan validation, EIP-712 support, and deterministic token
deployment. `RevenueNFT` represents the current holder of both unpaid creator revenue streams. Global
configuration is split between the append-only `PayoutPluginRegistry` and typed `ProtocolController`.

The hook requests only initialization, swap, and liquidity-before callbacks. It requests no donation or
return-delta hooks. Pool keys use the literal static fee and do not set `DYNAMIC_FEE_FLAG`.

## 4. Coordinates, curve, and ladder

Native ETH is always `currency0`; the launch token is `currency1`. Pool price is token-per-ETH, so token
price rises when tick falls. Protocol arithmetic uses `level = -tick`; only `Orientation` converts at
PoolManager boundaries.

The immutable template defaults are:

| Parameter | Value |
|---|---:|
| Opening fully diluted valuation | 125 ETH |
| Bonding curve | 32 nested positions over one 2× level span |
| Supply | 25% curve / 65% ladder / 10% full-range seed |
| Ladder | 30 core bands, 2,235 levels apart, 447 levels wide |
| Fee-funded extensions | at most 30 |
| Band inventory cap | 2× nominal per-band inventory |
| Graduation quote split | 40% LP / 55% creator / 5% protocol |
| Trading fee | literal 1% |
| Per-swap deployment / harvest work | at most 8 each |

Position 0 exists at genesis. `beforeSwap` simulates each buy using v4 swap math and deploys every curve
position or ladder band its path reaches, subject to the work cap. Sells deploy nothing. A band already
behind spot cannot be minted single-sided, so its core share moves to `carriedInventory`; the next band
can consume it. This skip-and-carry rule prevents a straddling undeployed band from bricking buys.

Bands and curve ranges are derived rather than stored. Bitmaps record deployed curves, deployed bands,
and completed bands; `nextBandIndex` advances monotonically. A live band is a standing sell order and has
no reclaim path. A dead market may leave it in the pool indefinitely; a returning market fills it.

`afterSwap` reads post-swap level and retires completed live bands in ascending order, up to the immutable
harvest cap. It burns each position, mints a PoolManager claim for gross quote, carries token residue,
marks completion once, snapshots global economics once for that harvest, and funds liabilities. It does
not redeem, transfer ETH, call a plugin, swap, donate, or change the fee.

## 5. Immutable payout plans and registry

A launch stores exactly one 256-bit registry bitset. Set bits are resolved in ascending order at launch.
A valid plan selects at most eight existing, unsuspended `PAYOUT` entries and their immutable takes total
at most `WAD`. Empty and exact-WAD plans are valid. Preset names are offchain aliases only and never enter
signed identity or storage.

Registry entries have stable indices 0–255 and immutable address, take, gas stipend, role, and registered
runtime code hash. Only suspension changes, and it is reversible. Registration rejects duplicate or
codeless addresses, invalid roles/takes/stipends, and proxy-like code. Delivery rechecks suspension and
`extcodehash`; an inactive or changed destination is not called. Its current allocation and all carry
redirect permanently to the creator path. Restoring code or reactivating the entry cannot replay value.

The creator is the mandatory implicit remainder destination, not a selectable plugin. Each plugin share
is independently floored from the post-tip distributable amount; creator entitlement receives the exact
subtraction remainder and all arithmetic dust. Canonical deployment registers buyback-and-burn at a
published index with `takeWad = floor(2 * WAD / 9)` and publishes that one-bit plan.

## 6. Harvest pots and flush

For gross completed-band quote `gross`, one active `EconomicConfig` snapshot computes:

```text
serviceFee  = floor(gross * harvestServiceFeeWad / WAD)
newPot      = gross - serviceFee
tip         = floor(newPot / 100)
distributable = newPot - tip
pluginShare_i = floor(distributable * takeWad_i / WAD)
creatorNew  = distributable - sum(pluginShare_i)
```

The default service fee is 10% with an immutable 20% cap. It credits the global protocol ledger and its
claim-backed subset. The net credits the source pool's claim-backed pot. Both remain PoolManager native
claims after `afterSwap`.

Any address may later `flush(poolId)`. A non-empty flush snapshots and zeros the complete pot, enters the
protocol-global payout guard, redeems exactly that amount once through `REDEEM_PAYOUT_POT`, and pays the
ordinary caller's 1% tip before plugin iteration. Tip rejection reverts the complete flush atomically.
Carry-only flushes perform no redemption, allocation, or tip. Empty pot and empty carry return without an
unlock or transfer.

Selected plan bits and carry bits are walked in ascending order. Each active destination receives:

```solidity
function onPayout(PoolId poolId, address token) external payable;
```

`attempted = currentShare + previousCarry`. Carry is cleared before interaction. A successful EVM `CALL`
consumes the attempted allocation regardless of empty, malformed, or very large returndata, all of which
core ignores. Revert or stipend exhaustion restores the complete attempted value as carry and does not
block later entries. Suspended/codehash-invalid entries redirect instead. Creator credit is recorded
only after iteration.

Each call uses its immutable stipend, capped at 500,000 gas. Immediately before `CALL`, after calldata
materialization and accounting effects, the payout path computes:

```text
reserve        = remainingCalls * 100_000 + 100_000
eip150Margin   = ceil(callGas / 63)
required       = reserve + callGas + eip150Margin + 15_000
```

Insufficient outer gas reverts the whole flush rather than being misclassified as destination failure.
The constants reserve final accounting and one conservative post-call budget for every unresolved bit.

## 7. Creator and protocol revenue

There are two deliberately separate creator ledgers:

- `_creatorClaimable[poolId]`: raw-backed graduation and quote-fee revenue, withdrawn by
  `claimCreator(poolId)`;
- `_creatorPathClaimable[poolId]`: payout-plan remainder and permanent redirects, withdrawn by
  `claimCreatorPath(poolId)`.

Both follow current RevenueNFT ownership at claim time. An arbitrary flusher never pushes creator value.
A creator-path claimant must be the holder at entry; the call flushes first, retains its self-flush tip for
the final transfer, rechecks ownership after plugin interactions and before payment, and attempts the
complete entitlement. Ownership change reverts all effects. Recipient rejection restores the complete
attempted amount, returns `(false, attemptedAmount)`, and leaves no partial value outside the ledger.

Protocol revenue is one global `_protocolClaimable`, payable only to the independently configurable
`protocolRecipient`. Administrator status grants no withdrawal authority. Harvest service fees also
increase `_protocolClaimBacked`; graduation and quote-fee protocol revenue are raw-backed. A global claim
zeros both captured counters, redeems only the exact claim-backed subset, and transfers the complete
ledger. No pool-scoped protocol claim exists.

## 8. Custody and solvency

Harvest quote and service-fee liabilities are initially claim-backed because a crossing swap has not yet
settled its input during `afterSwap`. All plugin carry, creator-path entitlement, direct creator revenue,
and non-claim-backed protocol revenue are raw-ETH-backed. The implementation tracks component ledgers
and exact aggregate counters:

```text
claimBackedLiability = totalPayoutPot + protocolClaimBacked
rawEthLiability      = totalPluginCarry + totalCreatorPath
                     + totalDirectCreator + (protocolClaimable - protocolClaimBacked)
```

Outside an active exact-redemption unlock, PoolManager native-claim balance must cover the first class and
the hook's raw ETH must cover the second. Their sum must cover all ETH liabilities. A pot redemption
reduces only pot liability before redeeming exactly that pot. Protocol redemption consumes only the
captured protocol-backed subset. Direct creator claims cannot use ambient claims, and no claim or flush
may consume ETH reserved for another class. Revert restores source ledgers and classification atomically.

Token reserves are outside these ETH counters: remaining ladder inventory, carry/milestone-fund token,
live positions, and permanently locked LP principal keep their own conservation and structural locks.

## 9. Fees and token recycling

Every pool uses a literal 1% Uniswap v4 fee from initialization forever. No hook path calls
`updateDynamicLPFee`; governance cannot alter it. Permissionless `collectFees` realizes only accrued
full-range fees with a zero-liquidity-delta operation, preserving principal and liquidity exactly.

The active versioned economics tuple defaults to:

| Field | Default | Immutable cap |
|---|---:|---:|
| Harvest service fee | 10% | 20% |
| Quote-fee creator share | 75% | 90% |
| Token-fee milestone-fund share | 20% | 50% |

Updates apply prospectively to every pool and replace the complete tuple atomically with a monotonically
increasing version. Each harvest or collection snapshots once; events record that version. Previously
recorded quantities are never repartitioned.

Quote fees credit the direct creator ledger using the active share; subtraction remainder credits global
protocol revenue. Token fees can fund only still-available fee-funded extension capacity. Capacity is
bounded by remaining extension count and per-band inventory cap, net of existing carry and accrued fund.
The admitted amount is the minimum of the configured share and free capacity. Every other token burns in
the same collection; when capacity is zero, 100% burns. Fee collection never swaps or adds liquidity and
keeps no unpaired LP carry.

## 10. Governance and deployment

`ProtocolController` exposes only typed delayed operations:

- append a registry entry;
- suspend or reactivate an entry;
- replace the complete economic tuple;
- replace the protocol recipient;
- replace the governance delay.

Operation identity binds action, complete parameters, controller address, chain ID, and caller salt.
Scheduling captures an absolute readiness timestamp using the current delay. A queued delay change also
waits under that old delay. Cancellation and execution consume one exact operation identity. The initial
delay is zero for bootstrap; the administrator is operationally a multisig and may later queue an
increase. Administrator transfer is propose/accept. Administrator and protocol recipient remain
independent.

Deployment has a constructor cycle because the final mined hook address depends on immutable controller,
registry, and both satellite addresses. Bootstrap therefore creates the registry, controller,
`RevenueNFT`, `LaunchSupport`, and both satellites with final matching dependencies, then mines and deploys
the hook. It binds the controller's one-shot target, hands registry authority to the controller, registers
the canonical buyback through a zero-delay typed operation, verifies immutable parity, registry
entries/code hashes/roles/stipends, economics and recipient, sets the NFT minter, and publishes the
canonical bitset. The bootstrap administrator then proposes the operational multisig, which must call the
controller directly to accept. No production state exists; any correction before launch means a full
redeployment and newly mined hook.

## 11. Reentrancy and callback isolation

Pool-scoped transient locks reject concurrent launch, settlement, collection, and claim work. Plugin
execution additionally holds one protocol-global transient payout guard. While held, no pool may begin
custody, lifecycle, claims, governance execution, or registry mutation. The controller checks the hook's
guard immediately before typed execution, not at scheduling time.

A reference buyback plugin may call PoolManager and trigger nested callbacks. Those callbacks suppress
protocol work and return normally; reverting would abort the plugin's own legitimate swap. This suppresses
graduation, curve/band deployment, and harvest across same- and cross-pool reentry without granting the
plugin any routing or storage authority. Transient storage guarantees no guard survives transaction end.

`BuybackAndBurnPlugin` is authenticated to one hook and PoolManager. It spends exactly `msg.value` against
the source pool, enforces immutable execution bounds, and burns all received launch tokens. Failure
becomes hook carry. There is no protocol-authored swap-and-flush composition: `flush` is a standalone
permissionless call whose 1% tip goes to the immediate caller, and `claimCreatorPath` is the only
same-transaction creator composition, flushing first and retaining its own tip for the holder.

## 12. Security and failure model

The principal safety boundary is conservation across custody classes, not destination reliability. A
plugin may revert, consume its full stipend, return malformed data, reenter through PoolManager, change
or lose its code, or reject future use. None may block the crossing swap, spend another destination's
allocation, replay a redirected value, or reach arbitrary hook storage. Failed calls preserve complete
carry; inactive destinations redirect once to the creator path; insufficient outer gas fails atomically
before a call is misclassified.

The remaining structural risks are explicit:

- delegatecall layout or immutable mismatch can corrupt storage or route through inconsistent dependencies;
- sign mistakes at the tick/level boundary can place liquidity on the wrong side of spot;
- incomplete liability accounting can let one claim class consume another class's backing;
- an unbounded callback or plugin loop can make swaps or flushes unexecutable;
- registry code replacement can change destination behavior after plan signing;
- accidental full-range removal or fee compounding can violate permanent-lock and supply assumptions;
- deployment-order drift can mine an address for initcode different from the code ultimately deployed.

Layout/parity checks, `Orientation`, exact aggregate counters, bounded per-swap and per-plan work, runtime
codehash checks, structural full-range locks, and initcode-derived deployment verification are mandatory
controls rather than optional hardening. No emergency sweep, arbitrary call, proxy upgrade, or
administrator override may bypass these controls.

## 13. Test strategy

Every normative OpenSpec `#### Scenario:` must have at least one passing test carrying the literal header:

```solidity
// --- Scenario: Exact scenario name ---
```

The scenario inventory is generated from the current specs and test sources; historical totals are not
evidence. Unit coverage uses a local PoolManager and shared registry/controller/satellite fixture.
Handler invariants exercise lifecycle, liability conservation, monotonic bitmaps, token conservation, and
locked full-range principal. Base-fork suites rerun integration behavior against the pinned deployed v4
singleton when an RPC is available.

Payout tests must cover empty and exact-WAD plans, deterministic ordering and rounding, pot and protocol
exact redemption, carry-only retry, suspension/codehash redirect, tiny and maximum gas stipends, EIP-150
preflight, ignored returndata, tip rejection, creator rejection and ownership changes, same- and
cross-pool reentrancy, nested callback suppression, and attempts to drain another liability class.
Deployment tests must prove constructor parity, one-shot bindings, authority handoff, registry contents,
canonical plan publication, and rejection of every mismatched dependency.

## 14. Release gates

A release candidate must pass formatting, Solidity compilation, dependency pins, EIP-170 checks for all
three implementations, storage-layout equality, `onlyDelegated` entry guards, the full-range structural
lock, scenario traceability, unit tests, and invariant tests. Fork tests run only with the required Base
RPC; public-testnet rehearsal additionally requires deployed addresses, funded credentials, and external
configuration. Those environment-dependent tasks remain explicitly open when prerequisites are absent.

No OpenSpec task is complete merely because code exists. Its implementation, literal scenario evidence,
and applicable gates must all pass. Because this generation is pre-deployment and intentionally breaking,
a failed release candidate is corrected by rebuilding and re-mining the complete immutable deployment,
not by migrating state or weakening a requirement.
