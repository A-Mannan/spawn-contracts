## Purpose

Defines what traders pay to swap and where those fees go: the static base fee with its milestone-completion step-downs, the three-way fee waterfall, the permissionless collection mechanism, and the routing of token-denominated fees into pool-facing destinations (future ladder inventory and LP compounding) rather than to any recipient.

## ADDED Requirements

### Requirement: Default swap fee

The pool's base swap fee SHALL be a fixed 1% set by the protocol template, identical for every launch. There SHALL be no launch-window dynamic fee: the charged fee equals the stored base fee at all times, from the first swap after launch onward.

#### Scenario: The base fee applies from genesis

- **WHEN** the first swap after a launch occurs
- **THEN** the fee charged is 1%, identical to the fee charged at any later point absent milestone step-downs

#### Scenario: The fee does not depend on time since launch

- **WHEN** identical swaps occur immediately after launch and long after launch, with no milestone completions in between
- **THEN** both are charged the same fee

### Requirement: Fee routing waterfall

Collected swap fees SHALL be routed per currency. Quote (ETH)-denominated fees SHALL be routed 60% to the full-range liquidity position, 30% to the creator's claimable balance, and 10% to the protocol's claimable balance. Token-denominated fees SHALL NOT be credited to any recipient: their milestone-fund diversion share (below) goes to next-band inventory, and the remainder compounds into the full-range liquidity position, paired with the quote-side LP share where possible, with any unpairable remainder carried for a later collection.

#### Scenario: Quote fees split three ways on collection

- **WHEN** quote-denominated swap fees are collected
- **THEN** 60% is added to the full-range position, 30% is credited to the creator's claimable balance, and 10% is credited to the protocol's claimable balance

#### Scenario: Token fees are never credited to a recipient

- **WHEN** token-denominated swap fees are collected
- **THEN** no portion is credited to the creator's or the protocol's claimable balance; it is split between next-band inventory and full-range compounding only

#### Scenario: Routed amounts sum to collected fees

- **WHEN** fees are collected
- **THEN** the routed amounts in each currency sum to the collected fees of that currency, up to rounding dust retained by the hook

#### Scenario: The LP share compounds

- **WHEN** the LP share of collected fees is routed
- **THEN** it increases the full-range position's liquidity rather than being credited to any claimable balance

#### Scenario: An unpairable LP token remainder carries forward

- **WHEN** the token side of the LP share cannot be paired with quote at collection time
- **THEN** the remainder is retained in hook custody and is available to the next collection, never discarded and never credited to a recipient

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

### Requirement: Milestone-completion fee schedule

The base fee SHALL step down at cumulative milestone-completion thresholds fixed by the protocol template and scaled to the band count (completions 8 and 16 of the 30-band template). The schedule SHALL floor at 0.25% and SHALL contain at most 2 steps. Each step SHALL be applied at the harvest that reaches its completion threshold, via the pool's dynamic-fee mechanism, and SHALL be permanent.

#### Scenario: Base fee steps down at the completion threshold

- **WHEN** cumulative milestone completions reach a template step threshold
- **THEN** the base fee becomes that step's value from that harvest onward

#### Scenario: Base fee is unchanged between thresholds

- **WHEN** a milestone completes at a count that is not a step threshold
- **THEN** the base fee is unchanged

#### Scenario: Fee never falls below the floor

- **WHEN** all template steps have been applied
- **THEN** the base fee equals the schedule's final value, which is at or above 0.25%, and no further reduction occurs

#### Scenario: Step-downs do not reverse

- **WHEN** the price falls back after a step-down
- **THEN** the base fee does not increase back to a previous value

### Requirement: Milestone-fund diversion of token-denominated fees

The system SHALL divert a template-fixed 20% share of token-denominated collected fees away from LP compounding and into accrued inventory for the next ladder band. Quote-denominated fees SHALL NOT be diverted. No token-denominated fee SHALL be credited to the creator or the protocol.

#### Scenario: Sell-side fees fund the next band

- **WHEN** token-denominated fees are collected while ladder capacity remains
- **THEN** the configured share is credited as milestone-fund inventory for the next band, and the remainder flows through the standard waterfall

#### Scenario: Quote-denominated fees are never diverted

- **WHEN** quote-denominated fees are collected
- **THEN** the full amount flows through the standard waterfall with no diversion

#### Scenario: Diversion never exceeds the cap

- **WHEN** token-denominated fees are collected
- **THEN** the diverted share is exactly the template's 20% of those fees, never more

#### Scenario: Diversion requires no swap

- **WHEN** milestone-fund inventory accrues
- **THEN** it accrues from token-denominated fees already held, with no swap performed and no price impact

#### Scenario: Diversion stops when the ladder is capped out

- **WHEN** token-denominated fees are collected after 30 fee-funded bands have been created
- **THEN** no diversion occurs and the full amount flows through the standard waterfall
