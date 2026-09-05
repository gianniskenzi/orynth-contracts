// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";

import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {LaunchPlan, LaunchPlanner} from "./libraries/LaunchPlanner.sol";

/// @notice Permanently holds one Uniswap v4 LP position and splits collected fees 50/50.
/// @dev There is intentionally no NFT transfer or principal-withdrawal method.
contract OrynthFeeLocker is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using LaunchPlanner for LaunchPlan;

    IPositionManager public immutable positionManager;
    IUniversalRouter public immutable universalRouter;
    IAllowanceTransfer public immutable permit2;
    IERC20 public immutable token;
    address public immutable creator;
    address public immutable platform;
    address public immutable operator;
    uint256 public immutable positionTokenId;

    PoolKey private _poolKey;

    uint256 public creatorEthAccrued;
    uint256 public platformEthAccrued;
    uint256 public creatorTokenAccrued;
    uint256 public platformTokenAccrued;

    event FeesCollected(uint256 ethAmount, uint256 tokenAmount);
    event CreatorClaimed(uint256 ethAmount, uint256 tokenAmount);
    event PlatformClaimed(uint256 ethAmount, uint256 tokenAmount);
    event TokenFeesSwept(
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 creatorTokenAmount,
        uint256 platformTokenAmount
    );
    event CreatorAutoPaid(uint256 ethAmount);
    event CreatorAutoPayoutDeferred(uint256 ethAmount);

    constructor(
        IPositionManager positionManager_,
        IUniversalRouter universalRouter_,
        IAllowanceTransfer permit2_,
        PoolKey memory poolKey_,
        IERC20 token_,
        uint256 positionTokenId_,
        address creator_,
        address platform_,
        address operator_
    ) {
        require(
            address(positionManager_) != address(0) && address(universalRouter_) != address(0)
                && address(permit2_) != address(0) && address(token_) != address(0),
            "invalid protocol config"
        );
        require(
            creator_ != address(0) && platform_ != address(0) && operator_ != address(0),
            "invalid recipient"
        );
        positionManager = positionManager_;
        universalRouter = universalRouter_;
        permit2 = permit2_;
        _poolKey = poolKey_;
        token = token_;
        positionTokenId = positionTokenId_;
        creator = creator_;
        platform = platform_;
        operator = operator_;

        token_.forceApprove(address(permit2_), type(uint256).max);
        permit2_.approve(
            address(token_), address(universalRouter_), type(uint160).max, type(uint48).max
        );
    }

    receive() external payable {}

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice Pulls fees owed to the locked position into this contract and accounts for the split.
    function collect() public nonReentrant returns (uint256 ethCollected, uint256 tokenCollected) {
        return _collect();
    }

    function _collect() private returns (uint256 ethCollected, uint256 tokenCollected) {
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));

        LaunchPlan memory plan = LaunchPlanner.init();
        plan = plan.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(positionTokenId, uint256(0), uint128(0), uint128(0), bytes(""))
        );
        plan = plan.add(Actions.TAKE_PAIR, abi.encode(_poolKey.currency0, _poolKey.currency1, address(this)));
        positionManager.modifyLiquidities(plan.encode(), block.timestamp);

        ethCollected = address(this).balance - ethBefore;
        tokenCollected = token.balanceOf(address(this)) - tokenBefore;

        uint256 creatorEth = ethCollected / 2;
        uint256 creatorToken = tokenCollected / 2;
        creatorEthAccrued += creatorEth;
        platformEthAccrued += ethCollected - creatorEth;
        creatorTokenAccrued += creatorToken;
        platformTokenAccrued += tokenCollected - creatorToken;

        emit FeesCollected(ethCollected, tokenCollected);
    }

    /// @notice Converts already-earned token fees to ETH and immediately pays the creator's
    ///         complete ETH balance. The operator chooses when to call and must protect the
    ///         conversion with a non-zero minimum output. Normal pool trading never depends on it.
    function sweepTokenFees(uint256 tokenAmount, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 ethOut, uint256 creatorPaid)
    {
        require(msg.sender == operator, "operator only");
        require(tokenAmount != 0 && minEthOut != 0, "invalid sweep");
        require(block.timestamp <= deadline, "sweep expired");

        _collect();

        uint256 creatorTokensAvailable = creatorTokenAccrued;
        uint256 platformTokensAvailable = platformTokenAccrued;
        uint256 totalTokensAvailable = creatorTokensAvailable + platformTokensAvailable;
        require(tokenAmount <= totalTokensAvailable, "insufficient token fees");

        uint256 creatorTokensSold =
            (tokenAmount * creatorTokensAvailable) / totalTokensAvailable;
        uint256 platformTokensSold = tokenAmount - creatorTokensSold;
        creatorTokenAccrued = creatorTokensAvailable - creatorTokensSold;
        platformTokenAccrued = platformTokensAvailable - platformTokensSold;

        uint256 ethBefore = address(this).balance;
        IV4Router.ExactInputSingleParams memory swapParams = IV4Router.ExactInputSingleParams({
            poolKey: _poolKey,
            zeroForOne: false,
            amountIn: _toUint128(tokenAmount),
            amountOutMinimum: _toUint128(minEthOut),
            hookData: bytes("")
        });

        LaunchPlan memory swapPlan = LaunchPlanner.init();
        swapPlan = swapPlan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(swapParams));
        swapPlan = swapPlan.add(
            Actions.SETTLE, abi.encode(_poolKey.currency1, ActionConstants.OPEN_DELTA, true)
        );
        swapPlan = swapPlan.add(
            Actions.TAKE,
            abi.encode(_poolKey.currency0, address(this), ActionConstants.OPEN_DELTA)
        );

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = swapPlan.encode();
        universalRouter.execute(hex"10", inputs, deadline);

        ethOut = address(this).balance - ethBefore;
        require(ethOut >= minEthOut, "insufficient ETH output");

        uint256 creatorConvertedEth = (ethOut * creatorTokensSold) / tokenAmount;
        creatorEthAccrued += creatorConvertedEth;
        platformEthAccrued += ethOut - creatorConvertedEth;

        emit TokenFeesSwept(
            tokenAmount, ethOut, creatorTokensSold, platformTokensSold
        );

        creatorPaid = creatorEthAccrued;
        if (creatorPaid != 0) {
            creatorEthAccrued = 0;
            (bool sent,) = payable(creator).call{value: creatorPaid, gas: 30_000}("");
            if (sent) {
                emit CreatorAutoPaid(creatorPaid);
            } else {
                creatorEthAccrued = creatorPaid;
                creatorPaid = 0;
                emit CreatorAutoPayoutDeferred(creatorEthAccrued);
            }
        }
    }

    function claimCreator() external nonReentrant {
        require(msg.sender == creator, "creator only");
        _claimCreator();
    }

    function claimPlatform() external nonReentrant {
        require(msg.sender == platform, "platform only");
        uint256 ethAmount = platformEthAccrued;
        uint256 tokenAmount = platformTokenAccrued;
        platformEthAccrued = 0;
        platformTokenAccrued = 0;
        _pay(platform, ethAmount, tokenAmount);
        emit PlatformClaimed(ethAmount, tokenAmount);
    }

    function collectAndClaimCreator() external nonReentrant {
        require(msg.sender == creator, "creator only");
        _collect();
        _claimCreator();
    }

    function _claimCreator() private {
        uint256 ethAmount = creatorEthAccrued;
        uint256 tokenAmount = creatorTokenAccrued;
        creatorEthAccrued = 0;
        creatorTokenAccrued = 0;
        _pay(creator, ethAmount, tokenAmount);
        emit CreatorClaimed(ethAmount, tokenAmount);
    }

    function _pay(address recipient, uint256 ethAmount, uint256 tokenAmount) private {
        if (tokenAmount != 0) token.safeTransfer(recipient, tokenAmount);
        if (ethAmount != 0) {
            (bool sent,) = payable(recipient).call{value: ethAmount}("");
            require(sent, "ETH transfer failed");
        }
    }

    function _toUint128(uint256 amount) private pure returns (uint128) {
        require(amount <= type(uint128).max, "amount too large");
        return uint128(amount);
    }
}
