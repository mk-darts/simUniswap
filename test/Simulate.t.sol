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

contract SimulateTest is Test, DeployPermit2 {
    using EasyPosm for IPositionManager;

    IPoolManager manager;
    IPositionManager posm;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    MockERC20 tokenDAR; // DAR
    MockERC20 tokenUSDT; // USDT
    PoolKey poolKey;

    Counter hook;

    int24 tickSpacing;

    bytes ZERO_BYTES = new bytes(0);

    address company = makeAddr("company");
    address investor1 = makeAddr("investor1");

    function setUp() public {
        // foundry.toml で指定した eth_rpc_url を使ってフォークを作成
        // string memory rpcUrl = vm.rpcUrl("anvil");
        // vm.createSelectFork(rpcUrl);

        manager = deployPoolManager();
        ZERO_BYTES = new bytes(0);

        // hook contracts must have specific flags encoded in the address
        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("Counter.sol:Counter", constructorArgs, flags);
        hook = Counter(flags);

        posm = deployPosm(manager);
        (lpRouter, swapRouter, ) = deployRouters(manager);

        // 設定mint
        vm.startPrank(company);
        (tokenDAR, tokenUSDT) = deployTokens();
        tokenDAR.mint(company, 100_000_000 ether);
        tokenUSDT.mint(company, 100_000_000 ether);
        tokenDAR.mint(investor1, 100_000_000 ether);
        vm.stopPrank();

        tickSpacing = 60;
        // approve the tokens to the routers
        vm.startPrank(company);
        tokenDAR.approve(address(lpRouter), type(uint256).max);
        tokenUSDT.approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(investor1);
        tokenDAR.approve(address(swapRouter), type(uint256).max);
        tokenUSDT.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(company);
        approvePosmCurrency(posm, Currency.wrap(address(tokenDAR)));
        approvePosmCurrency(posm, Currency.wrap(address(tokenUSDT)));
        vm.stopPrank();
    }

    function testCreatePoolNoHookCustomRange() public {
        // プールキーを作成 (フックはなし)
        // 設定pool
        vm.startPrank(company);
        PoolKey memory customPool = PoolKey({
            currency0: Currency.wrap(address(tokenDAR)),
            currency1: Currency.wrap(address(tokenUSDT)),
            fee: 3000, // 0.3%
            // fee: 100000, // 10%
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        // // 初期価格 (1 tokenDARあたり0.1 tokenUSDT)
        // // おおよそ sqrt(0.1)×2^96
        // uint160 sqrtPriceX96 = 25000000000000000000000000000;

        // 1 tokenDAR あたり 0.1 tokenUSDT の場合、amount1 = 1 and amount0 = 10 を指定 (整数表現)
        uint160 sqrtPriceX96 = encodePriceSqrt(1978, 1e7);

        // プールを初期化
        manager.initialize(customPool, sqrtPriceX96);

        // 価格レンジ下限 (約0.05) と 価格上限 (1)
        // １
        int24 rawTickLower = TickMath.minUsableTick(tickSpacing);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 100);
        int24 rawTickUpper = TickMath.getTickAtSqrtPrice(sqrtPriceUpper);
        uint256 darAmount = type(uint128).max;
        uint256 usdtAmount = 70000e18;

        int24 tickLower = (rawTickLower / 60) * 60;
        int24 tickUpper = (rawTickUpper / 60) * 60;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            usdtAmount
        );

        // 1000tokenDARぶんを入金 (tokenUSDTは自動計算される想定)
        // 設定deposit
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

        // 以下、swapシミュレーション
        vm.startPrank(investor1);
        for (uint i = 0; i < 5; i++) {
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
            int256 amountSpecified = 10 ether; // 取引量：
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? (sqrtPriceBefore * 90) / 100
                    : (sqrtPriceBefore * 110) / 100
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
                console.log(unicode"で価格上昇：", formatPriceDiff(priceAfter - priceBefore), "USDT");
            } else {
                console.log(unicode"で価格下降：", formatPriceDiff(priceBefore - priceAfter), "USDT");
            }

            console.log(unicode"取引量:", amountSpecified / 1 ether);

            // swap後のtokenDAR, tokenUSDTのバランスをログ出力
            uint256 balance0 = tokenDAR.balanceOf(investor1);
            uint256 balance1 = tokenUSDT.balanceOf(investor1);
            console.log("DAR balance: ", formatBalance(balance0, 18), "DAR");
            console.log("USDT balance: ", formatBalance(balance1, 18), "USDT");
        }
        vm.stopPrank();
        uint256 combalance0 = 100_000_000 ether - tokenDAR.balanceOf(company);
        uint256 combalance1 = 100_000_000 ether - tokenUSDT.balanceOf(company);
        console.log("companyDAR balance:", combalance0 / 1e18);
        console.log("companyUSDT balance:", combalance1 / 1e18);
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

    function toReadablePriceFixed(uint160 sqrtPriceX96) internal pure returns (string memory) {
        uint256 price = ((uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) * 1e18) >> 192;

        string memory priceStr = uint2str(price);
        bytes memory priceBytes = bytes(priceStr);

        if (priceBytes.length <= 5) {
            // 5桁以下なら "0.00XXX" 形式
            string memory padded = priceStr;
            for (uint i = 0; i < 5 - priceBytes.length; i++) {
                padded = string(abi.encodePacked("0", padded));
            }
            return string(abi.encodePacked("0.000", padded));
        } else {
            return string(abi.encodePacked(
                "0.000",
                substring(priceStr, 0, 3),
                "...",
                substring(priceStr, priceBytes.length - 2, 2)
            ));
        }
    }

    function substring(string memory str, uint startIndex, uint length) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(length);
        for (uint i = 0; i < length; i++) {
            if (startIndex + i < strBytes.length) {
                result[i] = strBytes[startIndex + i];
            }
        }
        return string(result);
    }

    function formatBalance(uint256 balance, uint8 decimals) internal pure returns (string memory) {
        uint256 whole = balance / (10**decimals);
        uint256 fraction = (balance % (10**decimals)) / (10**(decimals-6)); // 小数点以下6桁まで表示

        // 小数部を6桁にゼロ埋め
        string memory fractionStr = uint2str(fraction);
        uint256 fractionLen = bytes(fractionStr).length;
        for (uint i = 0; i < 6 - fractionLen; i++) {
            fractionStr = string(abi.encodePacked("0", fractionStr));
        }

        return string(abi.encodePacked(uint2str(whole), ".", fractionStr));
    }

    function formatPriceDiff(uint256 diff) internal pure returns (string memory) {
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
}
