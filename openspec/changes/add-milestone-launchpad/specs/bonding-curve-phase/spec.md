## Purpose

Defines pre-graduation price discovery: a fixed, hook-owned set of nested liquidity positions derived from the protocol template — the first minted at genesis, the rest deployed just before the price reaches them — which buyers fill as demand arrives and which remain tradeable in both directions indefinitely.

## ADDED Requirements

### Requirement: The nested curve template

The bonding curve SHALL be a fixed set of nested single-sided token positions derived from the immutable protocol template: 32 positions spanning the 2× opening-to-far-level range, where position i spans from the opening level plus i·span/32 to the far level, each holding an equal share of the bonding curve supply, so liquidity staircases upward and concentrates toward the far level. The opening level SHALL be derived from the launch's total supply and the protocol's anchored opening FDV, so every launch opens at the same ETH-denominated market capitalization. Only the first position SHALL be minted at genesis; the remaining positions SHALL be minted before the price reaches them, per the simulation-driven deployment requirement.

#### Scenario: Genesis mints only the first curve position

- **WHEN** a launch completes
- **THEN** only position 0 exists as pool liquidity, spanning from the opening level to the far level and holding its equal share of the curve supply, and the pool is tradable

#### Scenario: Later curve positions deploy as price approaches

- **WHEN** a buy's simulated path would reach an undeployed curve position's start level
- **THEN** that position is minted before the price arrives, exactly as band deployment works after graduation

#### Scenario: Positions form a nested staircase

- **WHEN** any set of curve positions is deployed
- **THEN** each spans from its own start level to the shared far level holding an equal token amount, so the active liquidity is thinnest at the opening level and densest near the far level

#### Scenario: The opening price is derived from the FDV anchor

- **WHEN** a launch is configured with any total supply
- **THEN** the pool's opening level is the level at which that supply is valued at the protocol's anchored opening FDV

#### Scenario: Every launch opens at the same valuation

- **WHEN** two launches with different total supplies are compared
- **THEN** both pools open at the same ETH-denominated FDV

### Requirement: Bonding curve liquidity is static in shape

Deployed bonding curve positions SHALL NOT be rebalanced, re-priced, expired, or otherwise modified after they are minted. There SHALL be no epochs, no time decay, and no fixed duration. The only liquidity change during the phase is the protocol's own deployment of not-yet-deployed template positions ahead of the price.

#### Scenario: No rebalancing occurs over time

- **WHEN** an arbitrary amount of time passes during the bonding curve phase with no trading
- **THEN** deployed curve positions are unchanged in ticks, liquidity, and count

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
