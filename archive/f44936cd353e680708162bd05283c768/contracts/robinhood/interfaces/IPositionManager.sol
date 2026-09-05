// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal Uniswap v4 PositionManager interface used by the Orynth launcher and fee locker.
interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    function nextTokenId() external view returns (uint256);
}
