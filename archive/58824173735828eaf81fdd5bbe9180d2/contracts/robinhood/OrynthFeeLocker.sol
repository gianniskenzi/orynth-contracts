// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {LaunchPlan, LaunchPlanner} from "./libraries/LaunchPlanner.sol";

/// @notice Permanently holds one Uniswap v4 LP position and splits collected fees 50/50.
/// @dev There is intentionally no NFT transfer or principal-withdrawal method.
contract OrynthFeeLocker is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using LaunchPlanner for LaunchPlan;

    IPositionManager public immutable positionManager;
    IERC20 public immutable token;
    address public immutable creator;
    address public immutable platform;
    uint256 public immutable positionTokenId;

    PoolKey private _poolKey;

    uint256 public creatorEthAccrued;
    uint256 public platformEthAccrued;
    uint256 public creatorTokenAccrued;
    uint256 public platformTokenAccrued;

    event FeesCollected(uint256 ethAmount, uint256 tokenAmount);
    event CreatorClaimed(uint256 ethAmount, uint256 tokenAmount);
    event PlatformClaimed(uint256 ethAmount, uint256 tokenAmount);

    constructor(
        IPositionManager positionManager_,
        PoolKey memory poolKey_,
        IERC20 token_,
        uint256 positionTokenId_,
        address creator_,
        address platform_
    ) {
        require(
            address(positionManager_) != address(0) && address(token_) != address(0),
            "invalid protocol config"
        );
        require(creator_ != address(0) && platform_ != address(0), "invalid recipient");
        positionManager = positionManager_;
        _poolKey = poolKey_;
        token = token_;
        positionTokenId = positionTokenId_;
        creator = creator_;
        platform = platform_;
    }

    receive() external payable {}

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice Pulls fees owed to the locked position into this contract and accounts for the split.
    function collect() public nonReentrant {
        _collect();
    }

    function _collect() private {
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));

        LaunchPlan memory plan = LaunchPlanner.init();
        plan = plan.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(positionTokenId, uint256(0), uint128(0), uint128(0), bytes(""))
        );
        plan = plan.add(Actions.TAKE_PAIR, abi.encode(_poolKey.currency0, _poolKey.currency1, address(this)));
        positionManager.modifyLiquidities(plan.encode(), block.timestamp);

        uint256 ethCollected = address(this).balance - ethBefore;
        uint256 tokenCollected = token.balanceOf(address(this)) - tokenBefore;

        uint256 creatorEth = ethCollected / 2;
        uint256 creatorToken = tokenCollected / 2;
        creatorEthAccrued += creatorEth;
        platformEthAccrued += ethCollected - creatorEth;
        creatorTokenAccrued += creatorToken;
        platformTokenAccrued += tokenCollected - creatorToken;

        emit FeesCollected(ethCollected, tokenCollected);
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
}
