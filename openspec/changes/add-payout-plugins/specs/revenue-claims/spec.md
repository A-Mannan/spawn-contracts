## MODIFIED Requirements

### Requirement: Creator accruals are credited to the NFT
Only the creator's share of quote-denominated swap fees and bonding-curve proceeds SHALL be credited to the hook's direct per-pool creator ledger. Milestone proceeds SHALL enter the payout pot and the separate creator-path entitlement ledger instead. All creator entitlements SHALL be quote-denominated and SHALL follow current RevenueNFT ownership; token-denominated fees SHALL never accrue to a claimant.

#### Scenario: Fee creator share accrues directly
- **WHEN** quote-denominated swap fees are collected
- **THEN** the active creator share is added to the pool's direct creator ledger

#### Scenario: Bonding curve creator share accrues directly
- **WHEN** graduation completes
- **THEN** the creator share of bonding-curve proceeds is added to the direct creator ledger

#### Scenario: Token fees never accrue to a claimant
- **WHEN** token-denominated fees are collected
- **THEN** neither creator nor protocol claimable revenue increases from those tokens

#### Scenario: Direct creator sources aggregate
- **WHEN** swap-fee and bonding-curve creator revenue accrues without a claim
- **THEN** the direct creator ledger equals the sum of those sources

#### Scenario: Milestone harvest does not credit direct creator revenue
- **WHEN** a milestone is harvested or its pot is flushed
- **THEN** no milestone value is added to the hook's direct creator ledger

#### Scenario: Plugin-pot proceeds remain separate
- **WHEN** creator remainder is assigned to the creator path
- **THEN** it is accounted in the creator path's per-pool entitlement ledger

### Requirement: Pull-based claiming by the current holder
Only the current RevenueNFT owner SHALL be able to claim the hook's direct per-pool creator balance. A claim SHALL transfer the full recorded direct balance and reset it before transfer. It SHALL NOT flush a payout pot, claim a creator-path balance, or depend on plugin availability.

#### Scenario: Current holder claims direct revenue
- **WHEN** the current holder claims a non-zero direct balance
- **THEN** exactly that balance is transferred and reset to zero

#### Scenario: Non-holder direct claim is rejected
- **WHEN** a non-holder attempts a direct creator claim
- **THEN** the call reverts and all balances remain unchanged

#### Scenario: Empty direct claim is harmless
- **WHEN** the holder claims a zero direct balance
- **THEN** nothing is transferred and the call does not revert

#### Scenario: Reentrant claim cannot exceed the ledger
- **WHEN** a recipient attempts to reenter during transfer
- **THEN** no value beyond the pre-call direct balance can be transferred

#### Scenario: New direct accrual remains claimable
- **WHEN** direct creator revenue accrues after a claim
- **THEN** the current holder can claim the new amount

#### Scenario: Direct claim does not flush
- **WHEN** the holder claims direct revenue while a payout pot exists
- **THEN** the pot and all plugin carry remain unchanged

#### Scenario: Plugin failure cannot block a direct claim
- **WHEN** every selected payout plugin is failing
- **THEN** the current holder can still claim direct creator revenue

### Requirement: Transfer carries the unclaimed balance
Transferring the RevenueNFT SHALL transfer entitlement to future direct accruals, the complete unclaimed direct balance, and any unpaid creator-path entitlement. Transfer SHALL NOT settle the outgoing holder, flush a pot, or invoke a plugin.

#### Scenario: New holder claims pre-transfer direct revenue
- **WHEN** an NFT with a non-zero direct balance is transferred
- **THEN** only the new holder can claim that balance

#### Scenario: New holder receives future direct accruals
- **WHEN** direct creator value accrues after transfer
- **THEN** it is claimable by the new holder

#### Scenario: New holder receives unpaid creator-path value
- **WHEN** creator-path value remains unpaid at transfer
- **THEN** only the new holder can claim it

#### Scenario: Previous holder loses all creator claim rights
- **WHEN** the previous holder attempts either creator claim after transfer
- **THEN** the attempt is rejected

#### Scenario: Transfer performs no settlement
- **WHEN** the RevenueNFT is transferred
- **THEN** no payout pot, direct balance, or creator-path balance is paid or flushed

### Requirement: Protocol claimable balance
All quote-denominated protocol revenue SHALL accrue to one global pool-agnostic ledger, including milestone service fees, quote-fee protocol shares, and graduation protocol proceeds. Only the current configurable protocol recipient SHALL be able to pull the full global balance. The protocol administrator SHALL have no claim authority unless it is also the configured recipient. Accrual events SHALL retain pool, source, amount, and active configuration version attribution. No per-pool protocol claim path SHALL exist.

#### Scenario: Every protocol source accrues globally
- **WHEN** graduation, quote-fee collection, or milestone harvest creates protocol revenue
- **THEN** the amount increases the single global protocol ledger

#### Scenario: Multiple pools aggregate
- **WHEN** protocol revenue accrues from different pools
- **THEN** one global balance contains their sum while events preserve source pools

#### Scenario: Current recipient claims globally
- **WHEN** the configured recipient claims a non-zero balance
- **THEN** the entire global balance is transferred and reset before transfer

#### Scenario: Unauthorized protocol claim is rejected
- **WHEN** any address other than the current recipient attempts a claim
- **THEN** the call reverts

#### Scenario: Administrator has no implicit claim right
- **WHEN** the administrator differs from the revenue recipient
- **THEN** administrator authority alone cannot claim protocol revenue

#### Scenario: Recipient update transfers unclaimed entitlement
- **WHEN** a queued recipient update executes while global revenue is unclaimed
- **THEN** only the new recipient can claim the complete existing balance

#### Scenario: No per-pool protocol claim exists
- **WHEN** protocol revenue has multiple source pools
- **THEN** callers cannot withdraw only one pool's protocol balance through a pool-scoped claim

### Requirement: Claim paths cannot drain unaccrued value
Creator and protocol claim paths SHALL transfer only their recorded ledgers. They SHALL NOT consume another party's ledger, another pool's creator revenue, payout pots, plugin carry, flusher tips, ladder inventory, burn inventory, pending locked-LP quote, or locked liquidity.

#### Scenario: Claims cannot reach ladder inventory
- **WHEN** any creator or protocol claim executes
- **THEN** undeployed inventory and deployed bands remain unchanged

#### Scenario: Claims cannot reach locked liquidity
- **WHEN** any claim executes
- **THEN** the full-range position remains unchanged

#### Scenario: Direct creator and protocol claims are isolated
- **WHEN** either ledger is claimed
- **THEN** the other ledger is unchanged

#### Scenario: Creator claims are isolated across pools
- **WHEN** one pool's holder claims
- **THEN** every other pool's creator balances are unchanged

#### Scenario: Claims cannot reach pot or carry reserves
- **WHEN** direct or global claimable balances coexist with payout pots or failed carry
- **THEN** claims leave all pot and carry value fully backed

#### Scenario: Protocol claim cannot consume creator value
- **WHEN** the global protocol recipient claims
- **THEN** no direct or creator-path entitlement is reduced

## ADDED Requirements

### Requirement: Direct creator revenue is independent of payout flushing
Direct creator revenue SHALL remain claimable without a payout flush and regardless of plugin status. Flushing or retrying a plugin SHALL NOT alter the direct creator ledger.

#### Scenario: Direct revenue is claimable while a pot is unflushed
- **WHEN** the current holder claims direct revenue while milestone value remains in the pot
- **THEN** the direct claim succeeds and the pot remains unchanged

#### Scenario: Flush leaves direct creator revenue unchanged
- **WHEN** any caller flushes the pool
- **THEN** the direct creator balance is unchanged

#### Scenario: Failed delivery leaves direct revenue unchanged
- **WHEN** a plugin delivery fails into carry
- **THEN** direct creator revenue remains fully claimable
