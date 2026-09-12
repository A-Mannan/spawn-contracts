## MODIFIED Requirements

### Requirement: Bonding curve proceeds split
Graduation SHALL retain the immutable 20% locked-LP seed, 70% direct creator, and 10% protocol split. The protocol share SHALL enter the single global protocol ledger with source-pool attribution; the creator share SHALL enter the pool's direct RevenueNFT ledger. Administrative economic updates SHALL NOT change this graduation split. Unbought curve token inventory and curve token fees SHALL return to ladder inventory.

#### Scenario: Default split is applied
- **WHEN** graduation completes
- **THEN** 20% seeds locked liquidity, 70% credits direct creator revenue, and 10% credits the global protocol ledger

#### Scenario: Protocol graduation revenue accrues globally
- **WHEN** any pool graduates
- **THEN** its protocol share increases the pool-agnostic protocol balance and emits source-pool attribution

#### Scenario: Economic updates do not alter graduation split
- **WHEN** the administrator changes service-fee or swap-fee distributions
- **THEN** future graduations still use 20 70 10

#### Scenario: Curve tokens become ladder inventory
- **WHEN** graduation releases unbought token inventory or token-denominated curve fees
- **THEN** those tokens remain in protocol custody for bands and never become claimant revenue

#### Scenario: Graduation allocations conserve proceeds
- **WHEN** graduation quote proceeds are split
- **THEN** LP seed, direct creator credit, and global protocol credit equal collected quote proceeds up to specified rounding dust

#### Scenario: Creator proceeds are not pushed
- **WHEN** graduation completes
- **THEN** creator quote value is credited for pull claiming rather than transferred

## ADDED Requirements

### Requirement: Post-graduation full-range position remains fixed
Graduation SHALL continue to seed the initial permanently locked full-range position from the immutable launch token allocation and quote seed. After graduation, payout proceeds and collected quote or token fees SHALL NOT add liquidity to that position or create LP carry. Token-fee burning, milestone funding, payout flushing, and direct or global claiming SHALL NOT reduce the existing locked position.

#### Scenario: Graduation seeds both sides from original allocations
- **WHEN** graduation completes
- **THEN** the locked position uses the immutable token allocation and 20% quote seed

#### Scenario: Quote fees do not compound
- **WHEN** quote fees are collected after graduation
- **THEN** they route only between direct creator and global protocol revenue

#### Scenario: Token fees do not compound
- **WHEN** token fees are collected after graduation
- **THEN** they only fund future bands or burn

#### Scenario: Payouts do not compound
- **WHEN** a milestone payout pot is flushed
- **THEN** no payout destination adds liquidity through a protocol-authored LP plugin

#### Scenario: No LP fee carry exists
- **WHEN** any fee collection or payout flush completes
- **THEN** no quote or token amount is retained for later liquidity compounding

#### Scenario: Other routing preserves existing liquidity
- **WHEN** fees burn, fund milestones, accrue claims, or flush to plugins
- **THEN** the initial full-range position remains unchanged and non-withdrawable
