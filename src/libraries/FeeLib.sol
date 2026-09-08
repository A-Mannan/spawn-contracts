// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title FeeLib
/// @notice The milestone step-down schedule that moves a pool's stored base fee.
///
/// @dev design Decision 8, as revised by Decision 20. The launch-window anti-snipe decay and its
/// `beforeSwap` override are gone: with the nested just-in-time curve (Decision 17) the cheap supply a
/// decay wall protected is structurally scarce, and a wall that re-arms at genesis would make
/// deployment timing matter again — defeating the lazy-relay launch model's "timing is inert" property.
///
/// What survives is the half of Decision 8 whose trigger is a completion rather than a clock: the pool
/// charges its stored base fee at all times, and a harvest that reaches a template threshold steps that
/// base fee down permanently via `updateDynamicLPFee`. `DYNAMIC_FEE_FLAG` is retained solely for this.
/// There is no override and no precedence rule anymore.
library FeeLib {
    /// @notice The base fee implied by the template's schedule at a given completion count.
    ///
    /// @dev Evaluated from the count rather than accumulated step by step, so the fee is a pure function
    /// of how many milestones a pool has completed. That is what makes "step-downs do not reverse"
    /// structural rather than defended: the count only ever rises, and a price that falls back changes
    /// nothing. The `< fee` guards add the same property arithmetically, so a template whose steps rose
    /// would be ignored rather than obeyed.
    ///
    /// A zero threshold disables that step, which is how a template can ship one step or none.
    function steppedBaseFee(
        uint24 baseFee,
        uint8 stepOneAtCompletions,
        uint24 stepOneFee,
        uint8 stepTwoAtCompletions,
        uint24 stepTwoFee,
        uint32 completions
    ) internal pure returns (uint24 fee) {
        fee = baseFee;

        if (stepOneAtCompletions != 0 && completions >= stepOneAtCompletions && stepOneFee < fee) {
            fee = stepOneFee;
        }
        if (stepTwoAtCompletions != 0 && completions >= stepTwoAtCompletions && stepTwoFee < fee) {
            fee = stepTwoFee;
        }
    }
}
