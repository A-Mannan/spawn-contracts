// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {ProtocolTemplate} from "../../src/types/LaunchTypes.sol";
import {LaunchpadTest} from "../Fixtures.sol";

/// @notice Test-only payout seam with real PoolManager claim backing and production accounting.
contract PayoutTestHook is MilestoneHook {
    uint8 private constant _BACK_PAYOUT = 200;

    constructor(
        IPoolManager manager,
        RevenueNFT nft,
        LaunchSupport support,
        ProtocolTemplate memory template,
        address coldPaths,
        address payoutPaths,
        address controller,
        address recipient,
        address trustedOperator
    ) MilestoneHook(manager, nft, support, template, coldPaths, payoutPaths, controller, recipient, trustedOperator) {}

    function fundPayoutPot(PoolId poolId, uint32 milestoneIndex, uint256 grossQuote) external payable {
        require(msg.value == grossQuote, "value");
        poolManager.unlock(abi.encode(_BACK_PAYOUT, grossQuote));
        _fundPayoutPot(poolId, milestoneIndex, grossQuote);
    }

    function accrueDirectCreator(PoolId poolId, uint256 amount) external payable {
        require(msg.value == amount, "value");
        _accrueCreator(poolId, amount, AccrualSource.SWAP_FEES);
        _assertSolvent();
    }

    function accrueRawProtocol(PoolId poolId, uint256 amount) external payable {
        require(msg.value == amount, "value");
        _accrueProtocol(poolId, amount, AccrualSource.SWAP_FEES);
        _assertSolvent();
    }

    function _dispatchUnlock(bytes calldata data) internal override returns (bytes memory) {
        if (uint8(uint256(bytes32(data[0:32]))) < 200) return super._dispatchUnlock(data);
        (, uint256 amount) = abi.decode(data, (uint8, uint256));
        Currency native = Currency.wrap(address(0));
        _settleCurrency(native, amount);
        _mintClaim(native, amount);
        return "";
    }
}

/// @notice Shared fixture placing {PayoutTestHook} at the mined production hook address.
abstract contract PayoutTestFixture is LaunchpadTest {
    PayoutTestHook internal payoutHook;

    function setUp() public virtual override {
        super.setUp();
        payoutHook = PayoutTestHook(payable(HOOK_ADDR));
    }

    function _hookArtifact() internal view virtual override returns (string memory) {
        return "PayoutTestHook.sol:PayoutTestHook";
    }

    function _fundPot(PoolId id, uint32 milestoneIndex, uint256 grossQuote) internal {
        payoutHook.fundPayoutPot{value: grossQuote}(id, milestoneIndex, grossQuote);
    }
}
