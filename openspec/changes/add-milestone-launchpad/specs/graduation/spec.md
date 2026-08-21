## Purpose

Defines the one-way, permissionless transition from the bonding curve phase to the graduated phase: the bonding curve positions are retired in place, proceeds are split, a permanently locked full-range position is seeded, and the milestone ladder becomes active.

## ADDED Requirements

### Requirement: Permissionless graduation at the far tick

The system SHALL allow any address to trigger graduation once the pool's current tick has reached the configured far tick. The system SHALL verify the tick condition at call time rather than relying on any recorded flag, timestamp, or external attestation.

#### Scenario: Graduation succeeds at or above the far tick

- **WHEN** any address triggers graduation while the pool's current tick is at or above the far tick
- **THEN** graduation completes and the pool enters the graduated phase

#### Scenario: Graduation is rejected below the far tick

- **WHEN** any address triggers graduation while the pool's current tick is below the far tick
- **THEN** the call reverts and the pool remains in the bonding curve phase

#### Scenario: No privileged trigger

- **WHEN** an address unrelated to the creator or the protocol triggers graduation with the tick condition met
- **THEN** graduation completes on the same terms as if the creator had triggered it

#### Scenario: Tick condition is evaluated at call time

- **WHEN** the pool's tick reached the far tick earlier but has since fallen back below it, and graduation has not yet been triggered
- **THEN** a graduation call reverts

#### Scenario: Graduation happens once

- **WHEN** graduation is triggered on a pool that is already in the graduated phase
- **THEN** the call reverts, and no positions are re-minted and no proceeds are re-split

### Requirement: Curve retirement and proceeds collection

Graduation SHALL burn every bonding curve position and collect both the resulting token and quote balances and all swap fees accrued to those positions.

#### Scenario: All curve positions are burned

- **WHEN** graduation completes
- **THEN** no bonding curve position holds any liquidity

#### Scenario: Accrued curve fees are collected

- **WHEN** graduation completes on a pool whose curves accrued swap fees during the bonding curve phase
- **THEN** those fees are collected into hook custody and are included in the amounts subject to the graduation split and the full-range seed

#### Scenario: No value is stranded in retired positions

- **WHEN** graduation completes
- **THEN** the sum of the split allocations and the full-range seed accounts for the entire balance released by the burned curves, up to rounding dust retained by the hook

### Requirement: Bonding curve proceeds split

Graduation SHALL split collected bonding curve quote proceeds three ways: an LP-seed share, a creator share credited for pull-based claiming, and a protocol share credited for pull-based claiming. The defaults SHALL be 40% LP seed, 55% creator, and 5% protocol. The LP-seed share SHALL be configurable per launch with a floor of 20%.

#### Scenario: Default split is applied

- **WHEN** graduation completes on a launch that did not override the LP-seed share
- **THEN** 40% of quote proceeds seed the full-range position, 55% is credited to the creator's claimable balance, and 5% is credited to the protocol's claimable balance

#### Scenario: Configured LP-seed share is honoured

- **WHEN** graduation completes on a launch configured with an LP-seed share above the floor
- **THEN** that share seeds the full-range position and the remainder is distributed to creator and protocol in their configured proportions

#### Scenario: Split allocations sum to the collected proceeds

- **WHEN** graduation completes
- **THEN** the LP-seed amount, creator credit, and protocol credit sum to the collected quote proceeds, up to rounding dust

#### Scenario: Creator proceeds are not pushed

- **WHEN** graduation completes
- **THEN** no quote asset is transferred to the creator during graduation; the creator share is only credited as a claimable balance

### Requirement: Full-range position seeding

Graduation SHALL mint a single full-range liquidity position at the graduation price, funded with the LP-seed share of quote proceeds and the configured full-range token share of total supply.

#### Scenario: Full-range position is created at the graduation price

- **WHEN** graduation completes
- **THEN** a full-range position exists, owned by the hook, priced at the tick observed at graduation

#### Scenario: Full-range position is funded from both sides

- **WHEN** graduation completes
- **THEN** the position is funded with the LP-seed quote amount and the configured full-range share of total supply, with any unusable remainder retained in hook custody

#### Scenario: Ladder inventory is untouched by seeding

- **WHEN** graduation completes
- **THEN** the ladder supply share remains in hook custody, unallocated to the full-range position

### Requirement: Full-range position is permanently locked

The system SHALL expose no code path, for any caller including the creator and the protocol, that removes or reduces liquidity from the full-range position. Fee collection from that position SHALL NOT reduce its net liquidity.

#### Scenario: No caller can withdraw the full-range position

- **WHEN** any address attempts to remove liquidity from the full-range position, by any entry point
- **THEN** the attempt reverts

#### Scenario: Fee collection preserves net liquidity

- **WHEN** the permissionless fee collection path runs against the full-range position
- **THEN** the position's liquidity after collection is at least its liquidity before collection

#### Scenario: Lock survives ladder exhaustion

- **WHEN** every ladder band, including fee-funded extensions, has been completed or reclaimed
- **THEN** the full-range position remains in place and still cannot be removed

### Requirement: In-place phase transition

Graduation SHALL keep the same pool and the same hook. The system SHALL NOT create a second pool, deploy a second hook, or migrate liquidity to another venue.

#### Scenario: Pool identity is unchanged

- **WHEN** graduation completes
- **THEN** the pool identifier, token pair, and hook address are identical to their pre-graduation values

#### Scenario: Phase advances to graduated

- **WHEN** graduation completes
- **THEN** the phase is graduated, bonding-curve-phase behaviour no longer applies, and the milestone ladder is active

#### Scenario: No migration entry point exists

- **WHEN** any address attempts to move pool liquidity to a different pool or hook
- **THEN** the attempt reverts
