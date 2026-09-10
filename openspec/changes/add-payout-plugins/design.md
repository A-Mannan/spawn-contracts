## Context

See `proposal.md` for motivation and the delta specs for normative behavior. The existing protocol is a singleton Uniswap v4 hook: `MilestoneHook` owns the hot swap path, `MilestoneColdPaths` executes lifecycle work through immutable `DELEGATECALL`, and `MilestoneBase` is the sole declaration point for hook-owned mutable storage. Mid-swap quote proceeds are represented by PoolManager ERC-6909 claims until a later cold unlock redeems them. The initial full-range position is hook-owned and permanently locked.

This change replaces direct four-way harvest settlement with asynchronous plugin delivery, adds global governance and economics, changes signed launch identity, and removes dynamic fees, dev-buy vesting, and every post-graduation liquidity-compounding path. It therefore crosses the hook, both custody forms, shared layout, signatures, deployment, claims, fixtures, and all three test layers.

The implementation is constrained by:

- EIP-170 applies independently to the hook and every delegatecall satellite; `via_ir` and continuous size checks remain load-bearing.
- Every delegatecall-visible storage slot must be declared exactly once in `MilestoneBase`, and every satellite state-changing entry must be `onlyDelegated`.
- Satellite immutables come from satellite bytecode even under delegatecall, so constructor parity is a deployment invariant not protected by storage-layout checks.
- Ordinary swaps must remain independent of payout liveness. Pot redemption and untrusted plugin calls cannot occur in `beforeSwap` or `afterSwap`.
- A harvested band's quote exists first as a PoolManager claim because the crossing swap has not settled its input while `afterSwap` executes.
- The protocol has no deployed production state, so breaking signed-data, storage, and deployment changes require no live migration.

## Goals / Non-Goals

**Goals:**

- Keep hot-path harvest work bounded to band retirement, gross attribution, one economics snapshot, and ledger credits.
- Make each pool's immutable payout plan deterministic, inspectable, and safe from registry reinterpretation.
- Redeem and deliver payout value permissionlessly without allowing one plugin to block another, block swaps, or consume unrelated reserves.
- Preserve solvency across raw ETH, PoolManager claims, direct creator revenue, global protocol revenue, payout pots, creator-path entitlement, and failed plugin carry.
- Introduce typed delayed administration while keeping administrative authority separate from revenue claim authority.
- Preserve the initial locked full-range position while structurally deleting all later compounding paths.
- Keep every changed requirement traceable to unit, invariant, and Base-fork coverage.

**Non-Goals:**

- Upgradeable plugins, registry entry replacement, mutable per-pool plans, or on-chain preset names.
- Multi-pool batch flushes, arbitrary-call governance, or governance over the 1% trading fee and immutable graduation split.
- Per-milestone on-chain tranches, Merkle distribution, voting, lotteries, or community-gated creator payment.
- Reintroducing LP compounding through a protocol-authored plugin or utility.
- Guaranteeing plugin business success; the core guarantees bounded attempts, accounting recovery, and isolation.

## Decisions

### 1. Split payout settlement into a second cold-path satellite

**Decision:** Retain `MilestoneHook` for callbacks and bounded harvest accounting, retain `MilestoneColdPaths` for launch, graduation, fee collection, and existing lifecycle unlocks, and add `MilestonePayoutPaths` for flush, plugin delivery, carry retry, and creator-path claiming. All three inherit `MilestoneBase`; neither derived hook nor either satellite declares mutable state. The hook exposes thin wrappers that delegate to the appropriate immutable satellite.

**Why:** Flush logic contains bit iteration, exact accounting, gas-isolated calls, and reserve management but is never needed on an ordinary swap. A second satellite protects the hot hook's EIP-170 margin and avoids bloating lifecycle code with untrusted-call machinery. It preserves the established delegatecall ownership model: positions, pots, ledgers, and ETH remain at the hook address.

**Alternatives considered:** Put flush directly in the hook (charges bytecode headroom to every lifecycle); add it to `MilestoneColdPaths` (one satellite becomes an oversized unrelated bundle); use an external custodian (adds allowance, trust, and cross-contract solvency edges). The satellite split is selected, with `make size`, `make layout-check`, and cold-path guard checks extended to all three implementation contracts.

### 2. Use an external append-only registry and a typed governance controller

**Decision:** Deploy a `PayoutPluginRegistry` with up to 256 immutable entries. Each entry stores `plugin`, `takeWad`, `gasLimit`, `codehash`, and `role`; only `suspended` is mutable. Deploy a separate `ProtocolController` to own queued-operation state and two-step administrator transfer. The controller can invoke only typed hook and registry configuration functions: register, suspend/reactivate, replace economic configuration, replace protocol recipient, and replace delay.

Entry registration rejects zero or duplicate addresses, contracts without code, invalid roles, zero/unsafe gas limits, takes above one whole, and proxy-like or otherwise unpinnable entries. Runtime delivery compares the entry's live `extcodehash` with the registered value before every attempt. A mismatch permanently invalidates that historical destination for the attempted allocation: the core MUST NOT call it, MUST clear its carry, and MUST redirect current share plus all existing carry to the creator path in the same flush. Later code restoration, re-registration at another index, or registry reactivation cannot recover or replay the redirected amount. The creator sink/path and utility roles are not selectable plan bits.

**Why:** Stable bit meaning requires immutable registry identity, while governance queueing would consume substantial shared hook storage and bytecode if duplicated across delegatecall halves. Code-hash pinning makes the promise about immutable destination behavior meaningful: an immutable registry address is insufficient if a proxy can change implementation. Typed operations prevent the controller from becoming an arbitrary executor over protocol custody.

**Alternatives considered:** Store the registry in `MilestoneBase` (inflates the hook and couples global records to delegatecall layout); allow mutable addresses or proxy plugins (silently reinterprets historical signatures); use a generic timelock executor (authority exceeds the specified administrative surface).

### 3. Store only plan bits per pool and validate against current registry state

**Decision:** `LaunchConfig` replaces `HarvestSplit` and vesting with exact `uint256 payoutPlan`. Its EIP-712 type hash and deadline-independent configuration hash bind all plan bits; the CREATE2 salt remains `keccak256(configHash, creator)`. Launch validation walks set bits in ascending order, rejects more than eight, resolves every bit to an existing active selectable payout entry, and sums immutable takes to at most `WAD`. The resulting bitset alone is stored in `PoolState`; no entry copy, percentage array, or preset name is stored.

Canonical deployment registers buyback-and-burn at a published stable index with `takeWad = floor(2 * WAD / 9)` and publishes the one-bit default plan. The creator receives the exact arithmetic remainder, so WAD representability and all division dust favor the implicit mandatory creator sink.

**Why:** A one-word plan is compact, signature-friendly, and bounded at launch and flush. Append-only indices preserve meaning without duplicating registry data per pool. Computing plugin nominal shares independently from the post-tip distributable amount makes each immutable take auditable; assigning the final subtraction remainder to the creator guarantees conservation.

**Alternatives considered:** Store selected addresses per pool (larger state and signed payload); store a preset ID (mutable alias can change economics); normalize selected takes to 100% (would erase the creator's mandatory remainder semantics).

### 4. Keep global economics versioned in hook storage and snapshot once per operation

**Decision:** Add one active `EconomicConfig` to `MilestoneBase` containing `harvestServiceFeeWad`, `quoteCreatorShareWad`, `tokenMilestoneFundShareWad`, and a monotonically increasing `version`. Defaults are 10%, 75%, and 20%; immutable validation caps them at 20%, 90%, and 50%. The protocol and token-burn shares are exact remainders. The controller replaces the complete tuple atomically after its scheduled delay.

Each harvest or fee collection copies the active tuple once before calculating any destination. Events carry the version. Recorded pots and ledgers are quantities, not claims on a percentage, so updates never repartition prior accrual. Uncollected LP fees are routed under the version active when collection realizes them.

**Why:** Whole-configuration replacement prevents mixed-version routing if several values change together and makes event reconstruction exact. Keeping the active tuple in hook storage avoids an external controller read on the hot harvest path.

**Alternatives considered:** Independently mutable fields (one operation can observe an unintended combination); per-pool version snapshots (contradicts prospective global updates); read economics from the controller during callbacks (new external dependency and gas on the hot path).

### 5. Harvest into an isolated claim-backed pot; flush through a dedicated redemption action

**Decision:** `_harvestBand` continues to burn the completed position and mint a quote ERC-6909 claim for the gross proceeds. It records gross attribution, calculates the service fee from one snapshot, credits the global protocol ledger, records that service-fee credit as claim-backed, and credits the exact remainder to `_payoutPot[poolId]`. It performs no destination call, buyback, donation, or real-ETH transfer.

A flush snapshots and zeros the complete new pot before interaction, enters the global payout guard, and—only when the new pot is non-zero—opens one `PoolManager.unlock` with a dedicated `REDEEM_PAYOUT_POT` action containing pool and exact amount. The callback redeems precisely that claim quantity to the hook. It cannot use a generic claim top-up path, because whole-pot, once-only redemption must be independently auditable and must not consume claims backing protocol revenue. Carry-only flushes perform no unlock.

**Why:** PoolManager claims solve the in-flight swap shortfall without relying on unrelated singleton liquidity. The claim minted by a harvest backs both the payout pot and its service fee until each liability class is redeemed. A dedicated pot redemption action proves that the tip base and new allocation base correspond to one fully redeemed pot and are not mixed with direct or protocol claims.

**Alternatives considered:** Redeem during `afterSwap` (can fail before the swapper settles); reuse `_ensureEth` (may redeem only a shortfall and commingle liability classes); let each plugin redeem its share (multiple unlocks and plugin authority over custody).

### 6. Model every ETH liability explicitly and conserve it through state transitions

**Decision:** Shared accounting includes:

```solidity
mapping(PoolId => uint256) internal _payoutPot;
mapping(PoolId => mapping(uint8 => uint256)) internal _pluginCarry;
mapping(PoolId => uint256) internal _carryBitmap;
mapping(PoolId => uint256) internal _creatorPathClaimable;
mapping(PoolId => uint256) internal _creatorClaimable;
uint256 internal _protocolClaimable;
uint256 internal _protocolClaimBacked;
```

Aggregate totals are mandatory and exact: `_totalPayoutPot`, `_totalPluginCarry`, `_totalCreatorPathClaimable`, `_totalCreatorClaimable`, and `_protocolClaimable` increase and decrease in the same state transition as their component ledgers. `_protocolClaimBacked` is the exact subset of `_protocolClaimable` still represented by PoolManager quote claims and can never exceed it. Harvest service fees increment both protocol counters; graduation and quote-fee protocol revenue increment only `_protocolClaimable` because those sources are raw-ETH-backed.

Define `claimBackedLiability = _totalPayoutPot + _protocolClaimBacked` and `rawEthLiability = _totalPluginCarry + _totalCreatorPathClaimable + _totalCreatorClaimable + (_protocolClaimable - _protocolClaimBacked)`. Outside an active liability-class redemption unlock, the custody invariants are `poolManager.balanceOf(hook, quoteId) >= claimBackedLiability` and `address(hook).balance >= rawEthLiability`; the combined invariant `raw ETH + redeemable quote claims >= claimBackedLiability + rawEthLiability` also holds. During pot redemption, decrement only `_totalPayoutPot` before redeeming its exact amount and do not classify the redeemed ETH as plugin/creator/tip value until the unlock has returned. A global protocol claim zeros `_protocolClaimable` and `_protocolClaimBacked` before interaction, redeems exactly the captured claim-backed subset through a distinct exact-amount action, and transfers the complete captured global balance. A revert restores all source ledgers and backing classification transactionally. Inventory tokens and locked-liquidity principal are outside these ETH counters and remain protected by their own custody invariants. No claim function treats ambient ETH or claims reserved for another liability class as unreserved. State transitions zero or decrement the source liability before transfer and restore exactly on failed delivery.

A harvest classifies newly minted quote-claim backing into service-fee and pot liabilities without pretending either is raw ETH. A flush transfers pot and prior-carry liability into tip, successful plugin value, creator-path entitlement, redirects, or new carry. Direct creator claims operate only on their raw-backed ledger. A global protocol claim first redeems its exact claim-backed subset and then transfers the whole ledger without changing pot or carry accounting.

**Why:** Once plugins can fail while other claims remain live, address balance alone cannot show which ETH is spendable. Explicit liabilities make conservation testable and prevent a creator or protocol claim from consuming plugin reserves.

**Alternatives considered:** Track only per-pool values and infer totals off chain (harder to assert global solvency); escrow each plugin externally (more contracts and transfer failure surfaces); treat failed allocations as best-effort forfeiture (violates recovery requirements).

### 7. Flush computes current shares once, retries carry separately, and credits creator last

**Decision:** For a non-zero new pot:

```text
tip           = floor(newPot / 100)
distributable = newPot - tip
pluginShare_i = floor(distributable * takeWad_i / WAD)
creatorNew    = distributable - sum(pluginShare_i)
```

The immediate `msg.sender` receives the tip through an ordinary ETH transfer before plugin iteration. If that transfer fails, the flush reverts atomically: pot zeroing/redemption, carry changes, plugin calls, events, and every transfer in the flush are rolled back. The payout path then iterates the plan's at-most-eight set bits in ascending order. For each entry, `attempted = pluginShare_i + previousCarry_i`; carry is cleared before the external call. Plugin success is exactly the EVM `CALL` success bit: a non-reverting `void onPayout(PoolId,address)` call succeeds, and the core ignores all returndata, whether empty, malformed, or arbitrarily long. A zero success bit—including explicit revert or stipend exhaustion—restores the full attempted value as carry. A suspended or codehash-mismatched entry is not called: its attempted amount is credited to creator entitlement and its carry is permanently cleared. A zero attempted amount is skipped.

After plugin iteration, `creatorNew` plus all redirects is credited—not pushed—to `_creatorPathClaimable[poolId]`. A carry-only flush iterates `_carryBitmap` with no redemption, allocation, or tip. Empty pot plus empty bitmap returns before any unlock or transfer.

**Why:** Separating current allocation from previous carry is what prevents repeat tips. Clearing before interaction prevents replay. Creator-last subtraction absorbs every fixed-point remainder and gives a simple conservation identity.

**Alternatives considered:** Recalculate shares from gross harvest (service fee and tip become ambiguous); include carry in the tip base (charges failed value repeatedly); push creator ETH during arbitrary flush (recipient failure can block permissionless settlement).

### 8. Treat plugin delivery as an untrusted bounded call under a protocol-global transient guard

**Decision:** Add a protocol-global payout-delivery transient lock in addition to existing pool-scoped locks. Every flush, direct/global claim, fee collection, graduation, governance execution path on the hook, and delegated payout entry checks it. The registry has no independent authority path: each registry-only mutation is a typed `ProtocolController` execution, and immediately before mutating the registry the controller MUST query the hook's public global-guard view and revert if payout delivery is in flight. This check occurs at execution, not scheduling, so no registry term or suspension state can change during a plugin attempt. While held, no pool can start another protected operation. Hook callbacks caused by a reference plugin's PoolManager interaction return without deployment, harvest, graduation, fee collection, or payout side effects.

Each plugin receives a plain ETH call to:

```solidity
function onPayout(PoolId poolId, address token) external payable;
```

The payout path forwards no more than the immutable registered stipend and reserves enough outer gas for remaining destinations and final accounting. The published constants are `CALL_FIXED_GAS = 15_000`, `POST_CALL_GAS = 100_000`, `FINALIZE_GAS = 100_000`, and `MAX_PLUGIN_CALL_GAS = 500_000`; registration accepts `1 <= callGas <= MAX_PLUGIN_CALL_GAS`. `CALL_FIXED_GAS` conservatively covers the value-bearing `CALL` base, cold-account access, and instructions between the check and opcode; `POST_CALL_GAS` covers one worst-case carry restoration, aggregate/bitmap update, event, and loop step; `FINALIZE_GAS` covers creator credit, liability assertions, events, guard exit, and return. Let `remainingCalls` include the current call and every unresolved later selected entry, so skipped later entries only over-reserve. Immediately before each `CALL`, compute `reserve = remainingCalls * POST_CALL_GAS + FINALIZE_GAS`, `eip150Margin = (callGas + 62) / 63`, and require `gasleft() >= reserve + callGas + eip150Margin + CALL_FIXED_GAS`. The payout path samples `gasleft()` after suspension/codehash resolution, zero-attempt filtering, carry clearing, liability effects, and callback calldata materialization, and before any call-specific setup not covered by `CALL_FIXED_GAS`. If the check fails, the entire flush reverts, so preflight failure is never misclassified as plugin failure. The integer margin is exactly `ceil(callGas / 63)` and ensures EIP-150 can forward the full stipend while preserving the reserve; the registered maximum bounds the arithmetic and per-call work. Calls are authenticated by `msg.sender == hook` in protocol-authored plugins. The core does not grant approvals, expose arbitrary callback data, or let a plugin select a pool other than the source context.

**Why:** A pool-scoped lock would allow a malicious plugin to attack another pool or global ledgers during delivery. A global transient guard matches the requirement that all protocol custody be unavailable during untrusted execution and automatically clears on transaction completion or revert. An outer gas reserve is necessary because a stipend alone does not ensure the caller can finish after EIP-150 forwarding and adversarial gas use.

**Alternatives considered:** Pool-local locks (cross-pool reentry remains); persistent guard (extra writes and cleanup risk); `try/catch` without gas reserve (callee can starve final accounting); delegatecall plugins (total storage and authority compromise).

### 9. Make creator payout an internal entitlement with a dedicated holder entry

**Decision:** The creator destination is the implicit mandatory sink/path, never a selectable registry plugin. Flush credits `_creatorPathClaimable[poolId]` as the implementation ledger for creator-path entitlement. `claimCreatorPath(poolId)` records the caller as the initial RevenueNFT owner, invokes the same flush machinery first, then queries RevenueNFT ownership again after every plugin interaction and before any final transfer; if ownership changed, the complete call reverts. It then zeros and attempts to transfer the complete creator-path entitlement produced by the flush, including the 1% self-flush tip that an ordinary flusher would have received. This final creator transfer is the sole non-reverting tip-transfer exception: on failure, the complete attempted amount is restored to creator-path entitlement, aggregate counters are restored, the call returns an explicit failure result with attempted amount, and an event records pool, current holder, attempted amount, and failure. On success it returns success and emits the paid amount. No partial amount may remain outside the ledger.

The existing `claimCreator(poolId)` remains a separate NFT-gated path for graduation and quote-fee revenue and never flushes. RevenueNFT transfer itself performs no settlement; ownership lookup at claim time transfers both unpaid entitlements without moving ledger state.

**Why:** An arbitrary third-party flush must not depend on the current holder accepting ETH, while a holder should be able to atomically settle pending pot value and withdraw their complete entitlement. Keeping the two creator ledgers distinct preserves source semantics and plugin-independent direct claims.

**Alternatives considered:** External creator-sink plugin holding funds (duplicates NFT authorization and custody); push to current owner on every flush (recipient can block settlement); merge creator ledgers (direct claims would implicitly depend on flush semantics).

### 10. Move buyback into an authenticated external plugin

**Decision:** `BuybackAndBurnPlugin` is registered as a selectable payout role with immutable hook and PoolManager authentication. It accepts only hook calls, uses exactly `msg.value` in its own cold unlock to buy the launch token from the supplied source pool, requires atomic completion within immutable price/execution bounds, and burns every token received. Failure reverts the plugin call, causing the hook to retain the full attempted amount as carry.

No protocol-authored swap-and-flush composition exists. Flush is a standalone permissionless call whose 1% tip is paid to the immediate caller; the only same-transaction creator composition is `claimCreatorPath`, which flushes internally and retains its own tip for the holder. Integrators who want batched or composed settlement use public audited infrastructure or their own thin keeper contract.

**Why:** Buyback no longer belongs in `afterSwap`; isolating it as a selected plugin removes nested untrusted work from every trader's path. A dedicated swap-and-flush helper was considered and dropped before release: its only irreplaceable value was tip race avoidance for the triggering trader, it duplicated settlement machinery that audited routers already own, and every state-changing claim path already pays its named recipient directly, so no protocol surface is required for beneficiary composition.

**Alternatives considered:** Keep inline buyback (plugin failure blocks swaps); a protocol swap-and-flush helper (thin MEV-hygiene wrapper duplicating router settlement; removed — see above); routing tips through an arbitrary recipient parameter (spec churn with no demonstrated integrator demand; re-evaluate if public bundler demand emerges).

### 11. Use typed operation hashes and capture readiness at schedule time

**Decision:** The governance controller derives operation identity from action type, complete ABI-encoded parameters, controller address, `block.chainid`, and caller-supplied salt. Scheduling stores an absolute ready timestamp computed from the delay then active. Cancellation deletes that pending identity; execution deletes it before invoking the typed target. A delay update is itself an operation, so it waits under the old captured delay. Administrator replacement alone uses propose/accept and does not transfer revenue-recipient authority.

Initial delay is zero. Deployment may schedule and execute bootstrap operations in one multisig batch. The controller supports increasing or later decreasing delay through the same queue; a decrease cannot execute sooner than the delay active when it was queued.

**Why:** Captured readiness gives non-retroactive queue semantics. Domain-binding avoids replay across controller deployments or chains. Delete-before-call prevents operation replay and narrows reentrancy behavior.

**Alternatives considered:** Read current delay at execution (retroactively changes pending operations); unrestricted calldata hashes (generic timelock authority); immediate owner setters (no auditable queue structure or future reaction window).

### 12. Remove obsolete state and make the remaining fee and liquidity behavior structural

**Decision:** Remove `HarvestSplit`, vesting duration/amount/released state, mutable base-fee state, fee-step thresholds and events, `pendingLpQuote`, `pendingLpToken`, inline buyback, donation, and positive full-range-liquidity helpers. Pools initialize with the template's literal 1% fee and no `DYNAMIC_FEE_FLAG`; no path calls `updateDynamicLPFee`.

Fee collection retains zero-delta `modifyLiquidity` but routes quote to direct creator plus global protocol and token to milestone inventory plus burn. For one pool define `perBand = floor(totalSupply * ladderSupplyShareWad / WAD / coreBandCount)`, `bandCap = perBand * bandInventoryCapMultiple`, `remainingExtensions = maxFeeFundedBands - feeFundedBandsCreated`, and `freeCapacity = max(remainingExtensions * bandCap - carriedInventory - milestoneFundAccrued, 0)`. Only `min(floor(tokenFees * tokenMilestoneFundShareWad / WAD), freeCapacity)` may be added to milestone funding; every excess token is burned in the same collection. This counts capacity of still-undeployed fee-funded extension bands only: deployed bands and core-band entitlements do not create capacity, and zero remaining capacity means 100% burn. The graduation path alone may add full-range liquidity; its immutable 40/55/5 split remains separate from `EconomicConfig`. Source-level lock checking is extended to reject both negative and post-graduation positive changes involving `FULL_RANGE_SALT` outside the single graduation seed site.

**Why:** Deleting state and callers is safer than leaving disabled branches and recovers bytecode for payout safety. Structural absence is the strongest guarantee that governance cannot re-enable dynamic fees or compounding.

**Alternatives considered:** Retain zero-valued LP shares and fee steps (dead state can be accidentally revived); leave dynamic pool keys but never update them (pool identity advertises capability the protocol forbids); send burned token fees to an external burner (unnecessary transfer surface because `MilestoneToken` already supports caller-owned burn).

### 13. Extend tests around state transitions, adversarial plugins, and solvency

**Decision:** Preserve the three-layer strategy but replace obsolete scenario mappings.

- Unit suites cover registry immutability, plan validation and identity, typed governance, global economics, pot funding, exact flush math, suspension/codehash redirects, CALL-bit success with ignored returndata, carry retry, EIP-150 preflight and gas exhaustion, ordinary-tip atomic failure, same/cross-pool reentry, creator-path NFT semantics and post-plugin ownership recheck, buyback, static fees, immediate dev buy, aggregate liability/custody invariants, capacity-clamped token burning, global protocol claiming, and fixed locked liquidity.
- Invariants drive multiple pools and alternate ordinary swaps, fee collection, flush/carry retry, direct and plugin creator claims, global protocol claims, NFT transfer, governance, and suspension. Ghost accounting proves global and per-pool solvency, new-pot-plus-carry conservation, no double tip/delivery, registry/plan immutability, token-fee fund-plus-burn conservation, static fees, and unchanged locked liquidity.
- Base-fork tests validate real PoolManager claim redemption, separate unlocks, both currency orientations, buyback execution, callback suppression, failure carry, and global claims.

Every scenario section comment continues to mirror its delta-spec scenario literally. Fixture and harness test-only unlock actions remain at 200 or above. `make size`, layout, cold-path guard, lock, pin, unit, invariant, fork, and release gates remain mandatory.

**Why:** Payout correctness is sequential and cross-ledger: isolated unit examples do not establish that a failed plugin, NFT transfer, governance update, and later retry conserve value together. Invariants and live-v4 fork execution are necessary complements.

**Alternatives considered:** Unit-only verification (misses stateful replay and custody interactions); mock-only PoolManager tests (cannot validate ERC-6909 and unlock ordering); scenario-name aggregation without literal headers (breaks the repository's traceability convention).

## Risks / Trade-offs

- **Hook or satellite exceeds EIP-170** → Keep plugin delivery in `MilestonePayoutPaths`, remove obsolete dynamic-fee/vesting/compounding code early, and run size gates after each structural tranche.
- **Delegatecall storage corruption** → Declare hook-owned state only in `MilestoneBase`; compare the hook and every satellite to that base and enforce `onlyDelegated` on every mutating satellite entry.
- **Immutable mismatch across delegatecall halves** → Give satellites matching constructor dependencies, expose hashes/address views, and fail deployment verification before NFT/plugin authentication is finalized.
- **A registered contract changes code through a proxy or metamorphic deployment** → Reject proxy-like entries at registration, pin `extcodehash`, and redirect rather than invoke on mismatch. Governance may append a replacement index but cannot reinterpret old bits.
- **Gas-exhausting plugin prevents final accounting** → Fix `CALL_FIXED_GAS = 15_000`, `POST_CALL_GAS = 100_000`, `FINALIZE_GAS = 100_000`, and `MAX_PLUGIN_CALL_GAS = 500_000`; apply the exact EIP-150 preflight before every call, cap selected entries at eight, and adversarially test the boundary.
- **Cross-pool plugin reentrancy reaches global custody** → Hold one protocol-global transient payout guard and suppress all callback work during authenticated reference-plugin PoolManager interactions.
- **Claim or plugin transfer spends reserved ETH** → Maintain exact aggregate liability totals, classify harvest service fees in `_protocolClaimBacked` until exact redemption, and separately assert claim-backed coverage and raw-ETH coverage for direct, protocol, carry, and creator-path balances after every handler action.
- **Suspension confiscates historical plugin carry** → This is intentional policy: current share and carry redirect to the current creator entitlement. Emit the amount and source index; reactivation is prospective only.
- **Zero governance delay provides no reaction window** → Document it as bootstrap posture, require multisig administration operationally, preserve queue/cancel auditability, and allow a later delayed increase. On-chain code cannot enforce signer quality.
- **A later delay reduction weakens future protection** → The reduction itself waits under the old delay, giving the existing reaction window before weaker settings take effect.
- **Whole-pot redemption mixes with other claim backing** → Use a dedicated unlock action and exact amount, zero the pot before opening it, and test that one new pot produces exactly one redemption.
- **Rounding diverges from the nominal 2/9 and 7/9 default** → Publish the integer `takeWad`, compute plugin shares with floor division, and assign every remainder to creator entitlement; tests assert exact integer formulas rather than decimal approximations.
- **Buyback price movement or execution bounds cause repeated failure** → Preserve the full share as carry and keep swaps live; governance may suspend the plugin, redirecting carry to creator, but cannot silently change its terms.
- **RevenueNFT ownership changes during creator-path flush** → Snapshot the initiating holder, rerun `ownerOf` after all plugin interactions, and revert the complete operation if ownership changed before payment.
- **No post-graduation compounding reduces pool-depth growth** → Accepted product trade-off. The initial 40% quote/immutable-token full-range seed remains permanently locked, while later value goes to claims, burns, milestone inventory, or selected payouts.

## Migration Plan

There is no deployed production state to migrate. Implementation replaces the pre-deployment artifact set and requires a newly mined hook address.

1. Change shared types, signatures, template fields, and `MilestoneBase` storage; remove vesting, dynamic-fee, free-form harvest-split, LP-carry, and per-pool protocol-ledger surfaces.
2. Implement and unit-test `ProtocolController` and `PayoutPluginRegistry`, including typed operation identity, two-step administrator transfer, stable entries, code identity, and reversible suspension.
3. Refactor the hot harvest and lifecycle fee/graduation paths, then run layout, lock, build, and size gates before adding plugin delivery.
4. Implement `MilestonePayoutPaths`, dedicated pot redemption, exact aggregate liability accounting, global transient delivery guard, carry, creator-path claiming, ownership rechecks, and callback suppression; extend all delegatecall guard/layout checks.
5. Implement the authenticated buyback-and-burn plugin; add adversarial mocks and focused unit/invariant coverage.
6. Deploy controller and registry under a bootstrap administrator with initial zero delay. The final
   intended multisig is proposed after deterministic setup and accepts directly on the controller.
7. Deploy `RevenueNFT`, `LaunchSupport`, lifecycle satellite, and payout satellite with final immutable
   dependencies. Constructor arguments and satellite addresses are now fixed inputs to hook initcode.
8. Mine a new hook salt only after all immutable addresses and template values are final; deploy the hook
   with exactly the six required callback flags and static-fee pool behavior.
9. Bind the controller target, hand registry administration to it, and register protocol-authored
   components in deterministic order through typed zero-delay operations, including the buyback fixed take.
   Verify hook/satellite template hashes and dependency addresses, controller/registry authority,
   economics defaults/caps, entry indices/roles/code hashes/gas limits, canonical plan, recipient
   independence, and NFT minter wiring; then publish the canonical bitset.
10. Run local deployment dry-run, complete Base-fork lifecycle/adversarial campaigns, and a public-testnet rehearsal before mainnet publication.

**Rollback:** Contracts and registry entries are non-upgradeable, pool plans are immutable, and the hook has no runtime rollback. Before any production launch, rollback is redeployment with corrected contracts and a newly mined hook. After pools exist, they continue under their original hook and plan; a defective payout entry can be suspended to redirect its current and carried value to creators, but its code or terms cannot be replaced at the same index. A new implementation requires a new registry/hook deployment and frontends must stop creating pools on the old system.

## Open Questions

None. Contract names may change during implementation, but the contract split, explicit claim-backed protocol provenance, custody transitions, governance authority, registry identity rules, and test obligations are fixed by this design.