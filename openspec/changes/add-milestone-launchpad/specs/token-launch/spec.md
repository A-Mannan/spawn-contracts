## Purpose

Defines the permissionless entry point that turns a validated launch configuration into a live token, lifecycle hook, and Uniswap v4 pool, including the optional creator dev buy and its vesting.

## ADDED Requirements

### Requirement: Permissionless launch

The system SHALL allow any address to launch a new token without allowlisting, approval, or privileged roles. Each launch SHALL produce exactly one token, one hook, and one pool.

#### Scenario: Any caller can launch

- **WHEN** an arbitrary address submits a launch configuration that satisfies all protocol bounds
- **THEN** the launch succeeds, and a token, hook, and initialized pool are created

#### Scenario: Launch identity is unique per pool

- **WHEN** two launches complete
- **THEN** each has a distinct pool identifier, and no state of one launch is readable or mutable from the other

### Requirement: Launch configuration bounds validation

The system SHALL reject any launch configuration that violates the protocol bounds. The validated bounds are: band count between 3 and 15 inclusive; band spacing corresponding to at least a 1.5x market-cap step; band width a validated fraction of the band gap; ladder supply share at most 65% of total supply with any single band at most 15%; dev buy at most 20% of total supply and strictly less than the bonding curve supply share; dev buy vesting between 0 and 12 months; milestone fee schedule starting at at most 1.5%, flooring at at least 0.25%, with at most 2 steps; harvest split components summing to one whole with protocol share at least 5% and buyback share at most 40%; milestone-fund share at most 20%; anti-snipe window one of 0 seconds, 60 seconds, 10 minutes, or 98 minutes; bonding curve LP-seed share at least 20%.

#### Scenario: Out-of-range band count is rejected

- **WHEN** a launch configuration specifies a band count below 3 or above 15
- **THEN** the launch reverts and no token, hook, or pool is created

#### Scenario: Band spacing below the floor is rejected

- **WHEN** a launch configuration specifies a band tick spacing smaller than a 1.5x market-cap step
- **THEN** the launch reverts

#### Scenario: Oversized ladder supply is rejected

- **WHEN** a launch configuration allocates more than 65% of total supply to the ladder, or allocates more than 15% of total supply to any single band
- **THEN** the launch reverts

#### Scenario: Harvest split that does not sum to one whole is rejected

- **WHEN** a launch configuration provides creator, buyback, protocol, and LP harvest shares that do not sum to exactly one whole unit
- **THEN** the launch reverts

#### Scenario: Harvest split violating component bounds is rejected

- **WHEN** a launch configuration sets the protocol harvest share below 5%, or the buyback harvest share above 40%
- **THEN** the launch reverts

#### Scenario: Invalid anti-snipe window is rejected

- **WHEN** a launch configuration specifies an anti-snipe window that is not one of the four permitted values
- **THEN** the launch reverts

#### Scenario: Milestone fee schedule outside bounds is rejected

- **WHEN** a launch configuration enables the milestone fee schedule with a starting fee above 1.5%, a floor below 0.25%, or more than 2 steps
- **THEN** the launch reverts

#### Scenario: Bonding curve LP-seed share below the floor is rejected

- **WHEN** a launch configuration sets the bonding curve LP-seed share below 20%
- **THEN** the launch reverts

#### Scenario: Valid configuration at bound edges is accepted

- **WHEN** a launch configuration sits exactly on every permitted bound (for example, band count 3, ladder supply 65%, protocol harvest share 5%)
- **THEN** the launch succeeds

### Requirement: Token deployment and supply allocation

The system SHALL deploy a standard ERC20 token per launch and mint its entire supply to the hook at launch. No supply SHALL be minted to the creator, the factory, or any other address at launch, and the token SHALL expose no post-launch minting capability.

#### Scenario: Full supply is held by the hook

- **WHEN** a launch completes
- **THEN** the hook's token balance equals the total supply, and the creator's token balance is zero

#### Scenario: Supply is fixed after launch

- **WHEN** any address attempts to mint additional tokens after launch
- **THEN** the attempt reverts, and total supply is unchanged

#### Scenario: Token behaves as a standard ERC20

- **WHEN** a holder transfers, approves, or queries balances on a launched token
- **THEN** the token behaves per the ERC20 standard with no transfer restrictions, blocklists, or transfer taxes

### Requirement: Hook address encodes required permissions

The hook address SHALL encode exactly the callback permissions the lifecycle requires: before-initialize, after-initialize, before-swap, after-swap, before-add-liquidity, before-remove-liquidity, and the dynamic-fee flag.

#### Scenario: Deployed hook address carries the required flags

- **WHEN** a launch completes
- **THEN** the deployed hook address encodes each required permission flag, and the pool accepts it at initialization

#### Scenario: Pool initialization is restricted to the launch path

- **WHEN** an external party attempts to initialize a pool against an already-deployed launch hook
- **THEN** the initialization reverts

### Requirement: Pool initialization

The pool SHALL be initialized at the lowest configured curve boundary and SHALL use a dynamic fee so that anti-snipe and milestone fee schedules can act on it.

#### Scenario: Starting price matches the lowest curve boundary

- **WHEN** a launch completes
- **THEN** the pool's initial tick equals the lowest boundary of the configured curve set

#### Scenario: Pool uses a dynamic fee

- **WHEN** a launch completes
- **THEN** the pool is configured for dynamic fees rather than a static fee tier

### Requirement: Optional dev buy

A launch MAY include a creator dev buy. When present, the dev buy SHALL execute during launch against the bonding curve on the same terms as any other buyer, consuming bonding curve inventory and moving the price accordingly. The dev buy SHALL NOT grant any free or discounted allocation.

#### Scenario: Dev buy consumes bonding curve inventory

- **WHEN** a launch includes a dev buy
- **THEN** the purchased tokens come from bonding curve inventory, the public bonding curve's remaining inventory is reduced by the purchased amount, and the resulting price is the price any buyer of that size would have paid

#### Scenario: Dev buy is capped below the bonding curve share

- **WHEN** a launch configuration requests a dev buy exceeding 20% of total supply or greater than or equal to the bonding curve supply share
- **THEN** the launch reverts

#### Scenario: No dev buy is the default

- **WHEN** a launch configuration omits a dev buy
- **THEN** the launch completes with no tokens purchased by the creator and the full bonding curve inventory available

#### Scenario: Dev buy is observable on chain

- **WHEN** a launch with a dev buy completes
- **THEN** the purchased amount and the consideration paid are emitted in launch events

### Requirement: Dev buy vesting

When a launch configures vesting for its dev buy, the purchased tokens SHALL be held by the hook and released to the creator linearly over the configured duration, which SHALL be between 0 and 12 months.

#### Scenario: Vested tokens are held by the hook

- **WHEN** a launch completes with a dev buy and a non-zero vesting duration
- **THEN** the purchased tokens remain in hook custody and the creator's token balance is zero

#### Scenario: Linear release over the vesting period

- **WHEN** the creator claims vested tokens partway through the vesting duration
- **THEN** the amount released equals the purchased amount scaled by elapsed time over total duration, less anything already released

#### Scenario: Full release after the vesting period

- **WHEN** the creator claims after the vesting duration has elapsed
- **THEN** the entire purchased amount has been released and further claims transfer nothing

#### Scenario: Zero vesting releases immediately

- **WHEN** a launch configures a dev buy with zero vesting duration
- **THEN** the purchased tokens are transferred to the creator during the launch

#### Scenario: Only the creator can claim vested tokens

- **WHEN** an address other than the launch creator attempts to claim vested tokens
- **THEN** the claim reverts
