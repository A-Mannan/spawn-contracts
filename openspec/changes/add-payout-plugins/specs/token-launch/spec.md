## MODIFIED Requirements

### Requirement: Signed-config launch with permissionless relay
The creator SHALL sign the complete EIP-712 launch configuration, including deadline and exact 256-bit payout plan, and any address SHALL be able to relay it. A creator MAY launch directly without a signature. The recorded creator SHALL be the recovered signer or direct sender, never the relayer. Altering any field or payout-plan bit SHALL invalidate the signature. The configuration SHALL contain no harvest percentages, preset name, dev-buy vesting duration, or active governance-version snapshot. Existing replay and deadline protections SHALL remain.

#### Scenario: Relayer launches for the signer
- **WHEN** any address submits a valid creator-signed configuration before its deadline
- **THEN** one token and pool launch with the signer recorded as creator

#### Scenario: Creator launches directly
- **WHEN** the creator submits the same configuration without a signature
- **THEN** launch succeeds with the same deterministic identity

#### Scenario: Relayer cannot alter any field
- **WHEN** a relayer changes launch metadata, supply, dev-buy share, deadline, or another signed field
- **THEN** signature verification fails

#### Scenario: Relayer cannot alter a plan bit
- **WHEN** a relayer flips any payout-plan bit
- **THEN** signature verification fails

#### Scenario: Replay is rejected
- **WHEN** an identical signed launch is submitted again
- **THEN** deterministic deployment collision or replay protection rejects it

#### Scenario: Expired signature is rejected
- **WHEN** a relayed launch occurs after its signed deadline
- **THEN** launch reverts

#### Scenario: Launch identity is isolated
- **WHEN** distinct launches complete
- **THEN** each pool, token, plan, and accounting state remains isolated

### Requirement: Per-launch configuration
Per-launch configuration SHALL contain token metadata, total supply, optional creator dev-buy share capped at 10%, payout-plan bitset, and deadline. All geometry, the static 1% trading fee, graduation split, and work caps SHALL remain protocol-defined. No launch SHALL configure harvest percentages, vesting duration, economic-governance values, or preset name. Plan validation SHALL enforce registered active payout roles, fixed takes totaling at most one whole, and no more than eight enabled plugins. An empty plan and a plan totaling exactly one whole SHALL be valid.

#### Scenario: Geometry is not configurable
- **WHEN** a launch is constructed
- **THEN** it contains no band, curve, fee, or work-cap override

#### Scenario: Harvest percentages are not configurable
- **WHEN** a creator chooses payout behavior
- **THEN** they can select registry bits but cannot supply destination percentages

#### Scenario: Unknown or suspended plan bit is rejected
- **WHEN** a plan selects a nonexistent or suspended entry
- **THEN** launch reverts

#### Scenario: Enabled takes above one whole are rejected
- **WHEN** selected immutable takes total more than 100%
- **THEN** launch reverts

#### Scenario: More than eight plugins is rejected
- **WHEN** a plan selects nine or more payout entries
- **THEN** launch reverts

#### Scenario: Empty plan is accepted
- **WHEN** no payout bit is set
- **THEN** launch succeeds and the creator is the implicit full remainder destination

#### Scenario: Exact whole plan is accepted
- **WHEN** at most eight selected takes total exactly 100%
- **THEN** launch succeeds

#### Scenario: Preset names are absent
- **WHEN** a preset is used by a frontend
- **THEN** only the resulting bitset enters signed launch data

### Requirement: Token deployment and supply allocation
The system SHALL deploy one standard ERC20 via CREATE2 with a salt derived from the deadline-independent configuration hash and creator identity. The configuration hash SHALL bind the payout-plan bitset, so a different plan yields a different predicted address while re-signing only with a fresh deadline preserves it. The initial supply SHALL be minted to the hook for protocol allocation, except tokens bought by an immediate creator dev buy SHALL be transferred to the creator before launch returns. No post-launch mint capability SHALL exist.

#### Scenario: Protocol initially receives the full minted supply
- **WHEN** token deployment occurs
- **THEN** the hook receives the fixed total supply before genesis allocation and optional dev-buy execution

#### Scenario: Address is predictable
- **WHEN** an observer knows the configuration and creator
- **THEN** they can derive the token address before launch

#### Scenario: Different signer cannot occupy the address
- **WHEN** another signer uses otherwise identical data
- **THEN** their token address differs

#### Scenario: Re-signing preserves the address
- **WHEN** only the deadline and signature are refreshed
- **THEN** the predicted token address is unchanged

#### Scenario: Different payout plan changes the address
- **WHEN** any payout-plan bit changes
- **THEN** the predicted token address changes

#### Scenario: Supply is fixed after launch
- **WHEN** any caller attempts additional minting
- **THEN** it is rejected

#### Scenario: Token remains standard ERC20
- **WHEN** holders transfer, approve, or query the token
- **THEN** standard ERC20 behavior applies without transfer restrictions or taxes

### Requirement: Hook address encodes required permissions
The hook address SHALL encode exactly the lifecycle callback permissions required by the launchpad: before-initialize, after-initialize, before-swap, after-swap, before-add-liquidity, and before-remove-liquidity. No dynamic-fee flag SHALL be part of pool configuration or treated as a hook-address permission.

#### Scenario: Deployed hook has required callback flags
- **WHEN** the hook is deployed and a pool initializes
- **THEN** its address contains every required callback permission

#### Scenario: Pool has no dynamic-fee flag
- **WHEN** a launched pool key is inspected
- **THEN** it contains the static template fee without a dynamic flag

#### Scenario: Pool initialization is restricted
- **WHEN** an external party attempts unauthorized initialization against the hook
- **THEN** initialization reverts

### Requirement: Pool initialization
The pool SHALL initialize at the level derived from total supply and the anchored opening FDV, using the immutable static 1% template trading fee without a dynamic-fee flag. The launch transaction SHALL leave the first curve position live and the pool tradable.

#### Scenario: Starting price matches anchored FDV
- **WHEN** launch completes
- **THEN** the initial level values total supply at the anchored opening FDV

#### Scenario: Pool uses static one percent
- **WHEN** the pool key is created
- **THEN** its fee is the static 1% template value

#### Scenario: Pool is tradable at launch
- **WHEN** launch returns
- **THEN** the first curve position exists and swaps can execute

### Requirement: Optional creator dev buy
A creator-direct launch MAY execute a dev buy against the bonding curve on ordinary buyer terms, capped at 10% of total supply. Every purchased token SHALL transfer to the creator before launch returns. A relayed launch SHALL execute no dev buy and SHALL leave that share as curve inventory. The launch configuration and pool state SHALL contain no vesting duration, schedule, releasable balance, or release entry point.

#### Scenario: Dev buy consumes curve inventory
- **WHEN** a creator-direct launch includes a dev buy
- **THEN** it purchases from curve inventory and moves price on ordinary terms

#### Scenario: Dev buy is capped at ten percent
- **WHEN** the requested share exceeds 10% of supply
- **THEN** launch reverts

#### Scenario: Dev buy requires creator transaction
- **WHEN** a relayer submits a configuration with a non-zero dev-buy share
- **THEN** no dev buy executes and the share remains curve inventory

#### Scenario: No dev buy is the default
- **WHEN** dev-buy share is zero
- **THEN** no creator purchase occurs

#### Scenario: Dev buy is observable
- **WHEN** a dev buy executes
- **THEN** events record tokens acquired, quote spent, and creator recipient

#### Scenario: Tokens are delivered fully at launch
- **WHEN** a creator dev buy succeeds
- **THEN** all purchased tokens are in the creator's balance before launch returns

#### Scenario: No vesting state is created
- **WHEN** any launch completes
- **THEN** no dev-buy tokens remain reserved for later release

## REMOVED Requirements

### Requirement: Dev buy vesting
**Reason**: Creator dev-buy tokens are delivered fully during launch; vesting configuration, custody, math, views, and release actions are removed.

**Migration**: Remove vesting fields and release interfaces from signed data, storage, fixtures, deployment scripts, tests, events, and documentation.
