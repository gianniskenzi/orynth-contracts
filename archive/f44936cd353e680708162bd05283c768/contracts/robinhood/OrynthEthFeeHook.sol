// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta}
    from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Charges a 2% fee exclusively in native ETH and splits it between creator and Orynth.
/// @dev The hook supports both exact-input and exact-output swaps in both directions. Pools must
///      use native ETH as currency0 and must be registered by the Orynth launcher before initialize.
contract OrynthEthFeeHook is BaseHook, ReentrancyGuard {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 200;
    uint256 public constant CREATOR_SHARE_BPS = 5_000;

    address public immutable owner;
    address public immutable platform;
    address public launcher;

    mapping(PoolId poolId => address creator) public poolCreator;
    mapping(PoolId poolId => uint256 amount) public creatorEthAccrued;
    uint256 public platformEthAccrued;

    error InvalidConfig();
    error Unauthorized();
    error LauncherAlreadySet();
    error InvalidPool();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error NothingToClaim();
    error EthTransferFailed();

    event LauncherSet(address indexed launcher);
    event PoolRegistered(PoolId indexed poolId, address indexed creator);
    event EthFeeAccrued(
        PoolId indexed poolId,
        address indexed creator,
        uint256 creatorAmount,
        uint256 platformAmount
    );
    event CreatorClaimed(PoolId indexed poolId, address indexed creator, uint256 ethAmount);
    event PlatformClaimed(address indexed platform, uint256 ethAmount);

    constructor(IPoolManager manager_, address owner_, address platform_) BaseHook(manager_) {
        if (owner_ == address(0) || platform_ == address(0)) revert InvalidConfig();
        owner = owner_;
        platform = platform_;
    }

    receive() external payable {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice One-time connection between this hook and the hook-enabled launcher.
    function setLauncher(address launcher_) external {
        if (msg.sender != owner) revert Unauthorized();
        if (launcher != address(0)) revert LauncherAlreadySet();
        if (launcher_ == address(0)) revert InvalidConfig();
        launcher = launcher_;
        emit LauncherSet(launcher_);
    }

    /// @notice Registers a pool before it is initialized by the launcher.
    function registerPool(PoolKey calldata key, address creator) external returns (PoolId poolId) {
        if (msg.sender != launcher) revert Unauthorized();
        if (
            creator == address(0) || !key.currency0.isAddressZero()
                || address(key.hooks) != address(this)
        ) revert InvalidPool();

        poolId = key.toId();
        if (poolCreator[poolId] != address(0)) revert PoolAlreadyRegistered();
        poolCreator[poolId] = creator;
        emit PoolRegistered(poolId, creator);
    }

    /// @dev Handles fees that are in the specified currency:
    ///      - exact-input ETH -> token: fee is carved out of the supplied ETH;
    ///      - exact-output token -> ETH: the pool produces extra ETH for the hook while the
    ///        swapper still receives the exact requested net amount.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta delta, uint24)
    {
        PoolId poolId = key.toId();
        if (poolCreator[poolId] == address(0)) revert PoolNotRegistered();

        bool exactInput = params.amountSpecified < 0;
        uint256 fee;
        if (params.zeroForOne && exactInput) {
            uint256 grossEthIn = uint256(-params.amountSpecified);
            fee = _feeFromGross(grossEthIn);
        } else if (!params.zeroForOne && !exactInput) {
            uint256 netEthOut = uint256(params.amountSpecified);
            fee = _feeOnTop(netEthOut);
        }

        if (fee != 0) {
            _accrueAndTake(poolId, fee);
            delta = toBeforeSwapDelta(_toInt128(fee), 0);
        } else {
            delta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        }

        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @dev Handles fees that are in the unspecified currency:
    ///      - exact-input token -> ETH: fee is taken from the ETH output;
    ///      - exact-output ETH -> token: fee is added on top of the ETH input.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    ) internal override returns (bytes4, int128 hookDeltaUnspecified) {
        PoolId poolId = key.toId();
        if (poolCreator[poolId] == address(0)) revert PoolNotRegistered();

        bool exactInput = params.amountSpecified < 0;
        uint256 fee;
        if (!params.zeroForOne && exactInput) {
            int128 grossEthOut = swapDelta.amount0();
            if (grossEthOut > 0) fee = _feeFromGross(uint256(uint128(grossEthOut)));
        } else if (params.zeroForOne && !exactInput) {
            int128 netEthIn = swapDelta.amount0();
            if (netEthIn < 0) fee = _feeOnTop(uint256(uint128(-netEthIn)));
        }

        if (fee != 0) {
            _accrueAndTake(poolId, fee);
            hookDeltaUnspecified = _toInt128(fee);
        }
        return (IHooks.afterSwap.selector, hookDeltaUnspecified);
    }

    function claimCreator(PoolId poolId) external nonReentrant {
        address creator = poolCreator[poolId];
        if (msg.sender != creator) revert Unauthorized();
        uint256 amount = creatorEthAccrued[poolId];
        if (amount == 0) revert NothingToClaim();
        creatorEthAccrued[poolId] = 0;
        _sendEth(creator, amount);
        emit CreatorClaimed(poolId, creator, amount);
    }

    function claimPlatform() external nonReentrant {
        if (msg.sender != platform) revert Unauthorized();
        uint256 amount = platformEthAccrued;
        if (amount == 0) revert NothingToClaim();
        platformEthAccrued = 0;
        _sendEth(platform, amount);
        emit PlatformClaimed(platform, amount);
    }

    function quoteFeeFromGross(uint256 grossEth) external pure returns (uint256) {
        return _feeFromGross(grossEth);
    }

    function quoteFeeOnTop(uint256 netEth) external pure returns (uint256) {
        return _feeOnTop(netEth);
    }

    function _accrueAndTake(PoolId poolId, uint256 fee) private {
        address creator = poolCreator[poolId];
        uint256 creatorAmount = (fee * CREATOR_SHARE_BPS) / BPS;
        uint256 platformAmount = fee - creatorAmount;
        creatorEthAccrued[poolId] += creatorAmount;
        platformEthAccrued += platformAmount;

        poolManager.take(Currency.wrap(address(0)), address(this), fee);
        emit EthFeeAccrued(poolId, creator, creatorAmount, platformAmount);
    }

    function _feeFromGross(uint256 grossEth) private pure returns (uint256) {
        return (grossEth * FEE_BPS) / BPS;
    }

    function _feeOnTop(uint256 netEth) private pure returns (uint256) {
        uint256 denominator = BPS - FEE_BPS;
        return (netEth * FEE_BPS + denominator - 1) / denominator;
    }

    function _toInt128(uint256 value) private pure returns (int128) {
        if (value > uint256(uint128(type(int128).max))) revert InvalidPool();
        return int128(uint128(value));
    }

    function _sendEth(address recipient, uint256 amount) private {
        (bool sent,) = payable(recipient).call{value: amount}("");
        if (!sent) revert EthTransferFailed();
    }
}
