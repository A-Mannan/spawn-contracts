// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchpadTest} from "./Fixtures.sol";
import {MilestoneHookHarness} from "./harness/MilestoneHookHarness.sol";

/// @notice {LaunchpadTest} with the recording harness at {HOOK_ADDR} instead of the plain hook.
///
/// @dev Only the artifact changes. The satellite, the template, the NFT minter and every helper are the
/// production wiring, so a suite inheriting this is testing the real hook plus a snapshot log — see
/// {MilestoneHookHarness} for why mid-transaction state needs one.
abstract contract HarnessLaunchpadTest is LaunchpadTest {
    /// @dev `hook` still points at the same address; this is the same contract seen through the wider type.
    MilestoneHookHarness internal harness;

    function setUp() public virtual override {
        super.setUp();
        harness = MilestoneHookHarness(payable(HOOK_ADDR));
    }

    function _hookArtifact() internal view virtual override returns (string memory) {
        return "MilestoneHookHarness.sol:MilestoneHookHarness";
    }
}
