// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

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
    error DSCEngine_TransferFailed();
    error DSCEngine_BreakHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();

    //////////////////////////
    //  State Variables    //
    /////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISON = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    DecentralizedStableCoin private immutable i_dsc;
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMintd) private s_DSCMintd;
    address[] private s_collateralTokens;
    //////////////////////////
    //  Events              //
    /////////////////////////
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /////////////////
    //  Modifiers  //
    /////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
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
            s_collateralTokens.push(tokenAddresses[i]);
        }
        //stable token contract address
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////
    //  External Functions  //
    /////////////////////////

    /**
     * @param tokenCollateraAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount Of decentralized stablecoin to mint
     * @notice thsi function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateraAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateraAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     *
     * @param tokenCollateraAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     * use CEI check-effect-interaction
     */
    function depositCollateral(
        address tokenCollateraAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateraAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateraAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateraAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateraAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    /*
     * @notice follows CEI
     * @param amountDscToMint The amount Of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMintd[msg.sender] += amountDscToMint;
        //if they minted to mush($150 DSC,$100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool mintedSuccess = i_dsc.mint(msg.sender, amountDscToMint);
        if (!mintedSuccess) {
            revert DSCEngine_MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    /////////////////////////////////////////
    //  Private & Internal view Functions  //
    /////////////////////////////////////////
    function _getAccountInfomation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMintd[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /* TODO: can't understand
        Returns how close to liquidation a  user is   || liquidation-清算
        If a user goes below 1,then they can get liquidated
        质押价值必须大于或者等于铸造价值的 200%。当前最小清算比例为50%
        ((质押价值 *50)/100)*精度 / 铸造价值 >= 1 则不会受到清算
     */
    function _healthFactor(address user) private view returns (uint256) {
        //total DSC minted
        //total collateral VALUE
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsed //over 200%
        ) = _getAccountInfomation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsed *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISON;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. check health factor (do they have enough collateral)
        uint256 healthFactor = _healthFactor(user);
        // 2. Revert if they don't
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_BreakHealthFactor(healthFactor);
        }
    }

    /////////////////////////////////////////
    //  public & External view Functions  //
    /////////////////////////////////////////
    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token,get the amount they have deposited,and map it
        //the price,to get the USD value

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();

        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // 1000 * 1e8 * 1e10 * 1000 * 1e18
    }
}
