# CHANGES — v2 (pre-deployment, breaking)

Four coordinated changes, one generation (`add-payout-plugins`). Nothing is deployed, so
typehash, CREATE2 and storage breaks are free. Behaviour only is specified here — naming,
signatures and file layout are the implementer's call.

## 1. Payout plugins (milestone proceeds)

Replace the hardcoded post-harvest split with a signed, immutable **payout plan** per launch:

- The plan is a **bitset, not percentages**: each registered plugin carries a fixed take; the
  creator only chooses which are enabled. Enabled takes must total ≤100%; the **remainder
  always goes to the creator**. Creator payout is the implicit sink, always on — untick
  everything and the creator keeps 100% of the pot. The plan is salt-bound into the token
  address and can never change. Per-launch free-form splits disappear.
- The protocol service fee (template %) is taken natively at harvest into a **single global
  protocol ledger** (one pool-agnostic claim path). The remainder accrues to a **per-pool pot**
  (ETH-backed claims; mid-swap custody rules unchanged).

**Delivery — permissionless flush, always cold, own unlock**: redeem the whole pot to ETH once,
pay the caller a **flat template tip** (fixed %, no decay curve), then walk the plan. Plugins
are called one at a time, gas-stipended, in try/catch — a failing plugin never blocks the
others; its share **carries** to the next flush. Plugins receive plain ETH. No payout work ever
runs inside a swap callback: delivery can bounce mid-swap, plugins need their own unlock,
traders would conscript gas, and settlement must stay a side effect of swaps, never a
precondition. Liveness: the tip, the creator's self-flushing payout path, and a swap-time flush
helper.

**Creator money**: curve proceeds and the swap-fee share stay claimable directly from the hook's
per-pool ledger — no flush involved. The pot share is paid by the creator-payout plugin, whose
payout entry **flushes first, then pays**, with the tip passed back to whoever flushed — a
creator claiming for themselves loses nothing. Multi-pool batching is an offchain multicall
concern; the protocol ships no batch entry points.

**Accounting**: harvest events record milestone index and gross amount — the attribution record
for indexers. Plan shares apply **net of tip**; flush and plugin-ledger events carry settlement
truth. On-chain per-milestone (tranche) accounting is deferred to the first plugin that needs
per-milestone delivery — no history is lost, since plans are frozen at launch and such a plugin
can only appear in plans created after it ships.

**Reference plugins** (protocol-authored, registered in the plugin registry): buyback-and-burn; LP
compounding into in-range liquidity; creator payouts on demand; a same-transaction flush helper
for opted-in swappers.

## 2. Fee: flat 1% forever

Delete both step-downs. The fee is the template's static base (1%) for the pool's lifetime: no
dynamic-fee flag in the pool key, no step logic, no step events, no per-pool mutable fee.

## 3. Remove dev buy vesting

The dev buy (still ≤10% of supply) executes **fully at launch**. Delete the vesting config
field, all vesting state and math, the release entry point, and its bound.

## 4. Token fees: 80% burn, 20% milestone fund

The token side of fee routing becomes 80% burned (hook takes custody and burns — cold path) and
20% milestone fund (diversion unchanged, only within ladder cap). Past the cap: 100% burn
(confirm). Token-side full-range compounding disappears; audit the token-side carry for dead
state (quote-side carry unaffected).

## Cross-cutting

- **Plugin registry instead of a baked whitelist**: an append-only registry of plugins and
  their fixed takes, referenced by the hook through a single immutable address. **Adding a
  plugin is a registry entry — no new template, no re-mined hook, no new generation.**
  Entries are never removed or reordered — plans index positions, so shifting them would
  redirect existing pools to the wrong plugin — but a plugin can be **suspended**: new plans
  cannot enable it, and a suspended plugin's share reverts to the creator remainder.
  Addresses and takes never change after registration, so a signed plan keeps its meaning
  forever. Word size caps the registry at 256 plugins. A canonical default bitset mirrors
  today's routing, pinned as an equivalence test.
- **Presets are offchain-only**: named default bitsets ("classic", "buyback-max", …) live in
  docs/frontend. Signatures bind the bitset, never the preset name.
- **Gates**: expect the hook to shrink (size); layout gate (all new state in the shared base);
  full release check.
- **Specs** (openspec `add-payout-plugins`): deltas to `milestone-ladder`, `revenue-claims`
  (global protocol ledger), `swap-fees` (flat fee), `token-launch` (plan, no vesting); new
  `payout-plugins` capability (immutability, flush liveness, stipend, carry, tip, pot
  isolation, drain protection, bitset plan, remainder-to-creator).
- **Tests**: rework the fee-step, dev-buy-vesting and harvest-routing suites.

## Follow-up generations (not this change)

1. **Lottery plugin** (hold: per-pool pot, snapshot → merkle → pull claims).
2. **Community-gated creator pay** (hold: per-milestone tranches delivered via plugin metadata;
   majority vote per tranche; offchain snapshot + optimistic challenge). Ships the tranche
   ledger with it.

## Open questions

1. Past the ladder cap, token fees burn 100% — confirm.
2. Flat tip percentage (~1%?) — a template value, picked at deployment.
