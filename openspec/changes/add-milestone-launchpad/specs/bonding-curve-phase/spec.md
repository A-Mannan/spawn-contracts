## Purpose

Defines pre-graduation price discovery: a set of hook-owned multicurve liquidity positions minted once at launch, which buyers fill as demand arrives and which remain tradeable in both directions indefinitely.

## ADDED Requirements

### Requirement: Multicurve position minting at initialization

The system SHALL mint the configured curve set as real pool liquidity when the pool is initialized. Each curve SHALL specify a lower tick, an upper tick, a position count, and a share of ladder-external bonding curve inventory, and the shares across all curves SHALL sum to one whole unit. Positions SHALL be distributed across each curve as a fan spanning from that curve's starting tick to the shared far tick.

#### Scenario: Curves are minted as pool liquidity at launch

- **WHEN** a pool is initialized
- **THEN** the configured curve positions exist as pool liquidity owned by the hook, and their combined token amount equals the bonding curve supply share

#### Scenario: Curve shares must sum to one whole

- **WHEN** a launch configuration provides curve shares that do not sum to exactly one whole unit
- **THEN** the launch reverts

#### Scenario: Every curve terminates at the shared far tick

- **WHEN** the curve set is minted
- **THEN** each curve's positions span from its own starting tick to the common far tick

#### Scenario: Phased pricing across curves

- **WHEN** a launch configures multiple curves with different starting ticks and shares
- **THEN** the resulting inventory distribution is denser at lower prices for curves configured with earlier starting ticks, producing a rising average fill price as buying continues

### Requirement: Bonding curve liquidity is static

The system SHALL NOT rebalance, re-price, expire, or otherwise modify bonding curve positions after they are minted. There SHALL be no epochs, no time decay, and no fixed duration.

#### Scenario: No rebalancing occurs over time

- **WHEN** an arbitrary amount of time passes during the bonding curve phase with no trading
- **THEN** curve positions are unchanged in ticks, liquidity, and count

#### Scenario: No caller can reprice curves

- **WHEN** any address, including the creator or the protocol, attempts to move, resize, or replace curve positions during the bonding curve phase
- **THEN** the attempt reverts

#### Scenario: Price advances only through trading

- **WHEN** buyers fill curve inventory
- **THEN** the pool price rises as a direct consequence of the swaps, not through any scheduled or externally triggered adjustment

### Requirement: Hook-exclusive liquidity

All pool liquidity SHALL be owned by the hook. The system SHALL reject any liquidity addition or removal whose initiator is not the hook itself, in every phase.

#### Scenario: External liquidity addition is rejected

- **WHEN** an external address attempts to add liquidity to the pool
- **THEN** the attempt reverts

#### Scenario: External liquidity removal is rejected

- **WHEN** an external address attempts to remove liquidity from the pool
- **THEN** the attempt reverts

#### Scenario: Hook-initiated liquidity operations succeed

- **WHEN** the hook mints or burns its own positions as part of the lifecycle
- **THEN** the operation succeeds

#### Scenario: No just-in-time LP exposure during fundraising

- **WHEN** an external party attempts to sandwich a swap by adding and removing liquidity around it
- **THEN** both liquidity operations revert and the sandwich is impossible

### Requirement: Unrestricted two-way trading

The system SHALL permit swaps in both directions at every price during the bonding curve phase. The hook SHALL NOT revert a swap for size, direction, timing, or caller identity.

#### Scenario: Buyers can always buy

- **WHEN** a buyer swaps into the token during the bonding curve phase at any price below the far tick
- **THEN** the swap succeeds

#### Scenario: Sellers can always sell

- **WHEN** a holder swaps out of the token during the bonding curve phase
- **THEN** the swap succeeds against the curve liquidity, and the holder receives proceeds at the prevailing price

#### Scenario: No caller is privileged or blocked

- **WHEN** two different addresses submit identical swaps under identical pool conditions
- **THEN** both receive the same treatment, with no address-specific gating

### Requirement: Indefinite bonding curve for tokens that never graduate

A pool whose price never reaches the far tick SHALL remain tradeable on its curve liquidity indefinitely. The system SHALL NOT expire, cancel, refund, or force-close such a launch in this version.

#### Scenario: Trading continues long after launch

- **WHEN** a pool has remained below the far tick for an arbitrarily long period
- **THEN** swaps in both directions still succeed against the curve liquidity

#### Scenario: Holders are never trapped

- **WHEN** a holder of a token that has not graduated wishes to exit
- **THEN** a sell swap succeeds against curve liquidity at the prevailing price

#### Scenario: No refund or cancellation path exists

- **WHEN** any address attempts to cancel a launch or reclaim bonding curve proceeds before graduation
- **THEN** the attempt reverts
