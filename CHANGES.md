# CHANGES — v2 (pre-deployment, breaking)

`add-payout-plugins` replaces the original pre-deployment artifact set. No production state exists, so
signed-data, CREATE2, storage-layout, and deployment changes require a new mined hook rather than a
migration.

## 1. Immutable payout plans

Each launch signs one exact `uint256 payoutPlan`. Set bits select stable indices in the append-only
`PayoutPluginRegistry`; a plan may enable at most eight active `PAYOUT` entries and their fixed takes
must sum to at most `WAD`. Plugin addresses, takes, gas limits, roles, and registered code hashes never
change. Suspension is reversible, but a suspended or codehash-invalid destination redirects its current
share and existing carry permanently to the creator path.

The creator is the mandatory implicit remainder sink. An empty plan pays the creator 100%; arithmetic
dust also belongs to the creator. Preset names are offchain only and do not participate in launch
identity. The canonical plan selects buyback-and-burn with take `floor(2 * WAD / 9)`.

## 2. Harvest pots and asynchronous delivery

A completed milestone records gross quote proceeds, takes the active harvest service fee (10% by
default), credits that fee to the single global protocol ledger, and credits the net amount to the
source pool's payout pot. Both values remain backed by PoolManager quote claims while the crossing swap
is in flight. Harvesting performs no destination call, buyback, donation, or ETH transfer.

Any address may later `flush(poolId)`. A non-empty flush redeems the complete new pot exactly once,
pays the caller 1% of that net pot, and walks selected plugins in ascending index order. Carry-only
flushes perform no redemption or additional tip. Plugin calls receive plain ETH through the fixed
`onPayout(PoolId,address)` callback, use immutable gas stipends with an EIP-150 reserve preflight, and
succeed solely from the EVM call-success bit; returndata is ignored.

A failed or gas-exhausting plugin preserves its complete attempted value as carry without blocking
later entries. Creator value is recorded rather than pushed during arbitrary flushes. The RevenueNFT
holder's `claimCreatorPath(poolId)` flushes first, retains the self-flush tip for the final payment,
rechecks ownership after plugin interactions, and restores the complete entitlement if the recipient
rejects ETH.

One protocol-global transient payout guard blocks same-pool and cross-pool reentry into custody,
lifecycle, claims, governance execution, and registry mutation. Nested PoolManager callbacks suppress
protocol work rather than reverting the reference buyback's swap.

## 3. Explicit custody classes

Payout pots and the claim-backed subset of global protocol revenue are backed by PoolManager quote
claims. Plugin carry, creator-path entitlement, direct creator claims, and non-claim-backed protocol
revenue are backed by raw ETH. Aggregate counters track every liability class, and exact redemption
actions prevent creator or protocol claims from consuming pot, carry, ladder-inventory, or locked-LP
reserves.

Direct creator revenue remains per pool and follows current RevenueNFT ownership. Protocol revenue is
one global ledger paid only to the independently configurable protocol recipient. The administrator has
no implicit claim right.

## 4. Global economics and governance

The active versioned economic tuple contains:

- harvest service fee: 10% default, immutable 20% cap;
- quote-fee creator share: 75% default, immutable 90% cap; the protocol receives the remainder;
- token-fee milestone-fund share: 20% default, immutable 50% cap; excess tokens burn.

Updates apply prospectively to every pool and snapshot once per harvest or fee collection. The trading
fee and 40/55/5 graduation split remain immutable. `ProtocolController` exposes only typed delayed
operations, binds operation identity to complete parameters/controller/chain/salt, starts with a
zero-second delay, and uses the old delay for queued delay changes. Administrator transfer is two-step;
administrator and protocol recipient remain independent.

## 5. Static fees, immediate dev buy, and no compounding

Every pool uses a literal 1% Uniswap v4 fee for its complete lifetime. There is no dynamic-fee flag,
fee-step state, or governance path for the trading fee.

The optional creator dev buy remains capped at 10% of supply, executes completely during a creator-direct
launch, and transfers tokens immediately. Relayed launches cannot execute it. No vesting state or release
entry point remains.

Quote fees split 75% to direct creator revenue and 25% to global protocol revenue under the active
economic tuple. Token fees fund still-available extension capacity up to the active percentage and burn
the remainder; at the cap they burn entirely. Collected fees never add full-range liquidity, and no LP
fee carry exists. Graduation alone seeds the immutable 40% quote / 10% supply full-range position, which
remains code-locked forever.

## 6. Deployment and verification

`MilestoneHook`, `MilestoneColdPaths`, and `MilestonePayoutPaths` share only `MilestoneBase` mutable
storage. Both satellites are immutable delegatecall targets and must match the hook's PoolManager,
RevenueNFT, LaunchSupport, controller, registry, and template dependencies. Deployment creates the
registry, controller, NFT, support, and satellites first, finalizes every immutable address, then mines
and deploys a new hook. Bootstrap then binds the controller, hands registry authority to it, registers the
canonical buyback through a zero-delay typed operation, wires the NFT minter, and proposes the operational
multisig. That exact pending multisig must call the controller directly to accept administration.

Required evidence includes formatting, compilation, pins, EIP-170 size, storage-layout and delegated-entry
guards, full-range lock checks, literal OpenSpec scenario coverage, unit/invariant/fork suites where an
RPC is available, and the release gate. Public-testnet rehearsal remains environment-dependent.