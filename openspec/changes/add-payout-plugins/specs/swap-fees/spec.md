## MODIFIED Requirements

### Requirement: Default swap fee
Every pool SHALL charge the immutable template trading fee of 1% from initialization for its entire lifetime. Time, price, phase, milestone completion, fee collection, and administrative economic updates SHALL NOT change the trading fee. The pool SHALL use no dynamic-fee flag or mutable per-pool fee state.

#### Scenario: One percent applies from genesis forever
- **WHEN** swaps occur before or after any lifecycle event
- **THEN** each is charged the static 1% trading fee

#### Scenario: Time does not affect the fee
- **WHEN** equivalent swaps occur at different times
- **THEN** time since launch causes no fee difference

#### Scenario: Milestones do not affect the fee
- **WHEN** any number of milestones completes
- **THEN** the trading fee remains 1%

#### Scenario: Governance cannot change the trading fee
- **WHEN** the administrator updates configurable economic distributions
- **THEN** the pool's trading fee remains 1%

#### Scenario: Pool has no dynamic fee state
- **WHEN** a pool is inspected after initialization
- **THEN** its key has no dynamic-fee flag and no mutable fee step exists

### Requirement: Fee routing waterfall
Collected fees SHALL be routed per currency using one snapshot of the active global economic configuration. By default, quote fees SHALL route 75% to direct creator revenue and the exact remainder, initially 25%, to the global protocol ledger. The administrator MAY update the creator percentage after the configured timelock, subject to an immutable maximum of 90%; the protocol receives the exact remainder and updates SHALL apply to future collections for all pools. Token fees SHALL never reach a claimant, payout pot, payout plugin, or full-range position: while useful ladder capacity remains, the configured milestone-fund share, initially 20% and capped at 50%, SHALL fund future bands and the exact remainder SHALL burn; once no future permitted band can use inventory, 100% SHALL burn. No quote- or token-side LP fee carry SHALL exist and no collected fee SHALL compound liquidity.

#### Scenario: Default quote split is 75 25
- **WHEN** quote fees are collected under the default configuration
- **THEN** 75% credits direct creator revenue and the exact remainder credits global protocol revenue

#### Scenario: Active quote distribution applies globally
- **WHEN** a valid queued quote-creator update executes
- **THEN** subsequent collections on every pool use the new creator percentage and protocol remainder

#### Scenario: Collection uses one configuration snapshot
- **WHEN** a fee collection routes both currencies
- **THEN** one configuration version governs all routing within that operation

#### Scenario: Token fees never credit a claimant or pot
- **WHEN** token fees are collected
- **THEN** creator revenue, protocol revenue, payout pots, and plugin ledgers receive none of those tokens

#### Scenario: Collected fees never compound
- **WHEN** quote or token fees are collected after graduation
- **THEN** no amount enters the full-range position or any LP carry

#### Scenario: Routed amounts conserve each currency
- **WHEN** fees are collected
- **THEN** creator and protocol quote credits equal collected quote, while milestone funding and burn equal collected token

#### Scenario: No fee LP carry exists
- **WHEN** any collection completes
- **THEN** no quote or token balance is classified for future full-range compounding

### Requirement: Permissionless fee collection
Any address SHALL be able to collect accrued full-range fees. Collection SHALL apply one active configuration snapshot, preserve the locked position's net liquidity, and bound per-call work. Token-fee custody, milestone funding, and burning SHALL occur only on this cold path. The collector SHALL not choose destinations or retain collected value.

#### Scenario: Any address can collect
- **WHEN** an arbitrary caller triggers collection
- **THEN** accrued fees are routed under the active global configuration

#### Scenario: Net locked position is preserved
- **WHEN** collection completes
- **THEN** the full-range position's liquidity is not reduced

#### Scenario: Repeated collection is harmless
- **WHEN** collection is called repeatedly with little or no new accrual
- **THEN** work remains bounded and no caller gains protocol value

#### Scenario: Zero-accrual collection is a no-op
- **WHEN** no fees have accrued
- **THEN** nothing is routed, burned, or emitted and the call does not revert

#### Scenario: Ladder fees remain part of harvest
- **WHEN** a ladder band is harvested
- **THEN** its fees are included in gross harvest rather than this waterfall

#### Scenario: Token burning is cold-path only
- **WHEN** swaps execute without a fee-collection call
- **THEN** no token-fee burn occurs inside swap callbacks

#### Scenario: Collector cannot redirect value
- **WHEN** a third party collects fees
- **THEN** the active global distribution alone determines all destinations

### Requirement: Milestone-fund diversion of token-denominated fees
While another permitted band can use inventory, the system SHALL divert the active globally configured share of token fees to milestone inventory without performing a swap and SHALL burn the exact remainder. The default diverted share SHALL be 20%, and the immutable maximum SHALL be 50%. Quote fees SHALL never be diverted. When no future band is permitted or useful, diversion SHALL be zero and all collected token fees SHALL burn. Executed updates SHALL affect future collections for every pool without changing already routed value.

#### Scenario: Default token routing funds 20 and burns 80
- **WHEN** token fees are collected under defaults while useful ladder capacity remains
- **THEN** 20% funds milestone inventory and the remainder burns

#### Scenario: Active token distribution applies globally
- **WHEN** a valid queued token-fund update executes
- **THEN** future collections on every pool use the new share

#### Scenario: Quote fees are never diverted
- **WHEN** quote fees are collected
- **THEN** no quote amount enters milestone inventory

#### Scenario: Diversion causes no price impact
- **WHEN** token fees fund the ladder
- **THEN** already held tokens are reclassified without a swap

#### Scenario: Diversion stops at the cap
- **WHEN** no future permitted band can use inventory
- **THEN** no token fee enters milestone funding

#### Scenario: Post-cap token fees burn entirely
- **WHEN** token fees are collected after the ladder cap
- **THEN** 100% of them burn regardless of the configured pre-cap share

## ADDED Requirements

### Requirement: Governed global economic configuration
The protocol SHALL maintain one active, versioned economic configuration containing milestone service-fee, quote creator, and token milestone-fund percentages. Defaults SHALL be 10%, 75%, and 20%. Protocol quote share and token burn share SHALL be exact remainders. Only the configurable protocol administrator SHALL queue or cancel updates, and executed updates SHALL affect future harvests and fee collections for every existing and future pool. Immutable validation SHALL enforce service fee at most 20%, quote creator at most 90%, and token milestone funding at most 50%. Trading fee, graduation split, and all post-graduation LP compounding SHALL remain outside this configuration.

#### Scenario: Default global configuration is published
- **WHEN** the protocol is deployed
- **THEN** defaults are 10% harvest service fee, 75 25 quote routing, and 20 80 pre-cap token routing

#### Scenario: Valid update affects every pool prospectively
- **WHEN** a queued economic update executes
- **THEN** every pool uses it for later operations without repartitioning prior accruals

#### Scenario: Service-fee cap is enforced
- **WHEN** an update proposes more than 20% harvest service fee
- **THEN** it is rejected

#### Scenario: Quote creator cap is enforced
- **WHEN** an update proposes more than 90% creator share
- **THEN** it is rejected and the protocol remainder cannot fall below 10%

#### Scenario: Token-fund cap is enforced
- **WHEN** an update proposes more than 50% pre-cap milestone funding
- **THEN** it is rejected

#### Scenario: Exact cap values are accepted
- **WHEN** every updated value sits exactly at its immutable bound
- **THEN** the update can execute after its delay

#### Scenario: Prior accrual is not repartitioned
- **WHEN** configuration changes after a pot or claimable balance has accrued
- **THEN** that recorded value remains unchanged

#### Scenario: Uncollected fees use collection-time configuration
- **WHEN** swap fees accrue before an update but are collected afterward
- **THEN** the configuration active at collection governs their routing

#### Scenario: Trading fee remains immutable
- **WHEN** any economic configuration update executes
- **THEN** all pool trading fees remain 1%

## REMOVED Requirements

### Requirement: Milestone-completion fee schedule
**Reason**: Trading fees are static at 1% for the pool lifetime; milestone-driven dynamic fee steps and their flag are removed.

**Migration**: Delete fee-step state, events, update calls, and threshold tests; replace them with static-fee tests across arbitrary milestone counts and governance updates.
