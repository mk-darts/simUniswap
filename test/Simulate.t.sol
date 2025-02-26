// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "v4-core/src/../test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {Counter} from "../src/Counter.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {EasyPosm} from "../test/utils/EasyPosm.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "../test/utils/forks/DeployPermit2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

contract SimulateTest is Test, DeployPermit2 {
    using EasyPosm for IPositionManager;

    IPoolManager manager;
    IPositionManager posm;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    MockERC20 tokenDAR; // DAR
    MockERC20 tokenUSDT; // USDT
    PoolKey poolKey;
    PoolKey customPool;
    Counter hook;
    int24 tickSpacing;
    bytes ZERO_BYTES = new bytes(0);
    address company = makeAddr("company");
    address investor1 = makeAddr("investor1");
    uint256 darMintAmount = 100_000_000_000 ether;
    uint256 usdtMintAmount = 1_000_000 ether;

    function setUp() public {
        ZERO_BYTES = new bytes(0);
        tickSpacing = 60;
        manager = deployPoolManager();

        posm = deployPosm(manager);
        (lpRouter, swapRouter, ) = deployRouters(manager);

        // 設定mint
        (tokenDAR, tokenUSDT) = deployTokens();
        tokenDAR.mint(company, darMintAmount);
        tokenUSDT.mint(company, usdtMintAmount);

        // approve the tokens to the routers
        vm.startPrank(company);
        tokenDAR.approve(address(lpRouter), type(uint256).max);
        tokenUSDT.approve(address(lpRouter), type(uint256).max);
        approvePosmCurrency(posm, Currency.wrap(address(tokenDAR)));
        approvePosmCurrency(posm, Currency.wrap(address(tokenUSDT)));
        vm.stopPrank();

        vm.startPrank(investor1);
        tokenDAR.approve(address(swapRouter), type(uint256).max);
        tokenUSDT.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // make the pool
        customPool = PoolKey({
            currency0: Currency.wrap(address(tokenDAR)),
            currency1: Currency.wrap(address(tokenUSDT)),
            fee: 3000, // 0.3%
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    // 価格レンジ下限なし、 上限0.002（10倍）
    function testSim_2_70000USDT_sell() public {
        console.log("testSim_2_70000USDT_sell");
        tokenDAR.mint(investor1, darMintAmount);

        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(2, 1e4);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // swap取引量
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        uint256 usdtAmount = 70000e18; // *10
        // uint160 sqrtPriceLower = encodePriceSqrt(2, 1e5);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);

        // int24 tickLower = (TickMath.getTickAtSqrtPrice(sqrtPriceLower) /
        //     tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.getTickAtSqrtPrice(sqrtPriceUpper) /
            tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceUpper,
            type(uint128).max, // desiredDARAmount,
            usdtAmount
        );

        // make liquidity
        vm.startPrank(company);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity, // amount0
            type(uint256).max, // amount0Max
            usdtAmount, // amount1Max
            company,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();
        uint256 combalance0 = darMintAmount - tokenDAR.balanceOf(company);
        uint256 combalance1 = usdtMintAmount - tokenUSDT.balanceOf(company);
        console.log("poolDAR balance:", combalance0 / 1e18);
        console.log("poolUSDT balance:", combalance1 / 1e18);

        // 以下、swapシミュレーション
        int256 amountSpecified = 34000 ether; // 取引量：
        vm.startPrank(investor1);
        for (uint i = 0; i < 2; i++) {
            console.log("Swap", i + 1);
            // swap前の価格取得
            uint160 sqrtPriceBefore = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"前 1DAR =",
                toReadablePriceFixed(sqrtPriceBefore),
                "USDT"
            );

            // tokenDAR -> tokenUSDT のswapパラメータ設定
            bool zeroForOne = true; // tokenDAR -> tokenUSDT
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
            });
            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            // swap実行
            swapRouter.swap(customPool, params, testSettings, ZERO_BYTES);

            // swap後の価格取得
            uint160 sqrtPriceAfter = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"後 1DAR =",
                toReadablePriceFixed(sqrtPriceAfter),
                "USDT"
            );

            // 価格変動量（スリッページ）の計算とログ出力
            uint256 priceBefore = ((uint256(sqrtPriceBefore) *
                uint256(sqrtPriceBefore)) * 1e18) >> 192;
            uint256 priceAfter = ((uint256(sqrtPriceAfter) *
                uint256(sqrtPriceAfter)) * 1e18) >> 192;
            if (sqrtPriceAfter >= sqrtPriceBefore) {
                console.log(
                    unicode"価格上昇：",
                    priceAfter - priceBefore,
                    "USDT"
                );
            } else {
                console.log(
                    unicode"価格下降：",
                    priceBefore - priceAfter,
                    "USDT"
                );
            }

            console.log(unicode"取引量:", amountSpecified / 1 ether);

            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            uint256 balance0 = darMintAmount - tokenDAR.balanceOf(investor1);
            uint256 balance1 = tokenUSDT.balanceOf(investor1);
            console.log("investDAR: ", formatBalance(balance0, 18), "DAR");
            console.log("investUSDT: ", formatBalance(balance1, 18), "USDT");
        }
        vm.stopPrank();
    }

    // 価格レンジ下限なし、 上限0.002（10倍）
    function testSim_2_7000USDT_sell() public {
        console.log("testSim_2_7000USDT_sell");
        tokenDAR.mint(investor1, darMintAmount);

        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(2, 1e4);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // swap取引量
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        uint256 usdtAmount = 7000e18; // *10
        // uint160 sqrtPriceLower = encodePriceSqrt(2, 1e5);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);

        // int24 tickLower = (TickMath.getTickAtSqrtPrice(sqrtPriceLower) /
        //     tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.getTickAtSqrtPrice(sqrtPriceUpper) /
            tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceUpper,
            type(uint128).max, // desiredDARAmount,
            usdtAmount
        );

        // make liquidity
        vm.startPrank(company);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity, // amount0
            type(uint256).max, // amount0Max
            usdtAmount, // amount1Max
            company,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();
        uint256 combalance0 = darMintAmount - tokenDAR.balanceOf(company);
        uint256 combalance1 = usdtMintAmount - tokenUSDT.balanceOf(company);
        console.log("poolDAR balance:", combalance0 / 1e18);
        console.log("poolUSDT balance:", combalance1 / 1e18);

        // 以下、swapシミュレーション
        int256 amountSpecified = 3400 ether; // 取引量：
        vm.startPrank(investor1);
        for (uint i = 0; i < 2; i++) {
            console.log("Swap", i + 1);
            // swap前の価格取得
            uint160 sqrtPriceBefore = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"前 1DAR =",
                toReadablePriceFixed(sqrtPriceBefore),
                "USDT"
            );

            // tokenDAR -> tokenUSDT のswapパラメータ設定
            bool zeroForOne = true; // tokenDAR -> tokenUSDT
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
            });
            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            // swap実行
            swapRouter.swap(customPool, params, testSettings, ZERO_BYTES);

            // swap後の価格取得
            uint160 sqrtPriceAfter = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"後 1DAR =",
                toReadablePriceFixed(sqrtPriceAfter),
                "USDT"
            );

            // 価格変動量（スリッページ）の計算とログ出力
            uint256 priceBefore = ((uint256(sqrtPriceBefore) *
                uint256(sqrtPriceBefore)) * 1e18) >> 192;
            uint256 priceAfter = ((uint256(sqrtPriceAfter) *
                uint256(sqrtPriceAfter)) * 1e18) >> 192;
            if (sqrtPriceAfter >= sqrtPriceBefore) {
                console.log(
                    unicode"価格上昇：",
                    priceAfter - priceBefore,
                    "USDT"
                );
            } else {
                console.log(
                    unicode"価格下降：",
                    priceBefore - priceAfter,
                    "USDT"
                );
            }

            console.log(unicode"取引量:", amountSpecified / 1 ether);

            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            uint256 balance0 = darMintAmount - tokenDAR.balanceOf(investor1);
            uint256 balance1 = tokenUSDT.balanceOf(investor1);
            console.log("investDAR: ", formatBalance(balance0, 18), "DAR");
            console.log("investUSDT: ", formatBalance(balance1, 18), "USDT");
        }
        vm.stopPrank();
    }

    // 価格レンジ下限なし、 上限0.002（10倍）
    function testSim_2_350000USDT_sell() public {
        console.log("testSim_2_350000USDT_sell");
        tokenDAR.mint(investor1, darMintAmount);

        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(2, 1e4);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // swap取引量
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        uint256 usdtAmount = 350000 ether; // *10
        // uint160 sqrtPriceLower = encodePriceSqrt(2, 1e5);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);

        // int24 tickLower = (TickMath.getTickAtSqrtPrice(sqrtPriceLower) /
        //     tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.getTickAtSqrtPrice(sqrtPriceUpper) /
            tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceUpper,
            type(uint128).max, // desiredDARAmount,
            usdtAmount
        );

        // make liquidity
        vm.startPrank(company);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity, // amount0
            type(uint256).max, // amount0Max
            usdtAmount, // amount1Max
            company,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();
        uint256 combalance0 = darMintAmount - tokenDAR.balanceOf(company);
        uint256 combalance1 = usdtMintAmount - tokenUSDT.balanceOf(company);
        console.log("poolDAR balance:", combalance0 / 1e18);
        console.log("poolUSDT balance:", combalance1 / 1e18);

        // 以下、swapシミュレーション
        int256 amountSpecified = 170000 ether; // 取引量：
        vm.startPrank(investor1);
        for (uint i = 0; i < 2; i++) {
            console.log("Swap", i + 1);
            // swap前の価格取得
            uint160 sqrtPriceBefore = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"前 1DAR =",
                toReadablePriceFixed(sqrtPriceBefore),
                "USDT"
            );

            // tokenDAR -> tokenUSDT のswapパラメータ設定
            bool zeroForOne = true; // tokenDAR -> tokenUSDT
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
            });
            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            // swap実行
            swapRouter.swap(customPool, params, testSettings, ZERO_BYTES);

            // swap後の価格取得
            uint160 sqrtPriceAfter = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"後 1DAR =",
                toReadablePriceFixed(sqrtPriceAfter),
                "USDT"
            );

            // 価格変動量（スリッページ）の計算とログ出力
            uint256 priceBefore = ((uint256(sqrtPriceBefore) *
                uint256(sqrtPriceBefore)) * 1e18) >> 192;
            uint256 priceAfter = ((uint256(sqrtPriceAfter) *
                uint256(sqrtPriceAfter)) * 1e18) >> 192;
            if (sqrtPriceAfter >= sqrtPriceBefore) {
                console.log(
                    unicode"価格上昇：",
                    priceAfter - priceBefore,
                    "USDT"
                );
            } else {
                console.log(
                    unicode"価格下降：",
                    priceBefore - priceAfter,
                    "USDT"
                );
            }

            console.log(unicode"取引量:", amountSpecified / 1 ether);

            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            uint256 balance0 = darMintAmount - tokenDAR.balanceOf(investor1);
            uint256 balance1 = tokenUSDT.balanceOf(investor1);
            console.log("investDAR: ", formatBalance(balance0, 18), "DAR");
            console.log("investUSDT: ", formatBalance(balance1, 18), "USDT");
        }
        vm.stopPrank();
    }

    // 価格レンジ下限０．００００２(1/10倍)、 上限０．０２（100倍）
    function testSim_3_70000USDT_sell() public {
        console.log("testSim_3_70000USDT_sell");
        tokenDAR.mint(investor1, darMintAmount);

        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(2, 1e4);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // swap取引量
        // int24 rawTickLower = TickMath.minUsableTick(tickSpacing);
        uint256 usdtAmount = 70000e18; // *10
        uint160 sqrtPriceLower = encodePriceSqrt(2, 1e5);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e2);

        int24 tickLower = (TickMath.getTickAtSqrtPrice(sqrtPriceLower) /
            tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.getTickAtSqrtPrice(sqrtPriceUpper) /
            tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            type(uint128).max, // desiredDARAmount,
            usdtAmount
        );

        // make liquidity
        vm.startPrank(company);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity, // amount0
            type(uint256).max, // amount0Max
            usdtAmount, // amount1Max
            company,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();
        uint256 combalance0 = darMintAmount - tokenDAR.balanceOf(company);
        uint256 combalance1 = usdtMintAmount - tokenUSDT.balanceOf(company);
        console.log("poolDAR balance:", combalance0 / 1e18);
        console.log("poolUSDT balance:", combalance1 / 1e18);

        // 以下、swapシミュレーション
        int256 amountSpecified = 34000 ether; // 取引量：
        vm.startPrank(investor1);
        for (uint i = 0; i < 2; i++) {
            console.log("Swap", i + 1);
            // swap前の価格取得
            uint160 sqrtPriceBefore = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"前 1DAR =",
                toReadablePriceFixed(sqrtPriceBefore),
                "USDT"
            );

            // tokenDAR -> tokenUSDT のswapパラメータ設定
            bool zeroForOne = true; // tokenDAR -> tokenUSDT
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
            });
            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            // swap実行
            swapRouter.swap(customPool, params, testSettings, ZERO_BYTES);

            // swap後の価格取得
            uint160 sqrtPriceAfter = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"後 1DAR =",
                toReadablePriceFixed(sqrtPriceAfter),
                "USDT"
            );

            // 価格変動量（スリッページ）の計算とログ出力
            uint256 priceBefore = ((uint256(sqrtPriceBefore) *
                uint256(sqrtPriceBefore)) * 1e18) >> 192;
            uint256 priceAfter = ((uint256(sqrtPriceAfter) *
                uint256(sqrtPriceAfter)) * 1e18) >> 192;
            if (sqrtPriceAfter >= sqrtPriceBefore) {
                console.log(
                    unicode"価格上昇：",
                    priceAfter - priceBefore,
                    "USDT"
                );
            } else {
                console.log(
                    unicode"価格下降：",
                    priceBefore - priceAfter,
                    "USDT"
                );
            }

            console.log(unicode"取引量:", amountSpecified / 1 ether);

            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            uint256 balance0 = darMintAmount - tokenDAR.balanceOf(investor1);
            uint256 balance1 = tokenUSDT.balanceOf(investor1);
            console.log("investDAR: ", formatBalance(balance0, 18), "DAR");
            console.log("investUSDT: ", formatBalance(balance1, 18), "USDT");
        }
        vm.stopPrank();
    }

    // 価格レンジ下限０．００００２(1/10倍)、 上限０．０２（100倍）
    function testSim_3_350000USDT_sell() public {
        console.log("testSim_3_350000USDT_sell");
        tokenDAR.mint(investor1, darMintAmount);

        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(2, 1e4);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // swap取引量
        // int24 rawTickLower = TickMath.minUsableTick(tickSpacing);
        uint256 usdtAmount = 350000e18; // *10
        uint160 sqrtPriceLower = encodePriceSqrt(2, 1e5);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e2);

        int24 tickLower = (TickMath.getTickAtSqrtPrice(sqrtPriceLower) /
            tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.getTickAtSqrtPrice(sqrtPriceUpper) /
            tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            type(uint128).max, // desiredDARAmount,
            usdtAmount
        );

        // make liquidity
        vm.startPrank(company);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity, // amount0
            type(uint256).max, // amount0Max
            usdtAmount, // amount1Max
            company,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();
        uint256 combalance0 = darMintAmount - tokenDAR.balanceOf(company);
        uint256 combalance1 = usdtMintAmount - tokenUSDT.balanceOf(company);
        console.log("poolDAR balance:", combalance0 / 1e18);
        console.log("poolUSDT balance:", combalance1 / 1e18);

        // 以下、swapシミュレーション
        int256 amountSpecified = 170000 ether; // 取引量：
        vm.startPrank(investor1);
        for (uint i = 0; i < 2; i++) {
            console.log("Swap", i + 1);
            // swap前の価格取得
            uint160 sqrtPriceBefore = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"前 1DAR =",
                toReadablePriceFixed(sqrtPriceBefore),
                "USDT"
            );

            // tokenDAR -> tokenUSDT のswapパラメータ設定
            bool zeroForOne = true; // tokenDAR -> tokenUSDT
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
            });
            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            // swap実行
            swapRouter.swap(customPool, params, testSettings, ZERO_BYTES);

            // swap後の価格取得
            uint160 sqrtPriceAfter = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"後 1DAR =",
                toReadablePriceFixed(sqrtPriceAfter),
                "USDT"
            );

            // 価格変動量（スリッページ）の計算とログ出力
            uint256 priceBefore = ((uint256(sqrtPriceBefore) *
                uint256(sqrtPriceBefore)) * 1e18) >> 192;
            uint256 priceAfter = ((uint256(sqrtPriceAfter) *
                uint256(sqrtPriceAfter)) * 1e18) >> 192;
            if (sqrtPriceAfter >= sqrtPriceBefore) {
                console.log(
                    unicode"価格上昇：",
                    priceAfter - priceBefore,
                    "USDT"
                );
            } else {
                console.log(
                    unicode"価格下降：",
                    priceBefore - priceAfter,
                    "USDT"
                );
            }

            console.log(unicode"取引量:", amountSpecified / 1 ether);

            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            uint256 balance0 = darMintAmount - tokenDAR.balanceOf(investor1);
            uint256 balance1 = tokenUSDT.balanceOf(investor1);
            console.log("investDAR: ", formatBalance(balance0, 18), "DAR");
            console.log("investUSDT: ", formatBalance(balance1, 18), "USDT");
        }
        vm.stopPrank();
    }

    // 価格レンジ下限０．００００２(1/10倍)、 上限０．０２（100倍）
    function testSim_3_7000USDT_sell() public {
        console.log("testSim_3_7000USDT_sell");
        tokenDAR.mint(investor1, darMintAmount);

        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(2, 1e4);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // swap取引量
        // int24 rawTickLower = TickMath.minUsableTick(tickSpacing);
        uint256 usdtAmount = 350000e18; // *10
        uint160 sqrtPriceLower = encodePriceSqrt(2, 1e5);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e2);

        int24 tickLower = (TickMath.getTickAtSqrtPrice(sqrtPriceLower) /
            tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.getTickAtSqrtPrice(sqrtPriceUpper) /
            tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            type(uint128).max, // desiredDARAmount,
            usdtAmount
        );

        // make liquidity
        vm.startPrank(company);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity, // amount0
            type(uint256).max, // amount0Max
            usdtAmount, // amount1Max
            company,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();
        uint256 combalance0 = darMintAmount - tokenDAR.balanceOf(company);
        uint256 combalance1 = usdtMintAmount - tokenUSDT.balanceOf(company);
        console.log("poolDAR balance:", combalance0 / 1e18);
        console.log("poolUSDT balance:", combalance1 / 1e18);

        // 以下、swapシミュレーション
        int256 amountSpecified = 3400 ether; // 取引量：
        vm.startPrank(investor1);
        for (uint i = 0; i < 2; i++) {
            console.log("Swap", i + 1);
            // swap前の価格取得
            uint160 sqrtPriceBefore = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"前 1DAR =",
                toReadablePriceFixed(sqrtPriceBefore),
                "USDT"
            );

            // tokenDAR -> tokenUSDT のswapパラメータ設定
            bool zeroForOne = true; // tokenDAR -> tokenUSDT
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
            });
            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            // swap実行
            swapRouter.swap(customPool, params, testSettings, ZERO_BYTES);

            // swap後の価格取得
            uint160 sqrtPriceAfter = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"後 1DAR =",
                toReadablePriceFixed(sqrtPriceAfter),
                "USDT"
            );

            // 価格変動量（スリッページ）の計算とログ出力
            uint256 priceBefore = ((uint256(sqrtPriceBefore) *
                uint256(sqrtPriceBefore)) * 1e18) >> 192;
            uint256 priceAfter = ((uint256(sqrtPriceAfter) *
                uint256(sqrtPriceAfter)) * 1e18) >> 192;
            if (sqrtPriceAfter >= sqrtPriceBefore) {
                console.log(
                    unicode"価格上昇：",
                    priceAfter - priceBefore,
                    "USDT"
                );
            } else {
                console.log(
                    unicode"価格下降：",
                    priceBefore - priceAfter,
                    "USDT"
                );
            }

            console.log(unicode"取引量:", amountSpecified / 1 ether);

            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            uint256 balance0 = darMintAmount - tokenDAR.balanceOf(investor1);
            uint256 balance1 = tokenUSDT.balanceOf(investor1);
            console.log("investDAR: ", formatBalance(balance0, 18), "DAR");
            console.log("investUSDT: ", formatBalance(balance1, 18), "USDT");
        }
        vm.stopPrank();
    }

    // 価格レンジ下限０．００００２(1/10倍)、 上限０．０２（100倍）
    function testSim_3_70000USDT_buy() public {
        console.log("testSim_3_70000USDT_buy");
        tokenUSDT.mint(investor1, usdtMintAmount);

        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(2, 1e4);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // swap取引量
        // int24 rawTickLower = TickMath.minUsableTick(tickSpacing);
        uint256 usdtAmount = 70000e18; // *10
        uint160 sqrtPriceLower = encodePriceSqrt(2, 1e5);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e2);

        int24 tickLower = (TickMath.getTickAtSqrtPrice(sqrtPriceLower) /
            tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.getTickAtSqrtPrice(sqrtPriceUpper) /
            tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            type(uint128).max, // desiredDARAmount,
            usdtAmount
        );

        // make liquidity
        vm.startPrank(company);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity, // amount0
            type(uint256).max, // amount0Max
            usdtAmount, // amount1Max
            company,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();
        uint256 poolbalance0 = darMintAmount - tokenDAR.balanceOf(company);
        uint256 poolbalance1 = usdtMintAmount - tokenUSDT.balanceOf(company);
        console.log("poolDAR balance:", poolbalance0 / 1e18);
        console.log("poolUSDT balance:", poolbalance1 / 1e18);

        // 以下、swapシミュレーション
        int256 amountSpecified = int256(((poolbalance0 * 10) / 21) / 10); // 取引量：
        vm.startPrank(investor1);
        for (uint i = 0; i < 2; i++) {
            console.log("Swap", i + 1);
            // swap前の価格取得
            uint160 sqrtPriceBefore = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"前 1DAR =",
                toReadablePriceFixed(sqrtPriceBefore),
                "USDT"
            );

            // tokenDAR -> tokenUSDT のswapパラメータ設定
            bool zeroForOne = false; // tokenUSDT -> tokenDAR
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
            });
            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            // swap実行
            swapRouter.swap(customPool, params, testSettings, ZERO_BYTES);

            // swap後の価格取得
            uint160 sqrtPriceAfter = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"後 1DAR =",
                toReadablePriceFixed(sqrtPriceAfter),
                "USDT"
            );

            // 価格変動量（スリッページ）の計算とログ出力
            uint256 priceBefore = ((uint256(sqrtPriceBefore) *
                uint256(sqrtPriceBefore)) * 1e18) >> 192;
            uint256 priceAfter = ((uint256(sqrtPriceAfter) *
                uint256(sqrtPriceAfter)) * 1e18) >> 192;
            if (sqrtPriceAfter >= sqrtPriceBefore) {
                console.log(
                    unicode"価格上昇：",
                    priceAfter - priceBefore,
                    "USDT"
                );
            } else {
                console.log(
                    unicode"価格下降：",
                    priceBefore - priceAfter,
                    "USDT"
                );
            }

            console.log(unicode"取引量:", amountSpecified / 1 ether);

            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            uint256 balance0 = tokenDAR.balanceOf(investor1);
            uint256 balance1 = usdtMintAmount - tokenUSDT.balanceOf(investor1);
            console.log("investDAR: ", balance0, "DAR");
            console.log("investUSDT: ", balance1, "USDT");
            // console.log("investDAR: ", formatBalance(balance0, 18), "DAR");
            // console.log("investUSDT: ", formatBalance(balance1, 18), "USDT");
        }
        vm.stopPrank();
    }

    // 価格レンジ下限０．００００２(1/10倍)、 上限０．０２（100倍）
    function testSim_3_350000USDT_buy() public {
        console.log("testSim_3_350000USDT_sell");
        tokenDAR.mint(investor1, darMintAmount);

        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(2, 1e4);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // swap取引量
        // int24 rawTickLower = TickMath.minUsableTick(tickSpacing);
        uint256 usdtAmount = 350000e18; // *10
        uint160 sqrtPriceLower = encodePriceSqrt(2, 1e5);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e2);

        int24 tickLower = (TickMath.getTickAtSqrtPrice(sqrtPriceLower) /
            tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.getTickAtSqrtPrice(sqrtPriceUpper) /
            tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            type(uint128).max, // desiredDARAmount,
            usdtAmount
        );

        // make liquidity
        vm.startPrank(company);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity, // amount0
            type(uint256).max, // amount0Max
            usdtAmount, // amount1Max
            company,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();
        uint256 combalance0 = darMintAmount - tokenDAR.balanceOf(company);
        uint256 combalance1 = usdtMintAmount - tokenUSDT.balanceOf(company);
        console.log("poolDAR balance:", combalance0 / 1e18);
        console.log("poolUSDT balance:", combalance1 / 1e18);

        // 以下、swapシミュレーション
        int256 amountSpecified = 170000 ether; // 取引量：
        vm.startPrank(investor1);
        for (uint i = 0; i < 2; i++) {
            console.log("Swap", i + 1);
            // swap前の価格取得
            uint160 sqrtPriceBefore = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"前 1DAR =",
                toReadablePriceFixed(sqrtPriceBefore),
                "USDT"
            );

            // tokenDAR -> tokenUSDT のswapパラメータ設定
            bool zeroForOne = true; // tokenDAR -> tokenUSDT
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
            });
            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            // swap実行
            swapRouter.swap(customPool, params, testSettings, ZERO_BYTES);

            // swap後の価格取得
            uint160 sqrtPriceAfter = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"後 1DAR =",
                toReadablePriceFixed(sqrtPriceAfter),
                "USDT"
            );

            // 価格変動量（スリッページ）の計算とログ出力
            uint256 priceBefore = ((uint256(sqrtPriceBefore) *
                uint256(sqrtPriceBefore)) * 1e18) >> 192;
            uint256 priceAfter = ((uint256(sqrtPriceAfter) *
                uint256(sqrtPriceAfter)) * 1e18) >> 192;
            if (sqrtPriceAfter >= sqrtPriceBefore) {
                console.log(
                    unicode"価格上昇：",
                    priceAfter - priceBefore,
                    "USDT"
                );
            } else {
                console.log(
                    unicode"価格下降：",
                    priceBefore - priceAfter,
                    "USDT"
                );
            }

            console.log(unicode"取引量:", amountSpecified / 1 ether);

            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            uint256 balance0 = darMintAmount - tokenDAR.balanceOf(investor1);
            uint256 balance1 = tokenUSDT.balanceOf(investor1);
            console.log("investDAR: ", formatBalance(balance0, 18), "DAR");
            console.log("investUSDT: ", formatBalance(balance1, 18), "USDT");
        }
        vm.stopPrank();
    }

    // 価格レンジ下限０．００００２(1/10倍)、 上限０．０２（100倍）
    function testSim_3_7000USDT_buy() public {
        console.log("testSim_3_7000USDT_sell");
        tokenDAR.mint(investor1, darMintAmount);

        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(2, 1e4);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // swap取引量
        // int24 rawTickLower = TickMath.minUsableTick(tickSpacing);
        uint256 usdtAmount = 350000e18; // *10
        uint160 sqrtPriceLower = encodePriceSqrt(2, 1e5);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e2);

        int24 tickLower = (TickMath.getTickAtSqrtPrice(sqrtPriceLower) /
            tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.getTickAtSqrtPrice(sqrtPriceUpper) /
            tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            type(uint128).max, // desiredDARAmount,
            usdtAmount
        );

        // make liquidity
        vm.startPrank(company);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity, // amount0
            type(uint256).max, // amount0Max
            usdtAmount, // amount1Max
            company,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();
        uint256 combalance0 = darMintAmount - tokenDAR.balanceOf(company);
        uint256 combalance1 = usdtMintAmount - tokenUSDT.balanceOf(company);
        console.log("poolDAR balance:", combalance0 / 1e18);
        console.log("poolUSDT balance:", combalance1 / 1e18);

        // 以下、swapシミュレーション
        int256 amountSpecified = 3400 ether; // 取引量：
        vm.startPrank(investor1);
        for (uint i = 0; i < 2; i++) {
            console.log("Swap", i + 1);
            // swap前の価格取得
            uint160 sqrtPriceBefore = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"前 1DAR =",
                toReadablePriceFixed(sqrtPriceBefore),
                "USDT"
            );

            // tokenDAR -> tokenUSDT のswapパラメータ設定
            bool zeroForOne = true; // tokenDAR -> tokenUSDT
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
            });
            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            // swap実行
            swapRouter.swap(customPool, params, testSettings, ZERO_BYTES);

            // swap後の価格取得
            uint160 sqrtPriceAfter = getCurrentSqrtPrice(customPool);
            console.log(
                unicode"後 1DAR =",
                toReadablePriceFixed(sqrtPriceAfter),
                "USDT"
            );

            // 価格変動量（スリッページ）の計算とログ出力
            uint256 priceBefore = ((uint256(sqrtPriceBefore) *
                uint256(sqrtPriceBefore)) * 1e18) >> 192;
            uint256 priceAfter = ((uint256(sqrtPriceAfter) *
                uint256(sqrtPriceAfter)) * 1e18) >> 192;
            if (sqrtPriceAfter >= sqrtPriceBefore) {
                console.log(
                    unicode"価格上昇：",
                    priceAfter - priceBefore,
                    "USDT"
                );
            } else {
                console.log(
                    unicode"価格下降：",
                    priceBefore - priceAfter,
                    "USDT"
                );
            }

            console.log(unicode"取引量:", amountSpecified / 1 ether);

            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            uint256 balance0 = darMintAmount - tokenDAR.balanceOf(investor1);
            uint256 balance1 = tokenUSDT.balanceOf(investor1);
            console.log("investDAR: ", formatBalance(balance0, 18), "DAR");
            console.log("investUSDT: ", formatBalance(balance1, 18), "USDT");
        }
        vm.stopPrank();
    }

    // グラフ作成用レンジ下限シミュ
    // パターン1
    // 下限無し
    function testSim_lower1() public {
        console.log(unicode"testSim_lower, 下限なし");
        tokenDAR.mint(investor1, darMintAmount);

        // swap取引量
        uint256 usdtAmount = 70000e18; // *10
        uint160 sqrtPriceLower = 0;
        // uint160 sqrtPriceLower = encodePriceSqrt(2, 1e3);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);
        int256 swapAmount = 6950 ether;

        bool zeroForOne = true; // tokenDAR -> tokenUSDT
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン2
    // 下限0.0001(1/2倍)
    function testSim_lower2() public {
        console.log(unicode"testSim_lower, 下限0.0001(1/2倍)");
        tokenDAR.mint(investor1, darMintAmount);

        // swap取引量
        uint256 usdtAmount = 70000e18; // *10
        // 下限
        uint160 sqrtPriceLower = encodePriceSqrt(1, 1e4);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);
        int256 swapAmount = 6950 ether;

        bool zeroForOne = true; // tokenDAR -> tokenUSDT
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン3
    // 下限0.00004 (1/5と表記) => 実際は 1/25,000 = 0.00004
    function testSim_lower3() public {
        console.log(unicode"testSim_lower3, 下限0.00004(1/5)");
        tokenDAR.mint(investor1, darMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 25000); // 1/25000 => 0.00004
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);
        int256 swapAmount = 6950 ether;

        bool zeroForOne = true;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン4
    // 下限0.00002 (1/10と表記) => 1/50,000 = 0.00002
    function testSim_lower4() public {
        console.log(unicode"testSim_lower4, 下限0.00002(1/10)");
        tokenDAR.mint(investor1, darMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 50000); // 1/50000 => 0.00002
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);
        int256 swapAmount = 6950 ether;

        bool zeroForOne = true;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン5
    // 下限0.000008 (1/25) => 1/125,000 = 0.000008
    function testSim_lower5() public {
        console.log(unicode"testSim_lower5, 下限0.000008(1/25)");
        tokenDAR.mint(investor1, darMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 125000); // 1/125000 => 0.000008
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);
        int256 swapAmount = 6950 ether;

        bool zeroForOne = true;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン6
    // 下限0.000004 (1/50) => 1/250,000 = 0.000004
    function testSim_lower6() public {
        console.log(unicode"testSim_lower6, 下限0.000004(1/50)");
        tokenDAR.mint(investor1, darMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 250000); // 1/250000 => 0.000004
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);
        int256 swapAmount = 6950 ether;

        bool zeroForOne = true;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン7
    // 下限0.000002 (1/100) => 1/500,000 = 0.000002
    function testSim_lower7() public {
        console.log(unicode"testSim_lower7, 下限0.000002(1/100)");
        tokenDAR.mint(investor1, darMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 500000); // 1/500000 => 0.000002
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);
        int256 swapAmount = 6950 ether;

        bool zeroForOne = true;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン1
    // 上限なし
    function testSim_Upper1() public {
        console.log(unicode"testSim_Upper1, 上限なし");
        tokenUSDT.mint(investor1, usdtMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 50000); // 1/50000 => 0.00002
        // uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);
        uint160 sqrtPriceUpper = 0;
        int256 swapAmount = 112; // =11.2

        bool zeroForOne = false;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン2
    // 上限0.0004(2倍)
    function testSim_Upper2() public {
        console.log(unicode"testSim_Upper2, 上限0.0004(2倍)");
        tokenUSDT.mint(investor1, usdtMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 50000); // 1/50000 => 0.00002
        uint160 sqrtPriceUpper = encodePriceSqrt(4, 1e4);
        int256 swapAmount = 112; // =11.2

        bool zeroForOne = false;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン3
    // 上限0.001 (5倍)
    function testSim_Upper3() public {
        console.log(unicode"testSim_Upper3, 上限0.001(5倍)");
        tokenUSDT.mint(investor1, usdtMintAmount);

        uint256 usdtAmount = 70000e18;
        // 例）下限は同じ 1/50000 => 0.00002
        uint160 sqrtPriceLower = encodePriceSqrt(1, 50000);
        // 上限0.001 => 1 / 1000
        uint160 sqrtPriceUpper = encodePriceSqrt(1, 1e3);
        int256 swapAmount = 112; // 適宜同じか変更する

        bool zeroForOne = false;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン4
    // 上限0.002 (10倍)
    function testSim_Upper4() public {
        console.log(unicode"testSim_Upper4, 上限0.002(10倍)");
        tokenUSDT.mint(investor1, usdtMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 50000); // 下限例
        // 上限0.002 => 2 / 1000
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);
        int256 swapAmount = 112; // 同じ 11.2

        bool zeroForOne = false;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン5
    // 上限0.005 (25倍)
    function testSim_Upper5() public {
        console.log(unicode"testSim_Upper5, 上限0.005(25倍)");
        tokenUSDT.mint(investor1, usdtMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 50000);
        // 上限0.005 => 5 / 1000
        uint160 sqrtPriceUpper = encodePriceSqrt(5, 1e3);
        int256 swapAmount = 112;

        bool zeroForOne = false;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン6
    // 上限0.01 (50倍)
    function testSim_Upper6() public {
        console.log(unicode"testSim_Upper6, 上限0.01(50倍)");
        tokenUSDT.mint(investor1, usdtMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 50000);
        // 上限0.01 => 1 / 100
        uint160 sqrtPriceUpper = encodePriceSqrt(1, 1e2);
        int256 swapAmount = 112;

        bool zeroForOne = false;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // パターン7
    // 上限0.02 (100倍)
    function testSim_Upper7() public {
        console.log(unicode"testSim_Upper7, 上限0.02(100倍)");
        tokenUSDT.mint(investor1, usdtMintAmount);

        uint256 usdtAmount = 70000e18;
        uint160 sqrtPriceLower = encodePriceSqrt(1, 50000);
        // 上限0.02 => 2 / 100
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e2);
        int256 swapAmount = 112;

        bool zeroForOne = false;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        _simulate(usdtAmount, sqrtPriceLower, sqrtPriceUpper, params);
    }

    // シミュレート
    function _simulate(
        uint256 _usdtAmount,
        uint160 _sqrtPriceLower,
        uint160 _sqrtPriceUpper,
        IPoolManager.SwapParams memory _params
    ) public {
        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(2, 1e4);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // swap取引量
        uint256 usdtAmount = _usdtAmount; // *10
        uint160 sqrtPriceLower = _sqrtPriceLower;
        uint160 sqrtPriceUpper = _sqrtPriceUpper;
        (int24 tickLower, int24 tickUpper) = getTick(
            sqrtPriceLower,
            sqrtPriceUpper
        );

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            type(uint128).max, // desiredDARAmount,
            usdtAmount
        );

        // make liquidity
        vm.startPrank(company);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity, // amount0
            type(uint256).max, // amount0Max
            type(uint256).max, // amount1Max
            company,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();
        uint256 poolDARbalance = tokenDAR.balanceOf(address(manager));
        uint256 poolUSDTbalance = tokenUSDT.balanceOf(address(manager));
        console.log("poolDAR balance:", poolDARbalance / 1e18);
        console.log("poolUSDT balance:", poolUSDTbalance / 1e18);
        // tokenDAR -> tokenUSDT のswapパラメータ設定
        IPoolManager.SwapParams memory params = _params;
        if (!_params.zeroForOne) {
            params.amountSpecified = int256(
                ((int256(poolDARbalance) * 10) / _params.amountSpecified)
            );
        }

        // 以下、swapシミュレーション
        vm.startPrank(investor1);
        for (uint i = 0; i < 10; i++) {
            // console.log("Swap", i + 1);
            // swap前の価格取得
            uint160 sqrtPriceBefore = getCurrentSqrtPrice(customPool);

            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            // swap実行
            swapRouter.swap(customPool, params, testSettings, ZERO_BYTES);

            // swap後の価格取得
            uint160 sqrtPriceAfter = getCurrentSqrtPrice(customPool);

            // 価格変動量（スリッページ）の計算とログ出力
            uint256 priceBefore = ((uint256(sqrtPriceBefore) *
                uint256(sqrtPriceBefore)) * 1e18) >> 192;
            uint256 priceAfter = ((uint256(sqrtPriceAfter) *
                uint256(sqrtPriceAfter)) * 1e18) >> 192;
            uint256 calcPrice;
            if (sqrtPriceAfter >= sqrtPriceBefore) {
                calcPrice = priceAfter - priceBefore;
            } else {
                calcPrice = priceBefore - priceAfter;
            }

            uint256 balance0;
            uint256 balance1;
            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            if (params.zeroForOne) {
                balance0 = darMintAmount - tokenDAR.balanceOf(investor1);
                balance1 = tokenUSDT.balanceOf(investor1);
            } else {
                balance0 = tokenDAR.balanceOf(investor1);
                balance1 = usdtMintAmount - tokenUSDT.balanceOf(investor1);
            }

            string memory amountStr = vm.toString(
                params.amountSpecified / 1 ether
            );
            string memory logLine = string(
                abi.encodePacked(
                    // swap回数
                    vm.toString(i + 1),
                    ",",
                    // 取引量
                    amountStr,
                    ",",
                    // swap前価格(USDT)
                    toReadablePriceFixed(sqrtPriceBefore),
                    ",",
                    // swap後価格(USDT)
                    toReadablePriceFixed(sqrtPriceAfter),
                    ",",
                    // 価格変動量(USDT)
                    vm.toString(calcPrice),
                    ",",
                    // ユーザがUSDTを得るのに使用したDAR量
                    formatBalance(balance0, 18),
                    ",",
                    // ユーザがUSDTを得る量
                    formatBalance(balance1, 18)
                )
            );
            console.log(logLine);
        }
        vm.stopPrank();
    }

    function deployPoolManager() internal returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(0))));
    }

    function deployRouters(
        IPoolManager manager
    )
        internal
        returns (
            PoolModifyLiquidityTest lpRouter,
            PoolSwapTest swapRouter,
            PoolDonateTest donateRouter
        )
    {
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        donateRouter = new PoolDonateTest(manager);
    }

    function deployPosm(
        IPoolManager poolManager
    ) public returns (IPositionManager) {
        DeployPermit2.anvilPermit2();
        return
            IPositionManager(
                new PositionManager(
                    poolManager,
                    permit2,
                    300_000,
                    IPositionDescriptor(address(0)),
                    IWETH9(address(0))
                )
            );
    }

    function approvePosmCurrency(
        IPositionManager posm,
        Currency currency
    ) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(
            address(permit2),
            type(uint256).max
        );
        // 2. Then, the caller must approve POSM as a spender of permit2
        permit2.approve(
            Currency.unwrap(currency),
            address(posm),
            type(uint160).max,
            type(uint48).max
        );
    }

    function deployTokens()
        internal
        returns (MockERC20 tokenDAR, MockERC20 tokenUSDT)
    {
        MockERC20 tokenA = new MockERC20("MockA", "A", 18);
        MockERC20 tokenB = new MockERC20("MockB", "B", 18);
        if (uint160(address(tokenA)) < uint160(address(tokenB))) {
            tokenDAR = tokenA;
            tokenUSDT = tokenB;
        } else {
            tokenDAR = tokenB;
            tokenUSDT = tokenA;
        }
    }

    function getCurrentSqrtPrice(
        PoolKey memory _poolkey
    ) internal view returns (uint160) {
        // return PoolManager(address(manager)).getSqrtPriceX96(_poolkey.toId());
        (
            uint160 sqrtPriceX96,
            int24 tick,
            uint24 protocolFee,
            uint24 lpFee
        ) = StateLibrary.getSlot0(manager, _poolkey.toId());
        return sqrtPriceX96;
    }

    function toReadablePriceFixed(
        uint160 sqrtPriceX96
    ) internal pure returns (string memory) {
        uint256 price = ((uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) *
            1e18) >> 192;

        string memory priceStr = uint2str(price);
        return priceStr;
        bytes memory priceBytes = bytes(priceStr);

        if (priceBytes.length <= 5) {
            // 5桁以下なら "0.00XXX" 形式
            string memory padded = priceStr;
            for (uint i = 0; i < 5 - priceBytes.length; i++) {
                padded = string(abi.encodePacked("0", padded));
            }
            return string(abi.encodePacked("0.000", padded));
        } else {
            return
                string(
                    abi.encodePacked(
                        "0.000",
                        substring(priceStr, 0, 3),
                        "...",
                        substring(priceStr, priceBytes.length - 2, 2)
                    )
                );
        }
    }

    function substring(
        string memory str,
        uint startIndex,
        uint length
    ) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(length);
        for (uint i = 0; i < length; i++) {
            if (startIndex + i < strBytes.length) {
                result[i] = strBytes[startIndex + i];
            }
        }
        return string(result);
    }

    function formatBalance(
        uint256 balance,
        uint8 decimals
    ) internal pure returns (string memory) {
        uint256 whole = balance / (10 ** decimals);
        uint256 fraction = (balance % (10 ** decimals)) /
            (10 ** (decimals - 6)); // 小数点以下6桁まで表示

        // 小数部を6桁にゼロ埋め
        string memory fractionStr = uint2str(fraction);
        uint256 fractionLen = bytes(fractionStr).length;
        for (uint i = 0; i < 6 - fractionLen; i++) {
            fractionStr = string(abi.encodePacked("0", fractionStr));
        }

        return string(abi.encodePacked(uint2str(whole), ".", fractionStr));
    }

    function formatPriceDiff(
        uint256 diff
    ) internal pure returns (string memory) {
        if (diff < 1e12) {
            return string(abi.encodePacked("0.0000000", uint2str(diff / 1e5)));
        } else if (diff < 1e13) {
            return string(abi.encodePacked("0.000000", uint2str(diff / 1e5)));
        } else {
            return string(abi.encodePacked("0.00000", uint2str(diff / 1e7)));
        }
    }

    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = uint8(48 + (_i % 10));
            bstr[k] = bytes1(temp);
            _i /= 10;
        }
        return string(bstr);
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function encodePriceSqrt(
        uint256 amount1,
        uint256 amount0
    ) internal pure returns (uint160) {
        // 計算式: sqrtPriceX96 = sqrt((amount1 << 192) / amount0)
        uint256 ratio = (amount1 << 192) / amount0;
        return uint160(sqrt(ratio));
    }

    // Q18 表現の価格差を人間向けの文字列 (小数部3桁)
    // 例: 2e15 → 0.002
    function toReadableDiff(
        uint256 value
    ) internal pure returns (string memory) {
        // 整数部（1:1 の場合は 1）
        uint256 whole = value / 1e18;
        // 小数部（小数点以下3桁表示、1e15 = 0.001）
        uint256 fraction = (value % 1e18) / 1e15;

        // ゼロパディング（fraction を常に3桁の文字列にする）
        string memory fractionStr;
        if (fraction < 10) {
            fractionStr = string(abi.encodePacked("00", uint2str(fraction)));
        } else if (fraction < 100) {
            fractionStr = string(abi.encodePacked("0", uint2str(fraction)));
        } else {
            fractionStr = uint2str(fraction);
        }

        return string(abi.encodePacked(uint2str(whole), ".", fractionStr));
    }

    uint256 constant SCALE = 1e11;
    uint256 constant SLIPPAGE_DOWN = 94868329805; // ≈ sqrt(0.9)
    uint256 constant SLIPPAGE_UP = 104880884817; // ≈ sqrt(1.1)

    function computeTickRange(
        uint160 currentSqrtPriceX96,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        uint160 sqrtPriceLower = uint160(
            (uint256(currentSqrtPriceX96) * SLIPPAGE_DOWN) / SCALE
        );
        uint160 sqrtPriceUpper = uint160(
            (uint256(currentSqrtPriceX96) * SLIPPAGE_UP) / SCALE
        );

        tickLower =
            (TickMath.getTickAtSqrtPrice(sqrtPriceLower) / tickSpacing) *
            tickSpacing;
        tickUpper =
            (TickMath.getTickAtSqrtPrice(sqrtPriceUpper) / tickSpacing) *
            tickSpacing;
    }

    // ticklower, tickupperを返す関数
    function getTick(
        uint160 lower,
        uint160 upper
    ) internal view returns (int24, int24) {
        int24 tickLower;
        int24 tickUpper;

        if (lower == 0) {
            tickLower = TickMath.minUsableTick(tickSpacing);
        } else {
            tickLower =
                (TickMath.getTickAtSqrtPrice(lower) / tickSpacing) *
                tickSpacing;
        }

        if (upper == 0) {
            tickUpper = TickMath.maxUsableTick(tickSpacing);
        } else {
            tickUpper =
                (TickMath.getTickAtSqrtPrice(upper) / tickSpacing) *
                tickSpacing;
        }
        return (tickLower, tickUpper);
    }
}
