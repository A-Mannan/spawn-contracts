## Purpose

Defines what traders pay to swap and where those fees go: the dynamic fee level over a launch's life, the three-way fee waterfall, the permissionless collection mechanism, and the diversion of token-denominated fees into future ladder inventory.

## ADDED Requirements

### Requirement: Default swap fee

The pool's base swap fee SHALL default to 1%. Where a launch enables the milestone fee schedule, the base fee SHALL instead be that schedule's starting value.

#### Scenario: Default base fee applies after the anti-snipe window

- **WHEN** the anti-snipe window has elapsed on a launch that did not enable the milestone fee schedule
- **THEN** the pool's fee is 1%

#### Scenario: Milestone schedule sets the starting base fee

- **WHEN** the anti-snipe window has elapsed on a launch that enabled the milestone fee schedule
- **THEN** the pool's fee is the schedule's configured starting value

### Requirement: Fee routing waterfall

Collected swap fees SHALL be routed 60% to the full-range liquidity position, 30% to the creator's claimable balance, and 10% to the protocol's claimable balance.

#### Scenario: Fees split three ways on collection

- **WHEN** accrued swap fees are collected
- **THEN** 60% is added to the full-range position, 30% is credited to the creator's claimable balance, and 10% is credited to the protocol's claimable balance

#### Scenario: Routed amounts sum to collected fees

- **WHEN** fees are collected
- **THEN** the three routed amounts sum to the collected fees, up to rounding dust retained by the hook

#### Scenario: The LP share compounds

- **WHEN** the LP share of collected fees is routed
- **THEN** it increases the full-range position's liquidity rather than being credited to any claimable balance

#### Scenario: Anti-snipe windfall follows the same waterfall

- **WHEN** fees collected during the anti-snipe window are routed
- **THEN** they are split by the same 60/30/10 waterfall with no special-case accounting

### Requirement: Permissionless fee collection

Any address SHALL be able to trigger collection of accrued swap fees. Collection SHALL leave the full-range position's net liquidity unreduced, and its cost SHALL be bounded per call so that repeated triggering is not a griefing vector.

#### Scenario: Any address can trigger collection

- **WHEN** an arbitrary address triggers fee collection
- **THEN** accrued fees are collected and routed

#### Scenario: Net position is preserved

- **WHEN** fee collection completes
- **THEN** the full-range position's liquidity is at least its pre-collection liquidity

#### Scenario: Repeated collection is harmless

- **WHEN** fee collection is triggered repeatedly in quick succession with little or no fee accrual between calls
- **THEN** each call completes at bounded cost, the position is unchanged in net terms, and no caller gains at the protocol's or the LP's expense

#### Scenario: Collection with zero accrual is a no-op

- **WHEN** fee collection is triggered with no accrued fees
- **THEN** nothing is routed and the call does not revert

#### Scenario: Ladder band fees are collected at harvest

- **WHEN** a ladder band that accrued fees while in range is harvested
- **THEN** those fees are collected with the band and folded into the harvest rather than routed through this waterfall

### Requirement: Anti-snipe dynamic fee decay

Where a launch configures a non-zero anti-snipe window, the pool fee SHALL start at 99% and decay in block-sized steps to 1% across that window. The window SHALL be one of 0 seconds, 60 seconds, 10 minutes, or 98 minutes, defaulting to 60 seconds.

#### Scenario: Fee starts at the maximum

- **WHEN** the first swap occurs immediately after a launch with a non-zero anti-snipe window
- **THEN** the fee charged is 99%

#### Scenario: Fee decays monotonically across the window

- **WHEN** successive swaps occur at increasing block numbers within the anti-snipe window
- **THEN** each swap's fee is less than or equal to the previous swap's fee

#### Scenario: Fee reaches the floor at the end of the window

- **WHEN** a swap occurs at or after the end of the anti-snipe window
- **THEN** the fee charged is the base fee rather than a decayed anti-snipe value

#### Scenario: A zero window disables anti-snipe

- **WHEN** a launch configures a zero-second anti-snipe window
- **THEN** the first and all subsequent swaps are charged the base fee

#### Scenario: Decay does not depend on swap activity

- **WHEN** no swaps occur for part of the anti-snipe window
- **THEN** the fee for the next swap reflects elapsed blocks, not the number of swaps that occurred

### Requirement: Milestone-completion fee schedule

A launch MAY enable a step-down base fee schedule keyed to cumulative milestone completions. The schedule SHALL start at at most 1.5%, SHALL floor at at least 0.25%, and SHALL contain at most 2 steps. The schedule SHALL default to disabled. Each step SHALL be applied at the harvest that reaches its completion threshold.

#### Scenario: Base fee steps down at the completion threshold

- **WHEN** cumulative milestone completions reach a configured step threshold
- **THEN** the base fee becomes that step's value from that harvest onward

#### Scenario: Base fee is unchanged between thresholds

- **WHEN** a milestone completes at a count that is not a configured step threshold
- **THEN** the base fee is unchanged

#### Scenario: Fee never falls below the configured floor

- **WHEN** all configured steps have been applied
- **THEN** the base fee equals the schedule's final value, which is at or above 0.25%, and no further reduction occurs

#### Scenario: Disabled schedule leaves the base fee constant

- **WHEN** milestones complete on a launch that did not enable the schedule
- **THEN** the base fee remains at its default for the life of the pool

#### Scenario: Step-downs do not reverse

- **WHEN** the price falls back after a step-down, or bands are reclaimed
- **THEN** the base fee does not increase back to a previous value

### Requirement: Fee schedule precedence

The anti-snipe decay SHALL take precedence over the milestone fee schedule while the anti-snipe window is open. Milestone steps SHALL apply to the base fee only, and SHALL take effect on the charged fee once the anti-snipe window has elapsed.

#### Scenario: Anti-snipe overrides during its window

- **WHEN** a milestone completes and steps the base fee down while the anti-snipe window is still open
- **THEN** swaps in that window are still charged the decaying anti-snipe fee, not the stepped base fee

#### Scenario: Stepped base fee applies after the window

- **WHEN** the anti-snipe window has elapsed after a milestone step was applied
- **THEN** swaps are charged the stepped base fee

#### Scenario: Anti-snipe decays toward the current base fee

- **WHEN** the anti-snipe window elapses
- **THEN** the charged fee converges on the current base fee, including any milestone steps already applied

### Requirement: Milestone-fund diversion of token-denominated fees

The system SHALL divert a configurable share, at most 20% and defaulting to 20%, of token-denominated collected fees away from LP compounding and into accrued inventory for the next ladder band. Quote-denominated fees SHALL NOT be diverted.

#### Scenario: Sell-side fees fund the next band

- **WHEN** token-denominated fees are collected while ladder capacity remains
- **THEN** the configured share is credited as milestone-fund inventory for the next band, and the remainder flows through the standard waterfall

#### Scenario: Quote-denominated fees are never diverted

- **WHEN** quote-denominated fees are collected
- **THEN** the full amount flows through the standard waterfall with no diversion

#### Scenario: Diversion never exceeds the cap

- **WHEN** a launch configures a milestone-fund share above 20%
- **THEN** the launch reverts

#### Scenario: Diversion requires no swap

- **WHEN** milestone-fund inventory accrues
- **THEN** it accrues from token-denominated fees already held, with no swap performed and no price impact

#### Scenario: Diversion stops when the ladder is capped out

- **WHEN** token-denominated fees are collected after 30 fee-funded bands have been created
- **THEN** no diversion occurs and the full amount flows through the standard waterfall
