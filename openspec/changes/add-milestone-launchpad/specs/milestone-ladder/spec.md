## Purpose

Defines the milestone ladder: a protocol-owned series of narrow single-sided sell bands at ascending market-cap levels, deployed just in time as the price approaches each one, harvested atomically when the price crosses out the top, and routed per the launch's harvest split.

## ADDED Requirements

### Requirement: Deterministic band geometry

Band ticks and inventory SHALL be fully derivable from the launch configuration and the graduation price, with no hidden or off-chain parameters. Bands SHALL be spaced at uniform tick offsets so that each successive band sits at a constant market-cap multiple of the previous one, and each band SHALL be a narrow range whose width is the configured fraction of the band gap.

#### Scenario: Band ticks are computable by any observer

- **WHEN** an observer reads the launch configuration and the graduation tick
- **THEN** every core band's lower tick, upper tick, and target inventory can be computed without additional information

#### Scenario: Uniform tick spacing yields geometric market caps

- **WHEN** bands are laid out from the graduation tick using the configured tick spacing
- **THEN** the tick offset between consecutive band lower bounds is constant, and the implied market cap of each band is a constant multiple of the previous band's

#### Scenario: Band width is a fraction of the gap

- **WHEN** bands are laid out
- **THEN** each band's tick width equals the configured fraction of the band gap, and no band overlaps its neighbour

#### Scenario: One geometry setting applies to all bands

- **WHEN** a launch is configured
- **THEN** band count, tick spacing, band width, and ladder supply share are single values applied uniformly across all core bands, with no per-band overrides in this version

### Requirement: Just-in-time band deployment

The system SHALL NOT deploy bands at graduation. A band SHALL be minted during the swap whose pre-swap tick lies inside that band's deploy window — the range immediately below the band's lower tick, sized as the configured fraction of the band gap — and only when the swap moves the price toward the band.

#### Scenario: Band is minted on approach

- **WHEN** a swap begins with the pre-swap tick inside the next band's deploy window and moves the price upward
- **THEN** the band is minted as single-sided token liquidity before the swap executes

#### Scenario: No bands exist immediately after graduation

- **WHEN** graduation completes and no swap has yet approached the first band
- **THEN** no band positions exist, and the ladder inventory sits in hook custody

#### Scenario: Downward swaps do not mint

- **WHEN** a swap begins with the pre-swap tick inside a band's deploy window but moves the price downward
- **THEN** no band is minted

#### Scenario: A single sweeping swap still fills correctly

- **WHEN** a swap begins inside the deploy window and is large enough to push the price above the band's upper tick in one transaction
- **THEN** the band is minted before the swap executes, the swap fills it, and the milestone is harvested within the same transaction

#### Scenario: Bands below spot never deploy

- **WHEN** the current tick is already above a band's upper tick and that band has never been deployed
- **THEN** the band is not minted, since a single-sided sell band below spot would hold no token inventory

#### Scenario: At most one band is live at a time

- **WHEN** any sequence of swaps and harvests has occurred after graduation
- **THEN** at most one band position exists at any moment, and it is the lowest band level that is neither complete nor skipped

### Requirement: Jumped bands are skipped benignly

If the price moves past a band without that band having been deployed, the system SHALL leave that band's inventory in hook custody and re-target it at the next band in line. The system SHALL NOT revert, lock the ladder, or lose the inventory.

#### Scenario: Inventory survives a jumped band

- **WHEN** a swap moves the pre-swap tick from below a band's deploy window to above the band's upper tick without triggering a mint
- **THEN** the swap succeeds, the band is treated as skipped, and its inventory remains in hook custody

#### Scenario: Skipped inventory re-targets the next band

- **WHEN** the next band in line is deployed after an earlier band was skipped
- **THEN** the skipped band's inventory is available to that next band's deployment

#### Scenario: Ladder continues after a skip

- **WHEN** a band has been skipped
- **THEN** subsequent bands still deploy and harvest normally

### Requirement: Harvest detection and atomic settlement

The system SHALL detect milestone completion within the same transaction as the swap that causes it: when the post-swap tick is at or above a deployed, incomplete band's upper tick, the band SHALL be marked complete, its position burned, and its released quote proceeds and accrued swap fees settled and routed before that transaction ends.

#### Scenario: Crossing the band top completes the milestone

- **WHEN** a swap ends with the post-swap tick at or above a deployed, incomplete band's upper tick
- **THEN** the band is marked complete, its position is burned, and its proceeds are routed within the same transaction

#### Scenario: Partial fill does not complete the milestone

- **WHEN** a swap ends with the post-swap tick inside a deployed band's range
- **THEN** the band remains incomplete, its position remains in place partially converted, and no routing occurs

#### Scenario: Band swap fees fold into the harvest

- **WHEN** a band that accrued swap fees while in range is harvested
- **THEN** those fees are collected with the band's balance and are included in the routed amount

#### Scenario: A swap sweeping past several band levels settles the deployed one

- **WHEN** a single swap ends above the upper ticks of several consecutive band levels, one of which was deployed
- **THEN** the deployed band is completed and routed within that transaction, and the levels that were never deployed are treated as skipped

#### Scenario: A completed band cannot be harvested again

- **WHEN** a subsequent swap ends above a band that is already marked complete
- **THEN** no additional routing occurs for that band

#### Scenario: Price falling back does not un-complete a band

- **WHEN** the price falls back below a completed band's range
- **THEN** the band stays complete, and it is not re-minted

### Requirement: Harvest proceeds routing

Harvest proceeds SHALL be split per the launch's global harvest configuration into creator, buyback, protocol, and LP shares whose sum is exactly one whole unit. The creator and protocol shares SHALL be credited as claimable balances. The buyback share SHALL purchase the launch token and burn it. The LP share SHALL be added to the full-range position.

#### Scenario: Shares are distributed per configuration

- **WHEN** a milestone is harvested
- **THEN** the creator share is credited to the creator's claimable balance, the protocol share to the protocol's claimable balance, the buyback share is spent buying and burning the token, and the LP share is added to the full-range position

#### Scenario: Routed amounts sum to the harvest

- **WHEN** a milestone is harvested
- **THEN** the four routed amounts sum to the harvested proceeds, up to rounding dust retained by the hook

#### Scenario: Buyback reduces total supply

- **WHEN** a harvest with a non-zero buyback share settles
- **THEN** the tokens purchased with the buyback share are burned and total supply decreases by that amount

#### Scenario: A zero buyback share performs no swap

- **WHEN** a harvest settles on a launch configured with a zero buyback share
- **THEN** no nested swap is performed and the remaining shares are routed normally

#### Scenario: Creator proceeds are not pushed

- **WHEN** a milestone is harvested
- **THEN** no asset is transferred to the creator during settlement; the creator share is only credited

### Requirement: Settlement is reentrancy-guarded

Every settlement path that performs a nested pool interaction SHALL be guarded so that callbacks triggered by that interaction cannot re-enter settlement. Guard state SHALL not persist beyond the transaction.

#### Scenario: Nested buyback swap does not re-enter settlement

- **WHEN** the buyback swap during harvest settlement triggers hook callbacks
- **THEN** those callbacks do not start another harvest settlement, deploy a band, or route proceeds a second time

#### Scenario: Guard does not leak across transactions

- **WHEN** a transaction containing a harvest completes
- **THEN** the next transaction's swap and settlement paths are unobstructed

#### Scenario: Reverting nested interaction does not corrupt state

- **WHEN** a nested settlement interaction reverts
- **THEN** the whole transaction reverts and no band is left marked complete with unrouted proceeds

### Requirement: The hook never blocks a swap in the graduated phase

The system SHALL permit swaps in both directions at every price after graduation. Band deployment and harvest settlement SHALL be side effects of swaps, never preconditions on them.

#### Scenario: Swaps succeed in both directions

- **WHEN** a trader swaps in either direction at any price after graduation
- **THEN** the swap succeeds

#### Scenario: In-band oscillation is permitted but cannot prevent completion

- **WHEN** a trader repeatedly buys into and sells back out of a partially filled band's range
- **THEN** each round trip pays the pool spread twice, the band's conversion state churns without being lost, and the milestone completes as soon as any swap ends above the band's upper tick

#### Scenario: No size or timing gate

- **WHEN** a swap is unusually large, or arrives immediately after another swap in the same block
- **THEN** the hook does not revert it

### Requirement: Band inventory sizing and milestone-fund top-up

At deployment time a band's inventory SHALL be its configured share of ladder supply plus any inventory carried from skipped bands plus accrued milestone-fund tokens, capped at twice its configured share. Inventory above the cap SHALL carry forward to the next band rather than being discarded.

#### Scenario: Accrued milestone-fund tokens enlarge the band

- **WHEN** a band is deployed while milestone-fund tokens have accrued
- **THEN** the band's inventory is its configured share plus the accrued amount, subject to the cap

#### Scenario: Inventory is capped at twice the configured share

- **WHEN** accrued inventory would push a band above twice its configured share
- **THEN** the band is deployed at exactly twice its configured share

#### Scenario: Overflow carries to the next band

- **WHEN** a band's inventory is capped
- **THEN** the excess remains in hook custody and is available to the next band's deployment

#### Scenario: No inventory is created from nothing

- **WHEN** any band is deployed
- **THEN** its inventory is drawn only from hook-custodied tokens, and the sum of all deployed band inventory, harvested inventory, and custodied inventory never exceeds the tokens the hook has received

### Requirement: Fee-funded ladder extension

Once the configured core bands are exhausted, the system SHALL continue creating new bands at the same tick spacing above the last band, funded from accrued milestone-fund tokens, up to a protocol maximum of 30 fee-funded bands. Beyond that maximum, no further bands SHALL be created.

#### Scenario: A new band is created beyond the core ladder

- **WHEN** all core bands are complete or skipped and sufficient milestone-fund inventory has accrued
- **THEN** a new band is created one tick-spacing step above the last band and behaves like a core band for deployment, harvest, routing, and reclaim

#### Scenario: Extension stops at the cap

- **WHEN** 30 fee-funded bands have been created
- **THEN** no further bands are created, regardless of further accrual

#### Scenario: Extension requires accrued inventory

- **WHEN** the core ladder is exhausted and no milestone-fund inventory has accrued
- **THEN** no new band is created and the ladder is simply inactive until accrual resumes

### Requirement: Permissionless reclaim of stale bands

A deployed band that has remained incomplete for the configured reclaim period SHALL be reclaimable by any address: the position is burned and its inventory returns to hook custody, re-targeted at the next band in line. The default reclaim period SHALL be 30 days. Reclaim SHALL NOT burn, reprice, or redirect the inventory in this version.

#### Scenario: Any address can reclaim after the period

- **WHEN** an arbitrary address triggers reclaim on a band that has been deployed and incomplete for longer than the reclaim period
- **THEN** the band position is burned and its inventory returns to hook custody

#### Scenario: Reclaim before the period is rejected

- **WHEN** reclaim is triggered on a band deployed more recently than the reclaim period
- **THEN** the call reverts and the band remains deployed

#### Scenario: Reclaim is rejected for completed bands

- **WHEN** reclaim is triggered on a band already marked complete
- **THEN** the call reverts

#### Scenario: Reclaimed inventory re-targets the next band

- **WHEN** the next band in line is subsequently deployed after a reclaim
- **THEN** the reclaimed inventory is available to that deployment

#### Scenario: Reclaimed band can be redeployed later

- **WHEN** the price later approaches a previously reclaimed band's deploy window from below and that band is still the next in line
- **THEN** the band may be deployed again with available inventory

### Requirement: Bands are hook-owned and externally immutable

Band positions SHALL be owned by the hook. No external address SHALL be able to mint, resize, remove, reprice, or otherwise modify a band, nor withdraw band inventory.

#### Scenario: External band mutation is rejected

- **WHEN** any external address attempts to add to, remove from, or reprice a band position
- **THEN** the attempt reverts

#### Scenario: Creator cannot withdraw ladder inventory

- **WHEN** the creator attempts to withdraw undeployed ladder inventory from hook custody
- **THEN** the attempt reverts

#### Scenario: Band-boundary trading cannot extract beyond band prices

- **WHEN** a trader attempts to sandwich a band deployment or harvest
- **THEN** the trader's fills occur at prices within the band's configured range, and no external liquidity path exists to extract value from the band beyond those fills
