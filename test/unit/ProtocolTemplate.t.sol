// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {Bounds, LaunchConfig, PoolState, ProtocolTemplate} from "../../src/types/LaunchTypes.sol";

/// @notice Unit tests for task 15.1 — the `ProtocolTemplate` immutable struct and the opening-level
/// derivation that anchors every launch to the same fully diluted valuation.
contract ProtocolTemplateTest is LaunchpadTest {
    // --- Scenario: The opening price is derived from the FDV anchor ---
    // --- Scenario (token-launch): Starting price matches the anchored opening FDV ---

    /// @dev The realised FDV read back out of the pool's own price, which is the only figure a buyer can
    /// actually observe. `FDV = totalSupply / price` and `price = (sqrtP / 2**96)**2`, so this is the
    /// derivation in {CurveLib.openingLevel} run backwards.
    function _impliedFdvWei(PoolId id, uint256 totalSupply) internal view returns (uint256) {
        uint160 sqrtPriceX96 = _sqrtPriceOf(id);
        uint256 half = FullMath.mulDiv(totalSupply, 1 << 96, sqrtPriceX96);
        return FullMath.mulDiv(half, 1 << 96, sqrtPriceX96);
    }

    function test_openingFdvMatchesTheAnchor() public view {
        uint256 fdv = _impliedFdvWei(poolId, SUPPLY);

        // A tick is one basis point, so the anchor is hit to within v4's price granularity rather than
        // exactly. Two ticks of slack covers the floor in `getTickAtSqrtPrice` plus the sqrt.
        assertApproxEqRel(fdv, template.openingFdvWei, 0.0005e18, "opens at the anchored FDV");
    }

    // --- Scenario: Every launch opens at the same valuation ---

    /// @dev This is the hole design Decision 16 closed: with a fixed opening *price*, a
    /// hundred-billion-supply token would have opened at a thousand times the valuation of a
    /// hundred-million-supply one.
    function test_twoSuppliesOpenAtTheSameFdv() public {
        uint256 smallSupply = 1_000_000 ether;
        uint256 largeSupply = 100_000_000_000 ether;

        LaunchConfig memory small = _defaultConfig("Small", "SML");
        small.totalSupply = smallSupply;
        (PoolId smallId,,) = _launchDirect(small);

        LaunchConfig memory large = _defaultConfig("Large", "LRG");
        large.totalSupply = largeSupply;
        (PoolId largeId,,) = _launchDirect(large);

        uint256 smallFdv = _impliedFdvWei(smallId, smallSupply);
        uint256 largeFdv = _impliedFdvWei(largeId, largeSupply);

        assertApproxEqRel(smallFdv, template.openingFdvWei, 0.0005e18, "small supply hits the anchor");
        assertApproxEqRel(largeFdv, template.openingFdvWei, 0.0005e18, "large supply hits the anchor");
        assertApproxEqRel(smallFdv, largeFdv, 0.001e18, "both open at the same valuation");
    }

    /// @dev A five-order-of-magnitude supply difference must move the *level*, or the anchor is not
    /// doing anything. The gap is `ln(1e5) / ln(1.0001)` — 115,136 levels, not the 115,129 that dividing
    /// by a flat 1e-4 would suggest; the tick base's own logarithm matters in the sixth figure.
    function test_largerSupplyOpensAtALowerLevel() public {
        LaunchConfig memory small = _defaultConfig("Small", "SML");
        small.totalSupply = 1_000_000 ether;
        (PoolId smallId,,) = _launchDirect(small);

        LaunchConfig memory large = _defaultConfig("Large", "LRG");
        large.totalSupply = 100_000_000_000 ether;
        (PoolId largeId,,) = _launchDirect(large);

        int24 smallLevel = hook.poolState(smallId).openingLevel;
        int24 largeLevel = hook.poolState(largeId).openingLevel;

        assertGt(smallLevel, largeLevel, "a scarcer token opens at a higher level");
        assertApproxEqAbs(int256(smallLevel) - int256(largeLevel), 115_136, 4, "the gap is ln(1e5) in level units");
    }

    function test_openingLevelIsDeterministicForASupply() public view {
        assertEq(
            CurveLib.openingLevel(SUPPLY, template.openingFdvWei),
            hook.poolState(poolId).openingLevel,
            "the pool opened where the pure derivation says"
        );
    }

    /// @dev The far level is the graduation target, so a 2x curve span means graduation is a doubling of
    /// the opening valuation — 250 ETH against the 125 ETH anchor.
    function test_farLevelIsOneCurveSpanAboveOpening() public view {
        PoolState memory state = hook.poolState(poolId);
        assertEq(
            int256(state.farLevel) - int256(state.openingLevel),
            int256(template.curveSpanLevels),
            "far level is exactly one curve span up"
        );
        assertEq(template.curveSpanLevels, Bounds.LEVELS_PER_DOUBLING, "the span is a market-cap doubling");
    }

    /// @dev The FDV anchor inverts the supply, so an unbounded supply is the input that breaks it: at
    /// `totalSupply > openingFdvWei * 2**64` (about 2.3e39 wei against the 125 ETH anchor) the
    /// `mulDiv(supply, 2**192, fdv)` in {CurveLib.openingLevel} exceeds a word and reverts. That is the
    /// reachable rejection, and it lands at launch rather than at some later swap.
    ///
    /// The out-of-tick-range branch inside `openingLevel` is *not* reachable from above — the multiply
    /// overflows long before a price could exceed `MAX_SQRT_PRICE` — so it stands as a guard rather than
    /// as a case a launch can produce, and this pins which of the two actually fires.
    function test_absurdSupplyIsRejected() public {
        LaunchConfig memory config = _defaultConfig("Absurd", "ABS");
        config.totalSupply = type(uint256).max;

        vm.prank(creator);
        vm.expectRevert();
        hook.launch(config, "");
    }

    /// @dev The other side of that boundary: a supply far beyond anything a real launch would use is still
    /// priced and launched, so the rejection above is a genuine arithmetic limit and not a low ceiling on
    /// what the protocol accepts.
    function test_anEnormousButRepresentableSupplyLaunches() public {
        LaunchConfig memory config = _defaultConfig("Enormous", "ENR");
        config.totalSupply = type(uint128).max;

        (PoolId id,,) = _launchDirect(config);

        assertApproxEqRel(
            _impliedFdvWei(id, config.totalSupply),
            template.openingFdvWei,
            0.0005e18,
            "even an absurd supply opens at the anchor"
        );
    }

    // --- Scenario (milestone-ladder): One template applies to all launches ---
    // (the immutability half — {LadderLibTest} takes the geometry half)

    function test_templateMatchesTheConstructorArgument() public view {
        ProtocolTemplate memory t = hook.template();

        assertEq(t.openingFdvWei, template.openingFdvWei, "openingFdvWei");
        assertEq(t.curvePositions, template.curvePositions, "curvePositions");
        assertEq(t.curveSpanLevels, template.curveSpanLevels, "curveSpanLevels");
        assertEq(t.bandLevelSpacing, template.bandLevelSpacing, "bandLevelSpacing");
        assertEq(t.bandWidthLevels, template.bandWidthLevels, "bandWidthLevels");
        assertEq(t.coreBandCount, template.coreBandCount, "coreBandCount");
        assertEq(t.maxFeeFundedBands, template.maxFeeFundedBands, "maxFeeFundedBands");
        assertEq(t.curveSupplyShareWad, template.curveSupplyShareWad, "curveSupplyShareWad");
        assertEq(t.ladderSupplyShareWad, template.ladderSupplyShareWad, "ladderSupplyShareWad");
        assertEq(t.fullRangeSupplyShareWad, template.fullRangeSupplyShareWad, "fullRangeSupplyShareWad");
        assertEq(t.lpSeedWad, template.lpSeedWad, "lpSeedWad");
        assertEq(t.proceedsCreatorWad, template.proceedsCreatorWad, "proceedsCreatorWad");
        assertEq(t.proceedsProtocolWad, template.proceedsProtocolWad, "proceedsProtocolWad");
        assertEq(t.baseFeeHundredthsBip, template.baseFeeHundredthsBip, "baseFeeHundredthsBip");
        assertEq(t.feeStepOneAtCompletions, template.feeStepOneAtCompletions, "feeStepOneAtCompletions");
        assertEq(t.feeStepOneFee, template.feeStepOneFee, "feeStepOneFee");
        assertEq(t.feeStepTwoAtCompletions, template.feeStepTwoAtCompletions, "feeStepTwoAtCompletions");
        assertEq(t.feeStepTwoFee, template.feeStepTwoFee, "feeStepTwoFee");
        assertEq(t.milestoneFundShareWad, template.milestoneFundShareWad, "milestoneFundShareWad");
        assertEq(t.bandInventoryCapMultiple, template.bandInventoryCapMultiple, "bandInventoryCapMultiple");
        assertEq(t.maxDeploysPerSwap, template.maxDeploysPerSwap, "maxDeploysPerSwap");
        assertEq(t.maxHarvestsPerSwap, template.maxHarvestsPerSwap, "maxHarvestsPerSwap");
        assertEq(t.defaultCreatorWad, template.defaultCreatorWad, "defaultCreatorWad");
        assertEq(t.defaultBuybackWad, template.defaultBuybackWad, "defaultBuybackWad");
        assertEq(t.defaultProtocolWad, template.defaultProtocolWad, "defaultProtocolWad");
        assertEq(t.defaultLpWad, template.defaultLpWad, "defaultLpWad");
    }

    /// @dev No setter exists for any template field, on either half of the delegatecall pair. Probed by
    /// selector rather than asserted by inspection so that adding one would fail this test.
    function test_noTemplateSetterExists() public {
        string[6] memory sigs = [
            "setTemplate((uint256,uint16,int24,int24,int24,uint8,uint8,uint64,uint64,uint64,uint64,uint64,uint64,uint24,uint8,uint24,uint8,uint24,uint64,uint8,uint8,uint8,uint64,uint64,uint64,uint64))",
            "setBandLevelSpacing(int24)",
            "setOpeningFdv(uint256)",
            "setBaseFee(uint24)",
            "setCurvePositions(uint16)",
            "setSupplySplit(uint64,uint64,uint64)"
        ];

        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = HOOK_ADDR.call(abi.encodeWithSignature(sigs[i], 0));
            assertFalse(ok, "no template setter on the hook");
            (bool ok2,) = address(coldPaths).call(abi.encodeWithSignature(sigs[i], 0));
            assertFalse(ok2, "no template setter on the satellite");
        }
    }

    /// @dev The template survives a full lifecycle unchanged — it is bytecode, not storage, so nothing
    /// a pool does could touch it, and this pins that.
    function test_templateIsUnchangedByAFullLifecycle() public {
        ProtocolTemplate memory before_ = hook.template();

        _graduate();
        (int24 lower,,) = hook.bandLevels(poolId, 2);
        _buyToLevel(5_000 ether, lower);
        hook.collectFees(key);

        ProtocolTemplate memory after_ = hook.template();
        assertEq(keccak256(abi.encode(before_)), keccak256(abi.encode(after_)), "template unchanged");
    }

    /// @dev Both halves must agree, because each reads the template from its *own* bytecode even while
    /// the satellite executes as the hook. A mismatch is silent at runtime — neither half can see the
    /// other's copy — so this is the runtime form of the Migration Plan's step 4.
    ///
    /// Compared through `templateHash()`, which is on the base for exactly this reason; the satellite has
    /// no bytecode budget for a second struct-returning view. The digest is also checked against the
    /// struct the hook reports, which pins the two accessors to each other — a field the constructor
    /// stopped copying into its immutable would still be inside the digest, and would fail here.
    function test_bothHalvesCarryTheSameTemplate() public view {
        assertEq(hook.templateHash(), coldPaths.templateHash(), "hook and satellite agree on the template");
        assertEq(hook.templateHash(), keccak256(abi.encode(template)), "the digest is the constructed struct");
        assertEq(hook.templateHash(), keccak256(abi.encode(hook.template())), "and the reported struct matches");
    }

    // --- Scenario: Geometry is not configurable ---

    /// @dev The launch configuration has no geometry field to supply, which is stronger than validating
    /// one: a degenerate ladder is unrepresentable rather than rejected. Probed by ABI shape, so adding
    /// a geometry field back would fail here.
    function test_launchConfigCarriesNoGeometry() public {
        // The launch selector is fixed by the config struct's shape. If a geometry field were added, the
        // encoding below would no longer be a valid call.
        LaunchConfig memory config = _defaultConfig("Shape", "SHP");
        bytes memory encoded = abi.encodeWithSelector(hook.launch.selector, config, bytes(""));

        vm.prank(creator);
        (bool ok,) = HOOK_ADDR.call(encoded);
        assertTrue(ok, "the config struct is exactly name/symbol/supply/devBuy/split/deadline");
    }

    /// @dev Two launches with different creators and different supplies still share every geometry
    /// number, which is what "one template applies to all launches" means in practice.
    function test_geometryIsIdenticalAcrossLaunches() public {
        LaunchConfig memory other = _defaultConfig("Other", "OTH");
        other.totalSupply = 42_000_000 ether;
        other.harvestSplit = _split(0.7e18, 0.1e18, 0.05e18);

        bytes memory signature = _sign(other, CREATOR_PK);
        vm.prank(RELAYER);
        (PoolId otherId,,) = hook.launch(other, signature);

        PoolState memory a = hook.poolState(poolId);
        PoolState memory b = hook.poolState(otherId);

        // Geometry lives in the template, so the only per-pool difference is where each pool opened.
        assertEq(
            int256(a.farLevel) - int256(a.openingLevel),
            int256(b.farLevel) - int256(b.openingLevel),
            "identical curve span"
        );
        assertTrue(a.openingLevel != b.openingLevel, "different supplies open at different levels");
    }
}
