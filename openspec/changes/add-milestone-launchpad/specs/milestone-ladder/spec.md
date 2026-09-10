## Purpose

Defines the milestone ladder: a protocol-owned series of narrow single-sided sell bands at ascending market-cap levels, deployed by simulating the incoming swap's price path before it executes, harvested atomically when the price crosses out the top, and routed per the launch's harvest split. Geometry is fixed by the protocol template; band state is tracked per index.

## ADDED Requirements

### Requirement: Deterministic band geometry

Band ticks and inventory SHALL be fully derivable from the protocol template and the graduation price, with no hidden or off-chain parameters. Bands SHALL be spaced at uniform level offsets so that each successive band sits at a constant market-cap multiple of the previous one, and each band SHALL be a narrow range whose width is the template fraction of the band gap. Geometry SHALL NOT be configurable per launch.

#### Scenario: Band ticks are computable by any observer

- **WHEN** an observer reads the protocol template and the graduation tick
- **THEN** every band's lower tick, upper tick, and target inventory can be computed without additional information

#### Scenario: Uniform tick spacing yields geometric market caps

- **WHEN** bands are laid out from the graduation tick using the template tick spacing
- **THEN** the tick offset between consecutive band lower bounds is constant (2,235 levels, a 1.25× market-cap step), and the implied market cap of each band is a constant multiple of the previous band's

#### Scenario: Band width is a fraction of the gap

- **WHEN** bands are laid out
- **THEN** each band's tick width equals the template fraction of the band gap (447 levels of the 2,235-level spacing), and no band overlaps its neighbour

#### Scenario: One template applies to all launches

- **WHEN** any launch is configured
- **THEN** band count, spacing, width, and ladder supply share come from the immutable protocol template with no per-launch overrides and no per-band overrides

### Requirement: Simulation-driven band deployment

The system SHALL NOT deploy bands at graduation. On a buy, the hook SHALL simulate the incoming swap's price path using the swap's own parameters and the pool's known protocol-owned liquidity profile, and SHALL deploy every undeployed band the simulated path crosses before the swap executes, so the swap fills them as real liquidity. Band deployments SHALL be capped per swap; a sell SHALL never deploy a band.

#### Scenario: A buy crossing multiple undeployed bands deploys each before filling it

- **WHEN** a buy's simulated path crosses the lower bounds of several consecutive undeployed bands
- **THEN** each crossed band is minted as single-sided token liquidity before the price reaches it, and the swap fills them in order within the same transaction

#### Scenario: A deployed band cannot be jumped without filling

- **WHEN** a swap's price path passes through a deployed band's range
- **THEN** the band's inventory is real pool liquidity in the path, and exiting the range's top necessarily consumed its inventory

#### Scenario: An undeployed band straddling spot deploys before the crossing buy fills it

- **WHEN** a buy's simulated path enters the range of a band that was never deployed
- **THEN** the band is minted before the price enters its range, and the straddle deadlock — a band that can neither deploy nor skip — cannot occur

#### Scenario: No bands exist immediately after graduation

- **WHEN** graduation completes and no swap has yet approached the first band
- **THEN** no band positions exist, and the ladder inventory sits in hook custody

#### Scenario: Downward swaps do not mint

- **WHEN** a sell arrives after graduation
- **THEN** no band is deployed

#### Scenario: Bands below spot never deploy

- **WHEN** the current level is already above a band's upper tick and that band has never been deployed
- **THEN** the band is not minted, since a single-sided sell band below spot would hold no token inventory

#### Scenario: A simulation mismatch can only under-deploy

- **WHEN** simulated execution differs from real execution at a band boundary
- **THEN** the only possible divergence is a band that was not deployed; inventory degrades to the skip-and-carry behaviour, and no inventory is ever sold that the simulation did not place

### Requirement: Band state is tracked per index

Band deployment and completion SHALL be recorded per band index in per-pool bitmaps, so that multiple bands may be live simultaneously and every band's lifecycle is independently observable. A completed band SHALL never redeploy, and deployment order SHALL remain strictly ascending.

#### Scenario: Multiple bands may be live simultaneously

- **WHEN** swaps deploy several consecutive bands without completing them all
- **THEN** each live band's deployed state is tracked independently by its index

#### Scenario: Completed bands never redeploy

- **WHEN** the price later approaches a completed band's level from below
- **THEN** no position is minted for that level; the band stays complete

#### Scenario: Deployment order is strictly ascending

- **WHEN** any sequence of deployments has occurred
- **THEN** no band below an already-deployed or completed index is deployed

### Requirement: Band deployments are capped per swap; overflow skips benignly

Band deployments within one swap SHALL be capped at a protocol maximum per swap. If a buy's simulated path crosses more undeployed bands than the cap, the excess bands SHALL be treated as skipped: the swap succeeds, their inventory remains in hook custody, and it re-targets the bands that deploy later. The system SHALL NOT revert, lock the ladder, or lose the inventory.

#### Scenario: Inventory survives a capped-out swap

- **WHEN** a single buy's simulated path crosses more undeployed bands than the per-swap deployment cap
- **THEN** the swap succeeds, the uncrossed-at-execution bands are treated as skipped, and their inventory remains in hook custody

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

#### Scenario: A sweeping swap harvests every band it completes within the cap

- **WHEN** a single swap ends above the upper ticks of several consecutive deployed bands, no more than the per-swap harvest cap
- **THEN** every such band is completed and routed within that transaction, in ascending order

#### Scenario: Harvests beyond the per-swap cap settle on the next swap

- **WHEN** a single swap ends above the upper ticks of more deployed bands than the per-swap harvest cap
- **THEN** the lowest bands are harvested up to the cap, the remainder remain live and complete, and the next swap that ends above them routes them

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

#### Scenario: Harvest proceeds are quote only

- **WHEN** a band is harvested
- **THEN** the routed proceeds are entirely ETH: the band's token inventory converted by the fills, plus the fees it accrued while in range; any token residue the position releases on burn returns to carried inventory, never to a recipient

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
- **THEN** a new band is created one tick-spacing step above the last band and behaves like a core band for deployment, harvest, and routing

#### Scenario: Extension stops at the cap

- **WHEN** 30 fee-funded bands have been created
- **THEN** no further bands are created, regardless of further accrual

#### Scenario: Extension requires accrued inventory

- **WHEN** the core ladder is exhausted and no milestone-fund inventory has accrued
- **THEN** no new band is created and the ladder is simply inactive until accrual resumes

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
