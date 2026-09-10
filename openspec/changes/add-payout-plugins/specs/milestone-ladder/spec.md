## MODIFIED Requirements

### Requirement: Harvest detection and atomic settlement
The system SHALL detect milestone completion in the same transaction as the crossing swap. When the post-swap level is at or above a deployed incomplete band's upper level, the band SHALL be marked complete, its position burned, and its released quote proceeds and fees accounted before the transaction ends. The harvest SHALL record the gross amount, accrue the active global service fee, and fund the pool's payout pot with the exact remainder. It SHALL NOT redeem the pot, transfer ETH, invoke a payout plugin, perform a buyback, or add liquidity. Harvest work SHALL remain capped per swap.

#### Scenario: Crossing the band top completes and accounts for the milestone
- **WHEN** a swap ends at or above a deployed incomplete band's upper level
- **THEN** the band is completed and burned, its gross proceeds are recorded, and service-fee and pot accounting finish atomically

#### Scenario: Partial fill does not complete the milestone
- **WHEN** a swap ends inside a deployed band's range
- **THEN** the band remains incomplete and no service fee or payout-pot value accrues for it

#### Scenario: Band swap fees fold into the gross harvest
- **WHEN** a harvested band has accrued fees
- **THEN** those fees are included in the milestone's recorded gross quote amount

#### Scenario: A sweeping swap accounts for every completed band within the cap
- **WHEN** one swap ends above several deployed band tops within the harvest cap
- **THEN** each band is completed and accounted in ascending order with distinct milestone attribution

#### Scenario: Harvests beyond the cap remain pending
- **WHEN** one swap crosses more deployed bands than the harvest cap
- **THEN** excess bands remain deployed and unharvested until a later eligible swap

#### Scenario: A completed band cannot be accounted again
- **WHEN** a later swap ends above an already completed band
- **THEN** no additional harvest, service fee, or pot credit occurs for that band

#### Scenario: Harvest invokes no payout plugin
- **WHEN** any band is harvested during a swap
- **THEN** neither swap callback invokes a payout plugin or redeems a payout pot

### Requirement: Harvest proceeds routing
For each gross quote harvest, the system SHALL credit the active globally configured service-fee percentage to the single protocol ledger and credit the exact remainder to only the source pool's payout pot. The service fee SHALL default to 10% and SHALL be subject to the immutable governance cap specified by the payout-plugin capability. Harvest SHALL NOT directly credit creator revenue, buy back tokens, or compound liquidity. Token residue SHALL return to carried ladder inventory. Events SHALL preserve the milestone index, gross amount, active configuration version, service fee, and net pot credit.

#### Scenario: Gross harvest is attributed before deductions
- **WHEN** a milestone is harvested
- **THEN** its pool, index, and gross quote amount are observable independently of later payout settlement

#### Scenario: Active service fee is applied
- **WHEN** a milestone is harvested after an economic update executes
- **THEN** that operation uses one snapshot of the active service-fee percentage and configuration version

#### Scenario: Net harvest funds only its source pool
- **WHEN** the service fee is deducted
- **THEN** the exact gross remainder increases only the source pool's payout pot

#### Scenario: Harvest proceeds are quote only
- **WHEN** a band is harvested
- **THEN** routed proceeds are quote currency and any token residue returns to carried inventory

#### Scenario: Harvest accounting conserves the gross amount
- **WHEN** harvest accounting completes
- **THEN** service fee plus net pot credit equals the gross quote amount exactly

#### Scenario: Harvest leaves direct creator revenue unchanged
- **WHEN** a milestone is harvested
- **THEN** the hook's direct creator-revenue ledger is unchanged

#### Scenario: Harvest performs no direct destination work
- **WHEN** a milestone is harvested
- **THEN** no creator payment, buyback, liquidity operation, or plugin delivery occurs

### Requirement: The hook never blocks a swap in the graduated phase
The system SHALL permit swaps in both directions at every price after graduation. Bounded band deployment and harvest accounting MAY occur as swap side effects, but pot redemption and payout delivery SHALL never be implicit swap work. Only a caller that explicitly selects the swap-and-flush helper MAY compose a settled swap with a later cold flush.

#### Scenario: Swaps succeed in both directions
- **WHEN** a trader swaps in either direction after graduation
- **THEN** the swap succeeds subject only to ordinary pool liquidity and price limits

#### Scenario: In-band oscillation cannot prevent completion
- **WHEN** traders move repeatedly through a partially filled band
- **THEN** its state remains consistent and it completes when an eligible swap ends above its top

#### Scenario: Ordinary swaps never flush
- **WHEN** a trader uses an ordinary router
- **THEN** no payout pot is redeemed and no payout plugin is invoked

#### Scenario: Plugin availability cannot block a swap
- **WHEN** any selected payout plugin is reverting, suspended, or out of gas
- **THEN** an ordinary swap and its bounded harvest accounting remain executable

## REMOVED Requirements

### Requirement: Settlement is reentrancy-guarded
**Reason**: Harvest no longer performs nested buyback or liquidity settlement. Payout-specific reentrancy, callback suppression, failure isolation, and recovery are defined by the new `payout-plugins` capability.

**Migration**: Replace harvest-settlement tests with payout-plugin lock, callback-suppression, carry, and drain-protection scenarios.
