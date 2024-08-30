// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DSCEngineTest is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address ethPriceFeed;
    address weth;
    address wbtcPriceFeed;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    ////Events/////
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    function setUp() external {
        DeployDSC deployDsc = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployDsc.run();
        (ethPriceFeed, wbtcPriceFeed, weth, wbtc, ) = helperConfig
            .activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(
            LIQUIDATOR,
            STARTING_ERC20_BALANCE + STARTING_ERC20_BALANCE
        );
    }

    //////////////////////
    // Constructor Test //
    //////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wbtcPriceFeed);
        priceFeedAddresses.push(wbtcPriceFeed);
        vm.expectRevert(
            DSCEngine
                .DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////
    // Price Test       //
    //////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    /////////////////////////////////
    // DepositCollateral Test       //
    /////////////////////////////////
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN");
        vm.prank(USER); //DSCEngine_NotAllowedToken
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine
            .getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositedAmount = dscEngine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositedAmount);
    }

    function testDepositCollateralTransferAndEmitCollateralDepositedEvent()
        public
    {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectEmit(true, false, true, false);
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 userBalance = 0;
        assertEq(
            ERC20Mock(weth).balanceOf(address(dscEngine)),
            AMOUNT_COLLATERAL
        );
        assertEq(ERC20Mock(weth).balanceOf(USER), userBalance);
    }

    function testRevertIfMintDscZero() public depositedCollateral {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
    }

    function testRevertIfHealthFactorBroken() public depositedCollateral {
        uint256 healthFator = dscEngine.calculateHealthFactor(
            20000e18,
            dscEngine.getAccountCollateralValue(USER)
        );
        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine_BreakHealthFactor.selector,
                healthFator
            )
        );
        dscEngine.mintDsc(20000e18);
    }

    function testMintDsc() public depositedCollateral {
        uint256 mintedDsc = 10000e18;
        uint256 beforDscBalance = IERC20(dsc).balanceOf(USER);
        vm.startPrank(USER);
        dscEngine.mintDsc(mintedDsc);
        uint256 afterDscBalance = IERC20(dsc).balanceOf(USER);
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        assert(healthFactor >= dscEngine.getMinHealthFactor());
        assertEq(
            ERC20Mock(weth).balanceOf(address(dscEngine)),
            AMOUNT_COLLATERAL
        );
        assertEq(dscEngine.getMintedDsc(USER), mintedDsc);
        assertEq(beforDscBalance + mintedDsc, afterDscBalance);
    }

    function testBurnDsc() public depositedCollateral {
        uint256 burnAmount = 100e18;
        uint256 mintedDsc = 10000e18;
        vm.startPrank(USER);
        dscEngine.mintDsc(mintedDsc);
        uint256 beforeUserDscBalance = IERC20(dsc).balanceOf(USER);
        uint256 beforeEngineDscBalance = IERC20(dsc).balanceOf(
            address(dscEngine)
        );
        dsc.approve(address(dscEngine), burnAmount);
        dscEngine.burnDsc(burnAmount);
        vm.stopPrank();
        uint256 afterBurnUserDscBalance = IERC20(dsc).balanceOf(USER);
        uint256 afterBurnEngineDscBalance = IERC20(dsc).balanceOf(
            address(dscEngine)
        );

        assertEq(beforeUserDscBalance, afterBurnUserDscBalance + burnAmount);
        assertEq(beforeEngineDscBalance, afterBurnEngineDscBalance);
    }

    function testRedeemCollateral() public depositedCollateral {
        vm.prank(USER);
        dscEngine.mintDsc(AMOUNT_COLLATERAL);
        uint256 redeemWethBefore = ERC20Mock(weth).balanceOf(USER);
        uint256 redeemoCollateralBefore = dscEngine.getCollateralDeposited(
            USER,
            weth
        );
        vm.prank(USER);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 redeemWethAfter = ERC20Mock(weth).balanceOf(USER);
        uint256 redeemoCollateralAfter = dscEngine.getCollateralDeposited(
            USER,
            weth
        );
        assertEq(redeemWethBefore + AMOUNT_COLLATERAL, redeemWethAfter);
        assertEq(
            redeemoCollateralBefore - AMOUNT_COLLATERAL,
            redeemoCollateralAfter
        );
    }

    function testRevertLiquidateHealthFactorOk() public depositedCollateral {
        uint256 mintDscAmount = 10e18;
        uint256 ethInUsd = 20000e18;
        vm.startPrank(USER);
        dscEngine.mintDsc(mintDscAmount);
        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, ethInUsd);
        vm.stopPrank();
    }

    function testLiquidateHealthFactorNotOk() public depositedCollateral {
        //DSCAmount = 11000e18
        //collateral ether: 5.500000000000000000 ether
        //bouns: 0.550000000000000000 ether
        vm.startPrank(USER);
        dscEngine.mintDsc(10000e18);
        uint256 currentMintedDsc = dscEngine.setMintedDsc(USER, 1000e18);
        console.log("before_healthFactor:", dscEngine.getHealthFactor(USER));
        vm.stopPrank();

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(
            address(dscEngine),
            AMOUNT_COLLATERAL + AMOUNT_COLLATERAL
        );
        dscEngine.depositCollateral(
            weth,
            AMOUNT_COLLATERAL + AMOUNT_COLLATERAL
        );
        dscEngine.mintDsc(20000e18);
        IERC20(address(dsc)).approve(address(dscEngine), currentMintedDsc);
        uint256 wethBeforeLiquidate = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        console.log("wethBeforeLiquidate: ", wethBeforeLiquidate);
        dscEngine.liquidate(weth, USER, currentMintedDsc);
        vm.stopPrank();
        uint256 wethAfterLiquidate = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        console.log("wethAfterLiquidate: ", wethAfterLiquidate);
        console.log("after_healthFactor:", dscEngine.getHealthFactor(USER));
        uint256 calWeth = dscEngine.calculateTotalCollateralToRedeem(
            weth,
            currentMintedDsc
        );
        console.log("InputUsdAndCalculateWethAmount:", calWeth);
        // assertEq(IERC20(dsc)., );
        assertEq(
            IERC20(address(dsc)).balanceOf(LIQUIDATOR),
            20000e18 - currentMintedDsc
        );
        assertEq(wethBeforeLiquidate, wethAfterLiquidate - calWeth);
    }
}
