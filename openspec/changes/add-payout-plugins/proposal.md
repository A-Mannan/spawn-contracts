## Why

The fixed harvest split prevents launches from selecting protocol-approved payout behavior and performs settlement work on the swap path. Before deployment, the protocol can replace it without migration risk with immutable, signed payout plans that preserve accounting, isolate plugin failures, and make settlement permissionless.

## What Changes

- **BREAKING**: Replace each launch's free-form harvest split with a signed immutable bitset selecting append-only registry plugins with fixed takes; the creator receives the unallocated remainder.
- Add a payout-plugin registry capped at 256 immutable entries. Entries cannot be removed or reordered; suspension prevents selection by new launches and routes a suspended enabled share to the creator for existing launches.
- Accrue milestone proceeds net of a protocol service fee, initially 10% of gross, into isolated per-pool ETH-backed pots while consolidating protocol revenue into one pool-agnostic global ledger and claim path.
- Move all payout delivery out of swap callbacks into permissionless cold-path flushes. A flush redeems the whole pot in its own unlock, pays a fixed 1% tip, and invokes at most eight selected plugins independently with gas stipends; failed shares carry to the next flush.
- Add reference plugins for buyback-and-burn and creator payout. Creator plugin payout flushes first and returns the tip to the actual flusher. No protocol-authored swap-and-flush composition: flush is a standalone permissionless call and every claim path pays its named recipient directly. An LP-compounding payout plugin is excluded from this change.
- Keep curve proceeds and the creator share of swap fees directly claimable from the existing per-pool creator ledger, without requiring a flush.
- Add a separate configurable protocol administrator and protocol revenue recipient. The administrator uses two-step ownership transfer, controls registry entries and reversible suspension, and may update the service fee, quote-fee distribution, token burn/fund distribution, recipient, and timelock delay. Economic updates apply to all pools after the configured delay, initially zero, within immutable caps.
- **BREAKING**: Remove both dynamic fee step-downs and the dynamic-fee pool-key flag; keep the pool's static 1% trading fee for its lifetime.
- **BREAKING**: Remove dev-buy vesting configuration, state, release math, and release entry point. The allowed dev buy, still capped at 10% of supply, executes fully at launch.
- **BREAKING**: Remove all fee and payout LP compounding after graduation. Quote-denominated fees default to 75% direct creator revenue and 25% global protocol revenue; token-denominated fees default to 80% burn and 20% milestone funding while useful ladder capacity remains, then 100% burn. The initial locked full-range position seeded at graduation remains unchanged.
- Expand unit, invariant, and Base-fork coverage for plans, governance, registry stability and suspension, pot accounting, flush liveness and failure isolation, the global protocol ledger, static fees, immediate dev buys, fee routing and burning, and the absence of post-graduation compounding.

## Capabilities

### New Capabilities
- `payout-plugins`: Registry, immutable bitset plans, isolated payout pots, permissionless flushes, stipended plugin delivery, failed-share carry, flusher tips, reference plugins, governance, and drain protection.

### Modified Capabilities
- `milestone-ladder`: Replace direct four-way milestone routing with gross harvest attribution, service-fee accrual, and per-pool payout-pot funding outside the swap settlement path.
- `revenue-claims`: Consolidate protocol ETH into a global ledger and claim path while preserving NFT-gated per-pool creator claims and distinguishing direct creator revenue from plugin-pot proceeds.
- `swap-fees`: Remove dynamic trading-fee steps and all post-graduation fee compounding; make the service-fee, two-way quote-fee, and pre-cap token burn/fund distributions globally configurable within immutable caps.
- `token-launch`: Bind immutable payout-plan bits into signed launch configuration and CREATE2 derivation, reject plans with more than eight enabled plugins, and replace vested dev buys with immediate execution.
- `graduation`: Preserve the initial locked full-range position while removing every post-graduation fee and payout compounding path.

## Impact

This changes signed launch data, EIP-712 type hashes, CREATE2 token derivation, pool-key construction, launch and fee-routing APIs, storage layout, events, errors, governance, deployment inputs, and hook/satellite templates. It adds a registry and plugin contracts, expands cold-path delegatecall and unlock dispatch, removes vesting and fee-step surfaces, and requires fixture, unit, invariant, fork, deployment, documentation, layout, lock, size, and release-gate updates. Mutable economics add a governance trust surface bounded by delayed execution and immutable maxima. Because no contracts are deployed, these compatibility breaks require no migration of live state.
