## Purpose

Defines how accrued value leaves the protocol: a transferable NFT that represents a launch's creator revenue stream, and the pull-based claim paths through which the NFT holder and the protocol withdraw what they have accrued.

## ADDED Requirements

### Requirement: Transferable creator revenue NFT

Each launch SHALL mint exactly one non-fungible token representing the creator's revenue stream, identified by the launch's pool, issued to the launch creator, and freely transferable under the ERC721 standard.

#### Scenario: NFT is minted to the creator at launch

- **WHEN** a launch completes
- **THEN** exactly one revenue NFT exists for that pool and its owner is the launch creator

#### Scenario: NFT identity maps to the pool

- **WHEN** an observer holds a pool identifier
- **THEN** they can derive that pool's revenue NFT identifier, and the mapping is one-to-one

#### Scenario: NFT is freely transferable

- **WHEN** the holder transfers or sells the revenue NFT
- **THEN** the transfer succeeds under standard ERC721 semantics with no protocol-imposed restriction, lockup, or approval requirement

#### Scenario: No second NFT is issued for a pool

- **WHEN** any address attempts to mint an additional revenue NFT for an existing pool
- **THEN** the attempt reverts

### Requirement: Creator accruals are credited to the NFT

The creator's share of milestone harvests, swap fees, and bonding curve proceeds SHALL be credited to a claimable balance associated with the revenue NFT rather than transferred at accrual time.

#### Scenario: Harvest creator share accrues

- **WHEN** a milestone is harvested
- **THEN** the creator share is added to the NFT's claimable balance and no transfer occurs during settlement

#### Scenario: Fee creator share accrues

- **WHEN** swap fees are collected
- **THEN** the creator share is added to the NFT's claimable balance

#### Scenario: Bonding curve proceeds creator share accrues

- **WHEN** graduation completes
- **THEN** the creator share of bonding curve proceeds is added to the NFT's claimable balance

#### Scenario: Accruals from all sources aggregate

- **WHEN** a pool has accrued creator value from graduation, fee collection, and multiple harvests without any claim
- **THEN** the NFT's claimable balance equals the sum of all those accruals

### Requirement: Pull-based claiming by the current holder

Claiming SHALL be initiated by the caller, and only the current owner of the revenue NFT SHALL be able to claim its balance. A claim SHALL transfer the full claimable balance to the holder and reset it to zero. The protocol SHALL NOT push accrued value to any recipient.

#### Scenario: Current holder claims successfully

- **WHEN** the current owner of a revenue NFT triggers a claim on a non-zero balance
- **THEN** the balance is transferred to them and the claimable balance becomes zero

#### Scenario: Non-holder claim is rejected

- **WHEN** an address that does not own the revenue NFT triggers a claim for it
- **THEN** the call reverts and the balance is unchanged

#### Scenario: Claiming an empty balance transfers nothing

- **WHEN** the holder triggers a claim on a zero balance
- **THEN** nothing is transferred and the call does not revert

#### Scenario: A claim cannot exceed the accrued balance

- **WHEN** a claim is triggered
- **THEN** the transferred amount equals exactly the recorded claimable balance at that moment, and repeated or reentrant claims in the same transaction transfer nothing further

#### Scenario: Accrual after a claim is claimable again

- **WHEN** new creator value accrues after a claim
- **THEN** the holder can claim the newly accrued amount

### Requirement: Transfer carries the unclaimed balance

Transferring the revenue NFT SHALL transfer entitlement to both future accruals and any unclaimed accrued balance. The system SHALL NOT settle the outgoing holder's balance on transfer.

#### Scenario: New holder can claim the pre-transfer balance

- **WHEN** a revenue NFT with an unclaimed balance is transferred
- **THEN** the new holder can claim that balance and the previous holder cannot

#### Scenario: New holder receives future accruals

- **WHEN** value accrues after a transfer
- **THEN** it is credited to the same NFT balance and is claimable by the new holder

#### Scenario: Previous holder loses claim rights immediately

- **WHEN** the previous holder triggers a claim after transferring the NFT
- **THEN** the call reverts

### Requirement: Protocol claimable balance

The protocol's share of milestone harvests, swap fees, and bonding curve proceeds SHALL be credited to a protocol claimable balance and withdrawable only by the protocol's designated recipient, on a pull basis, per pool.

#### Scenario: Protocol shares accrue from every source

- **WHEN** graduation completes, fees are collected, or a milestone is harvested
- **THEN** the corresponding protocol share is added to the protocol's claimable balance

#### Scenario: Designated recipient claims successfully

- **WHEN** the protocol's designated recipient triggers a claim on a non-zero protocol balance
- **THEN** the balance is transferred to them and the claimable balance becomes zero

#### Scenario: Unauthorised protocol claim is rejected

- **WHEN** any address other than the designated recipient triggers a protocol claim
- **THEN** the call reverts

#### Scenario: Protocol balances are isolated per pool

- **WHEN** protocol value has accrued on two different pools
- **THEN** claiming one pool's protocol balance leaves the other pool's balance unchanged

### Requirement: Claim paths cannot drain unaccrued value

Claim paths SHALL only ever transfer value recorded as accrued to the claimant. No claim SHALL be able to withdraw ladder inventory, full-range liquidity, another pool's balances, or another party's claimable balance.

#### Scenario: Claims cannot reach ladder inventory

- **WHEN** a holder or the protocol recipient claims
- **THEN** undeployed ladder inventory and deployed band positions are unaffected

#### Scenario: Claims cannot reach the full-range position

- **WHEN** a holder or the protocol recipient claims
- **THEN** the full-range position's liquidity is unchanged

#### Scenario: Claims are isolated between creator and protocol

- **WHEN** the creator claims their balance
- **THEN** the protocol's claimable balance for that pool is unchanged, and the converse holds

#### Scenario: Claims are isolated across pools

- **WHEN** the holder of one pool's revenue NFT claims
- **THEN** no other pool's creator or protocol balance is reduced
