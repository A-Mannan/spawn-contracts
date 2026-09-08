## Purpose

Define immutable launch-selected payout destinations and permissionless cold settlement without allowing plugin failures, governance updates, or custody interactions to block swaps or drain unrelated protocol value.

## ADDED Requirements

### Requirement: Append-only payout-plugin registry
The protocol SHALL reference one registry whose plugin indices, addresses, fixed takes, gas limits, and roles remain stable after registration. The registry SHALL contain at most 256 entries, SHALL reject duplicate or invalid registrations, and SHALL permit mutations only through the typed ProtocolController. Immediately before any registry-only mutation, the controller SHALL query the hook's protocol-global payout-delivery guard and SHALL revert while delivery is in flight. Suspension SHALL be reversible without changing the entry's index or terms. New launches SHALL NOT select a suspended entry; an existing plan's current share and carry for a suspended entry SHALL route to the creator sink until reactivation. Runtime codehash mismatch SHALL permanently redirect that attempt's current share plus all carry to the creator path without calling the entry; restoring code or appending a replacement SHALL NOT replay redirected value. Reactivation SHALL restore the immutable destination for later allocations but SHALL NOT recover value already redirected.

#### Scenario: Registration appends at a stable index
- **WHEN** the administrator registers a valid plugin
- **THEN** it is appended at the next index and every earlier index remains unchanged

#### Scenario: Registered terms cannot change
- **WHEN** a registry entry exists
- **THEN** its address, fixed take, gas limit, role, and index cannot be edited, removed, or reordered

#### Scenario: Registry is bounded to one word
- **WHEN** the administrator attempts to register a 257th entry
- **THEN** registration is rejected

#### Scenario: Unauthorized registry mutation is rejected
- **WHEN** an address other than the administrator attempts registration or suspension
- **THEN** the operation is rejected

#### Scenario: Suspension preserves identity
- **WHEN** the administrator suspends and later reactivates an entry
- **THEN** its stable index and immutable terms are unchanged

#### Scenario: Suspended value redirects to the creator
- **WHEN** an enabled entry is suspended with a current share or failed carry
- **THEN** that value is assigned to the creator sink and other plan destinations remain unaffected

#### Scenario: Reactivation affects later allocations only
- **WHEN** a suspended entry is reactivated after value was redirected
- **THEN** later plan allocations use the entry again and prior redirection is not reversed

#### Scenario: Registry mutation is blocked during payout delivery
- **WHEN** a typed registry operation executes while the hook-global payout guard is held
- **THEN** the controller's execution reverts before the registry changes

#### Scenario: Codehash mismatch permanently redirects value
- **WHEN** an enabled entry's live codehash differs while it has a current share or carry
- **THEN** the entry is not called, its complete attempted amount credits the creator path, its carry clears, and later code restoration cannot replay that amount

### Requirement: Protocol administration and delayed updates
The protocol SHALL maintain a configurable administrator distinct from the configurable protocol revenue recipient. Only the administrator SHALL control registry registration and suspension, economic configuration, revenue-recipient updates, and governance-delay updates. Administrator transfer SHALL use a two-step propose-and-accept process in which only the pending administrator can accept. Administrative configuration changes SHALL be typed, scheduled, cancellable before execution, and executable only after the active delay. The initial delay SHALL be zero seconds and MAY later change through the same delayed mechanism; already scheduled operations SHALL retain their original readiness. The protocol SHALL support a multisig as administrator without assuming signer policy on chain. The administrator SHALL have no implicit right to claim protocol revenue.

#### Scenario: Administrator and recipient are independent
- **WHEN** distinct addresses are configured
- **THEN** administrative authority does not grant claim authority and recipient status does not grant governance authority

#### Scenario: Administrator transfer requires acceptance
- **WHEN** the administrator proposes a non-zero successor
- **THEN** authority changes only after that exact pending address accepts

#### Scenario: Unauthorized acceptance is rejected
- **WHEN** an address other than the pending administrator attempts acceptance
- **THEN** the operation reverts and current authority remains unchanged

#### Scenario: Zero-delay update can execute immediately
- **WHEN** an authorized operation is scheduled while delay is zero
- **THEN** it may execute in the same transaction or multisig batch after scheduling

#### Scenario: Positive delay is enforced
- **WHEN** the delay has been increased and an operation is executed before readiness
- **THEN** execution is rejected

#### Scenario: Delay update uses the old delay
- **WHEN** the administrator schedules a new delay
- **THEN** that update cannot execute earlier than the delay active at scheduling

#### Scenario: Queued readiness does not change retroactively
- **WHEN** the governance delay changes after an operation was scheduled
- **THEN** the operation retains its original ready time

#### Scenario: Scheduled operation can be cancelled
- **WHEN** the administrator cancels a pending operation before execution
- **THEN** that operation can no longer execute

#### Scenario: Operation identity binds complete parameters
- **WHEN** any scheduled parameter, action type, controller identity, chain, or salt differs at execution
- **THEN** it does not match the queued operation

### Requirement: Immutable signed bitset payout plans
Each launch SHALL store the exact signed 256-bit payout plan. A set bit SHALL select the plugin at that stable registry index; a zero bit SHALL not select it. At launch, every selected entry SHALL exist, be active, have a selectable payout role, and the fixed takes SHALL total at most one whole. A launch SHALL enable at most eight payout plugins. The creator sink SHALL be implicit and always active, and SHALL receive all post-tip distributable value not allocated to selected active plugins, including fixed-point dust. The plan SHALL have no mutable percentages or on-chain preset name and SHALL never change after launch.

#### Scenario: Set bits select stable registry indices
- **WHEN** a valid plan is launched
- **THEN** each set bit selects exactly the entry at that index

#### Scenario: Invalid plan bits are rejected
- **WHEN** a plan selects an unregistered, suspended, or non-payout entry
- **THEN** launch is rejected

#### Scenario: Excessive fixed takes are rejected
- **WHEN** selected fixed takes total more than one whole
- **THEN** launch is rejected

#### Scenario: Enabled plugin count is bounded
- **WHEN** a plan contains more than eight selectable set bits
- **THEN** launch is rejected

#### Scenario: Empty plan pays the creator
- **WHEN** a launch selects no payout plugin
- **THEN** the creator sink receives the entire post-tip distributable amount

#### Scenario: Creator receives allocation dust
- **WHEN** fixed-point division leaves an unallocated remainder
- **THEN** the remainder is assigned to the creator sink

#### Scenario: Plan cannot change after launch
- **WHEN** a pool has launched
- **THEN** no caller can update its payout-plan bits

#### Scenario: Registry growth cannot reinterpret a plan
- **WHEN** entries are appended after a pool launches
- **THEN** every existing set bit retains its original meaning

#### Scenario: Preset names are off chain
- **WHEN** two off-chain preset names resolve to identical bits
- **THEN** they produce identical on-chain plan data

### Requirement: Isolated harvest payout pots and attribution
Each pool SHALL have an isolated payout pot containing net milestone proceeds not yet allocated by a flush. A harvest SHALL record pool, milestone index, and gross quote amount; deduct the active global service-fee percentage into the global protocol ledger; and credit the exact remainder to only that pool's pot. Multiple milestones MAY aggregate in one pot while their event history remains reconstructible. The hook SHALL maintain exact aggregate counters for payout pots, plugin carry, creator-path entitlement, direct creator claims, and global protocol claims, updated atomically with their component ledgers. Outside active payout-pot redemption, aggregate pots SHALL be covered by redeemable quote claims, while carry plus creator-path plus direct creator plus protocol liabilities SHALL be covered by raw ETH; combined raw ETH and claims SHALL cover their sum. The protocol SHALL NOT maintain an on-chain per-milestone tranche ledger.

#### Scenario: Gross harvest is attributable
- **WHEN** a band is harvested
- **THEN** an event records its pool, milestone index, and gross quote amount before deductions

#### Scenario: Service fee precedes pot funding
- **WHEN** gross harvest proceeds are accounted
- **THEN** the active service fee enters the global protocol ledger and the exact remainder enters the source pool's pot

#### Scenario: Pots are isolated across pools
- **WHEN** multiple pools accrue and flush milestone proceeds
- **THEN** no pool can consume another pool's pot

#### Scenario: Multiple milestones aggregate without losing history
- **WHEN** several milestones fund one pot before a flush
- **THEN** the pot aggregates their net value and events preserve each milestone's attribution

#### Scenario: Mid-swap pot accrual remains solvent
- **WHEN** a harvest accrues while PoolManager settlement is in flight
- **THEN** its pot is backed by claims without requiring premature ETH redemption

#### Scenario: Aggregate liabilities equal component ledgers
- **WHEN** harvest, flush, failure, redirect, or claim changes any payout liability
- **THEN** each aggregate counter equals the sum of its recorded component ledgers

#### Scenario: Custody classes cover their liabilities
- **WHEN** no payout-pot redemption unlock is active
- **THEN** redeemable quote claims cover aggregate pots, raw ETH covers all carry and claimable ledgers, and combined custody covers total ETH liabilities

### Requirement: Permissionless whole-pot cold flush
Any address SHALL be able to flush one pool. A flush SHALL remove the complete newly accrued pot from available accounting before external calls, redeem it exactly once in its own PoolManager unlock, and perform delivery outside all swap callbacks. The flusher tip SHALL equal the floor of 1% of the newly redeemed post-service-fee pot. An ordinary flush SHALL transfer that tip before plugin delivery and failure of that transfer SHALL revert the complete flush atomically. Plan takes SHALL apply to the remaining 99%. Previously failed carry SHALL be retried without another tip. The protocol SHALL expose no multi-pool batch-flush entry point.

#### Scenario: Any address can flush one pool
- **WHEN** an arbitrary caller requests a flush for a valid pool
- **THEN** the protocol processes that pool without requiring creator or administrator authorization

#### Scenario: Whole new pot is redeemed once
- **WHEN** a pool has newly accrued pot value
- **THEN** one cold unlock redeems the complete new pot and the pot is zeroed before delivery

#### Scenario: Flusher receives one percent of the net new pot
- **WHEN** a new pot is flushed
- **THEN** the immediate flusher receives floor(new pot times 1%) and plan allocations use the remainder

#### Scenario: Protocol service fee is never tipped
- **WHEN** a gross harvest is later flushed
- **THEN** the tip excludes the service fee already credited to the protocol

#### Scenario: Carry is not tipped twice
- **WHEN** a previous failed share is retried
- **THEN** no new tip is deducted from that carry

#### Scenario: Carry-only flush remains available
- **WHEN** no new pot exists but failed carry exists
- **THEN** a caller can retry delivery with a zero tip

#### Scenario: Empty flush is a no-op
- **WHEN** neither new pot nor carry exists
- **THEN** the call performs no unlock or value transfer

#### Scenario: Ordinary flusher tip failure is atomic
- **WHEN** an ordinary flush cannot transfer the 1% tip to its immediate caller
- **THEN** the complete flush reverts with pot, carry, liabilities, plugin state, events, and transfers unchanged

#### Scenario: Ordinary swaps do not flush
- **WHEN** a trader uses an ordinary router
- **THEN** no pot is redeemed and no payout plugin is invoked

### Requirement: Stipended and failure-isolated plugin delivery
A flush SHALL process selected destinations in ascending registry-index order. Each active plugin SHALL receive plain ETH equal only to its current computed share plus its own previous carry, under its registered gas limit. Plugin success SHALL be exactly the EVM `CALL` success bit for the void callback `onPayout(PoolId,address)`; the core SHALL ignore all returndata. A zero success bit from revert or gas exhaustion SHALL preserve the full attempted value in a per-pool, per-entry carry ledger and SHALL NOT block later destinations. The published constants SHALL be `CALL_FIXED_GAS = 15_000`, `POST_CALL_GAS = 100_000`, `FINALIZE_GAS = 100_000`, and `MAX_PLUGIN_CALL_GAS = 500_000`, and registration SHALL require `1 <= callGas <= MAX_PLUGIN_CALL_GAS`. At each actual call boundary, `remainingCalls` SHALL include the current call and every unresolved later selected entry. After suspension/codehash resolution, zero-attempt filtering, carry clearing, liability effects, and callback calldata materialization, but before any uncovered call-specific setup, the core SHALL compute `reserve = remainingCalls * POST_CALL_GAS + FINALIZE_GAS` and `eip150Margin = (callGas + 62) / 63`, then require `gasleft() >= reserve + callGas + eip150Margin + CALL_FIXED_GAS`. Failed preflight SHALL revert the complete flush rather than become carry. Successful delivery SHALL clear carry and SHALL NOT be replayable. Delivery events SHALL make successful, carried, and redirected values reconcilable.

#### Scenario: Plugins execute deterministically
- **WHEN** multiple plugins are enabled
- **THEN** delivery attempts occur in ascending registry-index order

#### Scenario: Plugin receives only its allocation
- **WHEN** an active plugin is called
- **THEN** it receives plain ETH equal to its current share plus its own carry and cannot consume another share

#### Scenario: Void callback success ignores returndata
- **WHEN** a plugin's void callback returns with EVM CALL success and any empty, malformed, or non-empty returndata
- **THEN** delivery succeeds, all returndata is ignored, and the attempted amount does not become carry

#### Scenario: EIP-150 preflight preserves finalization gas
- **WHEN** a plugin attempt reaches the call boundary
- **THEN** the exact formula using `15_000` fixed gas, `100_000` per unresolved call, `100_000` finalization gas, and `(callGas + 62) / 63` EIP-150 margin passes before CALL

#### Scenario: Insufficient preflight gas reverts the flush
- **WHEN** gas at a plugin call boundary is below the published preflight formula
- **THEN** the whole flush reverts and no attempted amount is misclassified as plugin carry

#### Scenario: Reverting plugin does not block later plugins
- **WHEN** one plugin reverts
- **THEN** its full attempted amount becomes carry and every later destination is still attempted

#### Scenario: Gas-exhausting plugin is isolated
- **WHEN** a plugin consumes its registered gas allowance
- **THEN** its call fails into carry without exhausting the outer flush gas bound

#### Scenario: Failed carry is retried
- **WHEN** a later flush encounters carry for an active plugin
- **THEN** that carry is added to the plugin's attempted delivery without a second tip

#### Scenario: Successful delivery is not replayed
- **WHEN** a plugin accepts its attempted amount
- **THEN** its carry is cleared and the same value cannot be delivered again

#### Scenario: Flush accounting conserves value
- **WHEN** a flush completes
- **THEN** tip, successful deliveries, creator value, redirects, and remaining carry equal all new pot and retried carry value

### Requirement: Creator payout entitlement
The implicit mandatory creator sink SHALL receive every post-tip amount not allocated to active selected plugins, including rounding dust, suspended-plugin redirects, and codehash-mismatch redirects. The creator path SHALL credit a separate per-pool entitlement ledger without pushing ETH to the holder during an arbitrary flush. Entitlement SHALL belong to the current RevenueNFT owner and SHALL remain distinct from the hook's direct creator-revenue ledger. A creator-path claim SHALL authenticate the initiating owner, flush first, query RevenueNFT ownership again after every plugin interaction, and revert the complete call if ownership changed. It SHALL then attempt the complete entitlement including its self-flush tip. Failure of this final transfer SHALL NOT revert: the complete attempted amount SHALL be restored to creator-path entitlement and aggregate liability, an event SHALL identify pool, holder, attempted amount, and failure, and the call SHALL return explicit `(success, attemptedAmount)` observability.

#### Scenario: Arbitrary flush records rather than pushes creator value
- **WHEN** a third party flushes a pool
- **THEN** the creator sink credits the pool ledger without transferring ETH to the NFT holder

#### Scenario: Creator value follows NFT ownership
- **WHEN** the RevenueNFT is transferred before creator-path value is claimed
- **THEN** the new holder gains the complete unpaid entitlement and the previous holder loses it

#### Scenario: Creator-path and direct ledgers remain separate
- **WHEN** a flush credits creator remainder
- **THEN** the hook's direct creator ledger is unchanged

#### Scenario: Creator payout flushes first
- **WHEN** the current NFT holder invokes creator-path payout
- **THEN** the creator path first flushes the pool and then attempts the complete resulting entitlement

#### Scenario: Creator self-flush preserves the tip
- **WHEN** the NFT holder initiates creator payout
- **THEN** the 1% tip is included in that initiating holder's complete final transfer

#### Scenario: Ownership change during plugins reverts payout
- **WHEN** RevenueNFT ownership differs after plugin interactions from the owner authenticated at creator-payout entry
- **THEN** the complete flush and payout revert before any creator-path transfer

#### Scenario: Failed recipient transfer preserves entitlement
- **WHEN** the complete creator-path transfer to the current holder fails
- **THEN** the call does not revert, the attempted amount including any self-flush tip is restored in full, and return data and an event report failure and attempted amount

### Requirement: Plugin reentrancy and drain protection
Payout accounting SHALL follow checks-effects-interactions and use transaction-scoped reentrancy control. During plugin delivery, no plugin SHALL re-flush any pool, replay settlement, mutate a different pool, or reach direct creator revenue, global protocol revenue, another pool's pot, another plugin's carry, ladder inventory, or locked liquidity. Pool callbacks caused by an authorized reference plugin interaction SHALL suppress payout and ladder work. A failed nested interaction SHALL leave accounting recoverable, and the guard SHALL not persist across transactions.

#### Scenario: Same-pool reentry is rejected
- **WHEN** a plugin attempts to flush its active pool recursively
- **THEN** the nested operation is rejected without corrupting the outer settlement

#### Scenario: Cross-pool reentry is rejected
- **WHEN** a plugin attempts payout or protocol activity against another pool
- **THEN** the nested operation fails into that plugin's carry

#### Scenario: Unrelated value is unreachable
- **WHEN** a plugin executes
- **THEN** it cannot consume direct or protocol ledgers, other pots or carries, ladder inventory, or locked liquidity

#### Scenario: Nested callbacks suppress protocol work
- **WHEN** a plugin's PoolManager interaction invokes hook callbacks
- **THEN** no ladder deployment, harvest, graduation, fee collection, or payout work begins

#### Scenario: Guard clears after the transaction
- **WHEN** a guarded transaction completes or reverts
- **THEN** a later independent transaction can use the protected entry points

### Requirement: Reference buyback-and-burn plugin
The protocol-authored buyback plugin SHALL accept only hook-authenticated payouts, use only its delivered ETH to buy the source pool's launch token through its own cold PoolManager interaction, and burn every acquired token. If the atomic purchase and burn cannot complete under its immutable execution bounds, the callback SHALL fail so the hook carries the entire attempted share.

#### Scenario: Buyback spends only delivered ETH
- **WHEN** the buyback plugin receives a payout
- **THEN** it cannot spend another pool's funds or unrelated balances

#### Scenario: Buyback burns acquired tokens
- **WHEN** the buyback succeeds
- **THEN** every acquired launch token is burned and total supply falls accordingly

#### Scenario: Failed buyback carries the entire share
- **WHEN** the bounded purchase or burn cannot complete atomically
- **THEN** the plugin call fails and the hook records the full attempted amount as carry

#### Scenario: Zero delivery performs no swap
- **WHEN** the plugin has neither a current share nor carry
- **THEN** it is not invoked

### Requirement: Opt-in same-transaction swap-and-flush helper
A protocol-authored utility helper SHALL allow a caller to opt into performing a swap and then a cold flush in one transaction. The swap SHALL fully settle before the separate flush unlock begins. The helper SHALL not be a selectable payout destination, SHALL not choose or alter payout destinations, and SHALL forward the flush tip and swap outputs or refunds to the initiating caller. Ordinary routers SHALL remain unchanged.

#### Scenario: Opted-in caller swaps then flushes
- **WHEN** a caller uses the helper
- **THEN** the swap settles before the helper invokes a flush for that pool

#### Scenario: Helper uses a separate flush unlock
- **WHEN** the helper composes both operations
- **THEN** pot redemption occurs in an unlock distinct from swap settlement

#### Scenario: Helper cannot alter routing
- **WHEN** the helper flushes a pool
- **THEN** the pool's immutable plan alone determines payout destinations

#### Scenario: Helper forwards the tip
- **WHEN** the helper is the immediate flush caller
- **THEN** it forwards the received tip to the initiating external caller

#### Scenario: Plugin failure does not undo the settled swap
- **WHEN** a payout plugin fails during the helper's flush
- **THEN** the plugin share carries and the completed swap remains successful

### Requirement: Canonical default plan and off-chain presets
The deployment SHALL publish one canonical default bitset that enables the registered buyback plugin with a fixed take of 2/9 of the post-tip distributable amount. The creator SHALL remain the implicit mandatory sink and receive the exact remainder, nominally 7/9 plus fixed-point dust. With the default 10% service fee, this preserves the former 2:1 buyback-to-LP plugin allocation by redirecting the removed LP destination into the creator remainder. Named presets SHALL remain off-chain aliases only; signatures, CREATE2 identity, and storage SHALL bind the bitset rather than a preset name.

#### Scenario: Canonical bits select intended destinations
- **WHEN** fixtures or frontends use the canonical default
- **THEN** its bits select the published buyback entry and no utility or creator-system entry

#### Scenario: Canonical economics match their declared baseline
- **WHEN** the default service fee and canonical plan process a pot
- **THEN** service fee, tip, creator remainder, and buyback share match the published post-tip baseline

#### Scenario: Preset naming cannot change identity
- **WHEN** an off-chain preset is renamed without changing bits
- **THEN** the signed plan and predicted token address remain unchanged

#### Scenario: Preset bit changes alter identity
- **WHEN** a preset resolves to different plan bits
- **THEN** the signed plan and predicted token address change
