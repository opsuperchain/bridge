// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";

// Minimal interfaces for Uniswap V4
interface IPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
}

interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
}

/// @notice Create a Uniswap V4 pool and add full-range liquidity for wrapped VIRTUAL / WETH
contract CreatePool is Script {
    // Uniswap V4 on OP Mainnet
    address constant POOL_MANAGER = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
    address constant POSITION_MANAGER = 0x3C3Ea4B57a46241e54610e5f022E5c45859A1017;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Tokens (currency0 must be < currency1)
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WRAPPED_VIRTUAL = 0xa29BbDAa47Da95Ab1EC829DCb12AcFd004a0df6C;

    // Pool params: 0.3% fee, tickSpacing=60
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    // Full range ticks for tickSpacing=60
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    // Action constants
    uint8 constant MINT_POSITION = 2;
    uint8 constant SETTLE_PAIR = 13;

    function run() external {
        // 1 ETH ≈ $2700, 1 VIRTUAL ≈ $1.50 → 1 WETH = ~1800 VIRTUAL
        // sqrtPriceX96 = sqrt(1800) * 2^96
        uint160 sqrtPriceX96 = 3361366258487168519347365740544;

        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        uint256 amount0 = IERC20(WETH).balanceOf(deployer);
        uint256 amount1 = IERC20(WRAPPED_VIRTUAL).balanceOf(deployer);
        console.log("WETH balance:", amount0);
        console.log("VIRTUAL balance:", amount1);

        vm.startBroadcast();

        // Step 1: Initialize the pool
        IPoolManager.PoolKey memory poolKey = IPoolManager.PoolKey({
            currency0: WETH,
            currency1: WRAPPED_VIRTUAL,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(0)
        });

        // Pool already initialized — skip
        // int24 tick = IPoolManager(POOL_MANAGER).initialize(poolKey, sqrtPriceX96);
        console.log("Adding to existing pool");

        // Step 2: Approve tokens to Permit2
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IERC20(WRAPPED_VIRTUAL).approve(PERMIT2, type(uint256).max);

        // Step 3: Approve PositionManager via Permit2
        IPermit2(PERMIT2).approve(WETH, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(WRAPPED_VIRTUAL, POSITION_MANAGER, type(uint160).max, type(uint48).max);

        // Step 4: Mint full-range position
        // Use all available tokens as max
        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);

        bytes[] memory params = new bytes[](2);

        // MINT_POSITION params
        params[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            uint256(160000000000000000), // liquidity — fits our WETH balance
            uint128(amount0),     // amount0Max (WETH)
            uint128(amount1),     // amount1Max (VIRTUAL)
            deployer,             // recipient
            bytes("")             // hookData
        );

        // SETTLE_PAIR params
        params[1] = abi.encode(WETH, WRAPPED_VIRTUAL);

        bytes memory unlockData = abi.encode(actions, params);
        uint256 deadline = block.timestamp + 600;

        IPositionManager(POSITION_MANAGER).modifyLiquidities(unlockData, deadline);

        console.log("Liquidity added!");

        vm.stopBroadcast();
    }
}
