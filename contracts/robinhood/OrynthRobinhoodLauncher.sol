// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";

import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {LaunchPlan, LaunchPlanner} from "./libraries/LaunchPlanner.sol";
import {OrynthLaunchTokenV2} from "./OrynthLaunchTokenV2.sol";
import {OrynthTokenDeployer} from "./OrynthTokenDeployer.sol";
import {OrynthFeeLocker} from "./OrynthFeeLocker.sol";

/// @notice Permissioned Orynth factory for direct, single-sided Uniswap v4 launches.
contract OrynthRobinhoodLauncher is EIP712 {
    using ECDSA for bytes32;
    using LaunchPlanner for LaunchPlan;
    using PoolIdLibrary for PoolKey;

    bytes32 private constant LAUNCH_TYPEHASH = keccak256(
        "Launch(bytes32 projectId,address creator,bytes32 nameHash,bytes32 symbolHash,bytes32 metadataHash,bytes32 tokenInfoHash,uint256 devBuyWei,uint256 minTokensOut,uint256 nonce,uint256 deadline)"
    );

    uint24 public constant POOL_FEE = 20_000; // 2%
    int24 public constant TICK_SPACING = 200;
    int24 public constant INITIAL_TICK = 202_000; // ~1.689 ETH FDV for 1B tokens
    uint256 public constant TOKEN_SUPPLY = 1_000_000_000 ether;
    uint256 public constant MAX_DEV_BUY = 0.1 ether;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IUniversalRouter public immutable universalRouter;
    IAllowanceTransfer public immutable permit2;
    OrynthTokenDeployer public immutable tokenDeployer;
    address public immutable launchAuthority;
    address public immutable platformRecipient;
    address public immutable operator;

    mapping(address creator => uint256 nonce) public nonces;
    mapping(bytes32 projectId => bool launched) public launchedProjects;

    struct LaunchRequest {
        bytes32 projectId;
        address creator;
        string name;
        string symbol;
        string metadataURI;
        string logo;
        string description;
        string twitter;
        string telegram;
        string website;
        uint256 devBuyWei;
        uint256 minTokensOut;
        uint256 nonce;
        uint256 deadline;
    }

    event TokenLaunched(
        bytes32 indexed projectId,
        address indexed creator,
        address indexed token,
        bytes32 poolId,
        address feeLocker,
        uint256 positionTokenId,
        uint256 devBuyWei
    );

    constructor(
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IUniversalRouter universalRouter_,
        IAllowanceTransfer permit2_,
        OrynthTokenDeployer tokenDeployer_,
        address launchAuthority_,
        address platformRecipient_,
        address operator_
    ) EIP712("Orynth Robinhood Launcher", "1") {
        require(
            launchAuthority_ != address(0) && platformRecipient_ != address(0) && operator_ != address(0),
            "invalid config"
        );
        require(
            address(poolManager_) != address(0) && address(positionManager_) != address(0)
                && address(universalRouter_) != address(0) && address(permit2_) != address(0)
                && address(tokenDeployer_) != address(0),
            "invalid protocol config"
        );
        poolManager = poolManager_;
        positionManager = positionManager_;
        universalRouter = universalRouter_;
        permit2 = permit2_;
        tokenDeployer = tokenDeployer_;
        launchAuthority = launchAuthority_;
        platformRecipient = platformRecipient_;
        operator = operator_;
    }

    function launch(LaunchRequest calldata request, bytes calldata authorization)
        external
        payable
        returns (address tokenAddress, bytes32 poolId, address feeLocker, uint256 positionTokenId)
    {
        require(block.timestamp <= request.deadline, "authorization expired");
        require(!launchedProjects[request.projectId], "project already launched");
        require(request.creator != address(0), "invalid creator");
        require(request.nonce == nonces[request.creator], "invalid nonce");
        require(msg.sender == request.creator || msg.sender == operator, "invalid payer");
        require(request.devBuyWei == msg.value, "incorrect ETH value");
        require(request.devBuyWei <= MAX_DEV_BUY, "buy exceeds maximum");
        if (request.devBuyWei != 0) require(msg.sender == request.creator, "creator must fund buy");

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    LAUNCH_TYPEHASH,
                    request.projectId,
                    request.creator,
                    keccak256(bytes(request.name)),
                    keccak256(bytes(request.symbol)),
                    keccak256(bytes(request.metadataURI)),
                    keccak256(
                        abi.encode(
                            request.logo,
                            request.description,
                            request.twitter,
                            request.telegram,
                            request.website
                        )
                    ),
                    request.devBuyWei,
                    request.minTokensOut,
                    request.nonce,
                    request.deadline
                )
            )
        );
        require(digest.recover(authorization) == launchAuthority, "invalid authorization");

        launchedProjects[request.projectId] = true;
        nonces[request.creator] = request.nonce + 1;

        OrynthLaunchTokenV2 token = OrynthLaunchTokenV2(
            tokenDeployer.deployToken(
                request.name,
                request.symbol,
                request.metadataURI,
                request.logo,
                request.description,
                request.twitter,
                request.telegram,
                request.website,
                address(this),
                request.creator
            )
        );
        tokenAddress = address(token);
        require(token.TOTAL_SUPPLY() == TOKEN_SUPPLY, "unexpected token supply");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(tokenAddress),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(INITIAL_TICK);
        poolManager.initialize(key, sqrtPriceX96);
        poolId = PoolId.unwrap(key.toId());
        token.setCanonicalPool(poolId, address(poolManager), address(0), POOL_FEE);

        positionTokenId = positionManager.nextTokenId();
        OrynthFeeLocker locker = new OrynthFeeLocker(
            positionManager,
            universalRouter,
            permit2,
            key,
            IERC20(tokenAddress),
            positionTokenId,
            request.creator,
            platformRecipient,
            operator
        );
        feeLocker = address(locker);

        token.approve(address(permit2), type(uint256).max);
        permit2.approve(tokenAddress, address(positionManager), type(uint160).max, type(uint48).max);

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceX96,
            token.TOTAL_SUPPLY()
        );

        LaunchPlan memory mintPlan = LaunchPlanner.init();
        mintPlan = mintPlan.add(
            Actions.MINT_POSITION,
            abi.encode(
                key,
                tickLower,
                INITIAL_TICK,
                uint256(liquidity),
                uint128(0),
                uint128(token.TOTAL_SUPPLY()),
                feeLocker,
                bytes("")
            )
        );
        mintPlan = mintPlan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency0));
        mintPlan = mintPlan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency1));
        positionManager.modifyLiquidities(mintPlan.encode(), block.timestamp);

        if (request.devBuyWei != 0) {
            IV4Router.ExactInputSingleParams memory swapParams = IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: uint128(request.devBuyWei),
                amountOutMinimum: uint128(request.minTokensOut),
                hookData: bytes("")
            });

            LaunchPlan memory swapPlan = LaunchPlanner.init();
            swapPlan = swapPlan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(swapParams));
            swapPlan = swapPlan.add(
                Actions.SETTLE,
                abi.encode(key.currency0, ActionConstants.OPEN_DELTA, true)
            );
            swapPlan = swapPlan.add(
                Actions.TAKE,
                abi.encode(key.currency1, request.creator, ActionConstants.OPEN_DELTA)
            );

            bytes[] memory inputs = new bytes[](1);
            inputs[0] = swapPlan.encode();
            universalRouter.execute{value: request.devBuyWei}(hex"10", inputs, request.deadline);
        }

        emit TokenLaunched(
            request.projectId,
            request.creator,
            tokenAddress,
            poolId,
            feeLocker,
            positionTokenId,
            request.devBuyWei
        );
    }
}
