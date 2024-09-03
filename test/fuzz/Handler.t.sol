// SPDX-License-Identifier: MIT
//Handler is going to narrow down the way we call function

pragma solidity ^0.8.22;
import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint96 private constant MAX_DEPOSITE_SIZE = type(uint96).max;

    uint256 public totalMintDscCount;

    address[] usersWithCollateralDeposited;

    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;
        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        ethUsdPriceFeed = MockV3Aggregator(
            address(dsce.getCollateralPriceFeed(address(weth)))
        );
    }

    function depositCollateral(
        uint256 collateralSeed,
        uint256 collateralAmount
    ) public {
        // dsce.depositCollateral(collateralSeed, collateralAmount);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSITE_SIZE);
        console.log("Hanlder-collateral:", address(collateral));

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(dsce), collateralAmount);
        dsce.depositCollateral(address(collateral), collateralAmount);
        vm.stopPrank();
        //double push
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral,
        uint256 addressSeed
    ) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        uint256 index = addressSeed % usersWithCollateralDeposited.length;
        address sender = usersWithCollateralDeposited[index];
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        //66884904903871590915023244415 - 47917066624767641279845705579
        uint256 collateralToRedeem = dsce.getCollateralDeposited(
            sender,
            address(collateral)
        );
        //5.089609629692226721636088895
        amountCollateral = bound(amountCollateral, 0, collateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        //赎回全部，或者只能赎回一半，不能
        if (amountCollateral > (collateralToRedeem / 2)) {
            return;
        }

        vm.startPrank(sender);
        // uint256 collateralInUsd = dsce.getUsdValue(
        //     address(collateral),
        //     amountCollateral
        // );
        // dsce.burnDsc(collateralInUsd);
        dsce.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        uint256 index = addressSeed % usersWithCollateralDeposited.length;
        address sender = usersWithCollateralDeposited[index];
        console.log(index, sender);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInformation(sender);
        console.log("totalDscMinted:", totalDscMinted);
        console.log("collateralValueInUsd:", collateralValueInUsd);
        int256 maxDsxToMint = (int256(collateralValueInUsd) / 2) -
            int256(totalDscMinted);
        console.log("maxDsxToMint:", uint256(maxDsxToMint));
        // console.log("maxDsxToMint:", maxDsxToMint);
        if (maxDsxToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDsxToMint));
        if (amount == 0) {
            return;
        }
        vm.prank(sender);
        dsce.mintDsc(amount);
        totalMintDscCount++;
    }

    function updateCollateralPrice(uint96 newPrice) public {
        int256 newPriceInt = int256(uint256(newPrice));
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }

    function _getCollateralFromSeed(
        uint256 collateralSeed
    ) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
