## Why

Every launchpad in the reference monorepo (sa1t, flaunch, Clanker/Liquid, Zora, Doppler, Liquidity Launcher) raises capital either once at launch (bonding curve / LBA) or never (instant AMM). None of them can raise *in lockstep with a token's performance*, because none model fundraising milestones as real liquidity positions. Virtuals Protocol proved the demand for milestone-gated founder proceeds and Pumpkin proved single-sided milestone positions work on Solana — but the mechanism does not exist on Uniswap v4.

This change builds it: a protocol-owned ladder of one-sided sell-limit bands at ascending market-cap levels, harvested automatically when the market reaches them, with configurable routing of the harvested value. The price reaching the level *is* the trigger — no oracle, no keeper.

## What Changes

This is a greenfield protocol. `DESIGN.md` at the repo root is the normative design; this change implements its **v1** scope on Base.

- **New Foundry project** in this repository: `foundry.toml` pinned to Solidity `0.8.26`, `evm_version = cancun` (transient storage is required), with `v4-core @ 5f00c84` and `v4-periphery @ 9628c36` installed at the pins named in `DESIGN.md §0`.
- **Permissionless launch entry** — validates every launch parameter against the `DESIGN.md §9` bounds table, then deploys the ERC20, mines the hook address, initializes the pool, and executes an optional creator dev buy against bonding curve inventory with optional linear vesting.
- **A single lifecycle hook** owning phase state (`NONE → BONDING_CURVE → GRADUATED`), the multicurve bonding curve positions, the milestone ladder, JIT band deployment, harvest settlement, fee collection and routing, dev-buy vesting, and anti-snipe. Graduation is an **in-place morph** — one pool, one hook, no migration path.
- **Bonding curve phase** (Doppler/Zora multicurve pattern): log-normal position fan minted once at initialize, no rebalancing, no epochs, no duration. Real two-sided liquidity, so sells are always possible.
- **Permissionless graduation** at `farTick`: burn curves, split proceeds 40% LP seed / 55% creator / 5% protocol, mint a code-locked full-range LP position (no removal code path exists).
- **The milestone ladder** — the differentiator. Uniform tick-spaced narrow bands (a 2× market-cap step is a constant 6,931 ticks), JIT-minted in `beforeSwap` when the pre-swap tick enters the deploy window, harvested atomically in `afterSwap` when the tick crosses `band.upper`. Harvest proceeds route through one global split (creator / buyback / protocol / LP). 30-day permissionless reclaim for unfilled bands.
- **Token-fee recycling into ladder inventory** (`MILESTONE_FUND`): up to 20% of token-denominated swap fees are diverted from LP compounding into the next band's inventory, extending the ladder indefinitely up to a 30 fee-funded-band cap. Sell pressure funds future walls.
- **Swap fee policy**: 1% pool fee routed 60% LP / 30% creator / 10% protocol via a permissionless `collectFees` sliver burn-and-re-add (v4 has no standalone collect). Dynamic fee covers both the anti-snipe decay (99% → 1% over a creator-chosen window) and the optional milestone-completion step-down, with anti-snipe taking precedence.
- **Transferable creator revenue NFT** (`tokenId = poolId`): pull-based claims on the creator's share of harvests, swap fees, and bonding curve proceeds. The revenue stream itself trades.
- **No breaking changes** — nothing exists yet to break.

Explicitly **out of scope** (deferred to v2 per `DESIGN.md §12`, with routing enum slots reserved in v1): milestone dividends / airdrop routing, treasury and staking destinations, a hard external `LPLocker`, the Dynamic Dutch Auction launch mode, minimum-proceeds with refund, the dead-token time-based force-graduate fallback, weighted band inventory, and per-milestone routing overrides.

## Capabilities

### New Capabilities
- `token-launch`: Permissionless launch entry — launch-parameter validation against protocol bounds, ERC20 deployment with full supply minted to the hook, hook address mining, pool initialization, optional dev buy against bonding curve inventory, and hook-held linear vesting.
- `bonding-curve-phase`: Pre-graduation multicurve mechanics — curve configuration and share accounting, log-normal position fan minted at initialize, hook-exclusive liquidity (no external LP mint or remove), unrestricted two-way trading, and indefinite dead-token behavior when `farTick` is never reached.
- `graduation`: Permissionless in-place morph at `farTick` — tick verification at call time, curve burn and balance collection, bonding curve proceeds split, code-locked full-range LP mint at the graduation price, and the phase transition that activates the ladder.
- `milestone-ladder`: Band geometry and uniform tick spacing, JIT deployment on approach, harvest detection and atomic settlement in `afterSwap`, harvest proceeds routing including reentrancy-guarded buyback, jumped-band and in-band-oscillation handling, 30-day permissionless reclaim, `MILESTONE_FUND` inventory sizing, and fee-funded ladder extension.
- `swap-fees`: Swap fee level and routing — the 60/30/10 waterfall, the permissionless `collectFees` sliver mechanism, anti-snipe dynamic-fee decay, the optional milestone-completion fee step schedule and its precedence against anti-snipe, and `MILESTONE_FUND` diversion of token-denominated fees with its caps.
- `revenue-claims`: The transferable creator revenue NFT (`tokenId = poolId`) and the pull-based claim paths for the NFT holder and the protocol, with current-holder claim semantics.

### Modified Capabilities

None — this repository has no existing specs.

## Impact

- **New code**: entire `src/` tree, plus `test/` and `script/`. `DESIGN.md §3` gives a reference decomposition (`MilestoneFactory`, `MilestoneHook`, `CreatorFeeNFT`, `MilestoneToken`) but explicitly marks it non-normative; the final contract layout is a `design.md` decision, constrained only by the obligations above and the requirement that no decomposition widen the trust surface.
- **New dependencies**: `v4-core @ 5f00c84`, `v4-periphery @ 9628c36`, `forge-std`. Permit2 is optional on the token.
- **Hook permissions**: `beforeInitialize`, `afterInitialize`, `beforeSwap`, `afterSwap`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, and `DYNAMIC_FEE_FLAG` — the address must be mined to encode these.
- **Toolchain constraint**: transient storage (`tstore`/`tload`) guards every settlement path, so `cancun` is mandatory and this protocol cannot deploy to pre-Cancun chains.
- **Testing**: unit tests per mechanism, Base fork tests over the full lifecycle, and invariant/fuzz suites on ladder accounting (supply conservation, routing splits summing to WAD, absence of any full-range removal path).
- **Reference material**: implementation patterns are borrowed from the vendored protocols at `~/Desktop/launchpad` per the `DESIGN.md §11` integration map. That directory is outside this repository and is read-only reference, not a dependency.
- **Accepted residual risks** carried from `DESIGN.md §10`: cost-based-only protection against flash-pump graduation, flash-loan sweeps completing milestones into a pump that later crashes, and current-holder NFT claim semantics.
