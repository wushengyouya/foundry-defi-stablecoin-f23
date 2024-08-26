// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title DSCEngin
 * @author WSYY
 * The system is designed to  be as minimal as possible,and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * Our DSC system should always be "overcollaterlized".At no point,should the value of
 * all collateral <= the $ backed value of all the DSC.
 *
 * It is similar to DAI if DAI had to no governance,no fees,and was only backed by WETH and WBTC.
 *
 * @notice This contract is the core of the DSC System.It handles all the login for mining and redeeming DSC,
 * as well as depositing & withdraw collateral.
 * @notice This contract is VERY loosely based on the MakerDAO  DSS(DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////
    //  Errors     //
    /////////////////
    error DSCEngine_NeedsMoreThanZero();
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine_NotAllowedToken();

    //////////////////////////
    //  State Variables    //
    /////////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds;
    DecentralizedStableCoin private immutable s_dsc;
    /////////////////
    //  Modifiers  //
    /////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount < 0) {
            revert DSCEngine_NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    /////////////////
    //  Functions  //
    /////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint8 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }
        //stable token contract address
        s_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////
    //  External Functions  //
    /////////////////////////

    function depositCollateralAndMintDsc() external {}

    /*
     *
     * @param tokenCollateraAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(
        address tokenCollateraAddress,
        uint256 amountCollateral
    )
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateraAddress)
        nonReentrant
    {}

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function mintDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}
