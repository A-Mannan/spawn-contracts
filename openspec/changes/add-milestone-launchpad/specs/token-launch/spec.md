## Purpose

Defines the permissionless entry point that turns a creator-signed launch configuration into a live token, lifecycle hook, and Uniswap v4 pool — deployable by any relayer, with the creator identified by signature — including the optional creator dev buy and its vesting.

## ADDED Requirements

### Requirement: Signed-config launch with permissionless relay

The creator SHALL sign the launch configuration off-chain (EIP-712 over the configuration hash, including a deadline), and any address SHALL be able to relay `launch(configuration, signature)` without allowlisting, approval, or privileged roles. A creator MAY instead launch directly with their own transaction, in which case no signature is required. In both cases the launch creator SHALL be the recovered signer or the transacting creator respectively, never the relayer. The signature SHALL cover the entire configuration, so a relayer cannot alter any economic parameter. Each launch SHALL produce exactly one token and one pool against the protocol's single deployed hook. v1 serves creators with wallets; custodial signing on behalf of keyless creators is deferred and, when added, MUST NOT require a privileged on-chain approver.

#### Scenario: A relayer can launch on the creator's behalf

- **WHEN** any address submits a creator-signed configuration that satisfies the protocol's per-launch rules, before the signature's deadline
- **THEN** the launch succeeds, the token and pool are created, and the recovered signer — not the relayer — is recorded as the launch creator

#### Scenario: A creator can launch directly without a signature

- **WHEN** a creator submits their own configuration in their own transaction without a signature
- **THEN** the launch succeeds, the sender is recorded as the launch creator, and the token address is identical to the address derived from that creator's signature over the same configuration

#### Scenario: A relayer cannot alter the configuration

- **WHEN** a relayer modifies any field of a signed configuration
- **THEN** the signature no longer verifies and the launch reverts

#### Scenario: Replay is rejected

- **WHEN** a signature that has already funded a launch is submitted again, or a second launch is attempted with the same configuration hash
- **THEN** the launch reverts; the token address is derived from the configuration hash and its recovered signer via CREATE2, so replay collides with the existing deployment

#### Scenario: An expired signature is rejected

- **WHEN** a launch is relayed after the signature's deadline
- **THEN** the launch reverts

#### Scenario: Launch identity is unique per pool

- **WHEN** two launches complete
- **THEN** each has a distinct pool identifier, and no state of one launch is readable or mutable from the other

### Requirement: Per-launch configuration

Every launch-shape parameter SHALL be fixed by the immutable protocol template and SHALL NOT be configurable per launch. The per-launch configuration SHALL consist of the token's metadata and total supply, the optional dev buy (at most 10% of total supply, with vesting between 0 and 12 months), and the harvest split components summing to one whole with the creator share at most 70%, the buyback share at least 10%, and the protocol share at least 5%.

#### Scenario: Geometry is not configurable

- **WHEN** a launch configuration supplies any band or curve geometry field (counts, spacing, widths, shares of supply beyond the dev buy)
- **THEN** no such field exists in the configuration; the launch uses the template values, and a creator cannot produce a degenerate ladder

#### Scenario: Creator share cap is enforced

- **WHEN** a launch configuration sets the creator harvest share above 70%, or the buyback harvest share below 10%
- **THEN** the launch reverts

#### Scenario: Harvest split that does not sum to one whole is rejected

- **WHEN** a launch configuration provides creator, buyback, protocol, and LP harvest shares that do not sum to exactly one whole unit
- **THEN** the launch reverts

#### Scenario: Valid configuration at bound edges is accepted

- **WHEN** a launch configuration sits exactly on every permitted bound (for example, creator share 70%, protocol share 5%)
- **THEN** the launch succeeds

### Requirement: Token deployment and supply allocation

The system SHALL deploy a standard ERC20 token per launch via CREATE2 with a salt derived from the configuration hash and its recovered signer, so the token address is knowable before launch, and mint its entire supply to the hook at launch. No supply SHALL be minted to the creator, the relayer, or any other address at launch, and the token SHALL expose no post-launch minting capability.

#### Scenario: Full supply is held by the hook

- **WHEN** a launch completes
- **THEN** the hook's token balance equals the total supply, and the creator's token balance is zero

#### Scenario: Token address is knowable before launch

- **WHEN** an observer recovers the signer from a signed configuration and hashes the configuration with that signer
- **THEN** the address the token will deploy to is derivable before the launch transaction exists

#### Scenario: A different signer cannot occupy the advertised address

- **WHEN** an address other than the creator signs an identical configuration and relays it first
- **THEN** that launch deploys a separate token at a different address with the relaying signer as creator, and the address derived from the creator's signature is unaffected and remains derivable for the creator's launch

#### Scenario: A re-signed configuration lands at the same address

- **WHEN** the creator re-signs an identical configuration after its deadline with a fresh deadline
- **THEN** the derived token address is identical to the address derived from the original signature

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

The pool SHALL be initialized at the level derived from the launch's total supply and the protocol's anchored opening FDV, at the fixed template fee tier base, and SHALL use a dynamic fee so that milestone fee step-downs can act on it. The launch transaction SHALL leave the pool tradable: the first curve position is minted within it.

#### Scenario: Starting price matches the anchored opening FDV

- **WHEN** a launch completes
- **THEN** the pool's initial level is the level at which the launch's total supply is valued at the protocol's anchored opening FDV

#### Scenario: Pool uses a dynamic fee

- **WHEN** a launch completes
- **THEN** the pool is configured for dynamic fees rather than a static fee tier

### Requirement: Optional creator dev buy

A launch MAY include a creator dev buy, executable only when the launch transaction is sent by the creator themselves (the recovered signer); a relayed launch SHALL NOT execute a dev buy, and the dev-buy share remains bonding curve inventory. When present, the dev buy SHALL execute during launch against the bonding curve on the same terms as any other buyer, consuming bonding curve inventory and moving the price accordingly. The dev buy SHALL NOT grant any free or discounted allocation, and SHALL NOT exceed 10% of total supply.

#### Scenario: Dev buy consumes bonding curve inventory

- **WHEN** a creator-sent launch includes a dev buy
- **THEN** the purchased tokens come from bonding curve inventory, the public bonding curve's remaining inventory is reduced by the purchased amount, and the resulting price is the price any buyer of that size would have paid

#### Scenario: Dev buy is capped at 10% of supply

- **WHEN** a launch configuration requests a dev buy exceeding 10% of total supply
- **THEN** the launch reverts

#### Scenario: Dev buy requires the creator's own transaction

- **WHEN** a relayed launch's configuration includes a dev buy
- **THEN** no dev buy executes and the dev-buy share remains bonding curve inventory

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
