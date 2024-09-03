// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {console} from "forge-std/Test.sol";

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
    error DSCEngine_HealthFactorOk();
    error DSCEngine_HeathFactorNotImproved();

    //////////////////////////
    //  Types    //
    /////////////////////////
    using OracleLib for AggregatorV3Interface;

    //////////////////////////
    //  State Variables    //
    /////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200%  overcollaterilzed
    uint256 private constant LIQUIDATION_PRECISON = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LUIQIDATION_BONUS = 10; //this mean a 10% bonus

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
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed tokenCollateralAddress,
        uint256 amount
    );
    event HealthFatorBroken(uint256 healthFator);
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
     * @notice this function will deposit your collateral and mint DSC in one transaction
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

    /**
     *
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral alredy checks health fator
    }

    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public {
        //In versions ^0.8,built-in mathematical overflow checks are included,which will trigger a rollback if an over flow occurs.
        //0.8版本以上自带数学溢出检查，超出会回滚
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

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

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor.Their _healthFactor should be
     * below MIN_HEALTH_FAVTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor.
     * @notice You can partially liquidate a user.
     * @notice This function working assumes the protocol will be roughly 200%
     * overcollateralized in order for this to work.
     * @notice A knwon bug would be if the protocol were 100% or less collateralized,then
     * wo would't be able to incentive the liquidators.
     * For example,if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        //need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOk();
        }
        //we want to burn their DSC "debt"
        //and take their collateral
        //Bad user:$140 ETH,$100 DSC
        //debtToCover = $100
        //$100 of DSC == ETH?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        //DSCAmountInUsd = 11000e18
        //collateral ether: 5.500000000000000000 ether
        //bouns: 0.550000000000000000 ether
        //And give them a 10% bonus
        //So we are givin the liquidator $110 of WTH,for 100DSC
        //We should implement amounts into a treasury
        //0.05 *0.1 = 0.005,Getting 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LUIQIDATION_BONUS) / LIQUIDATION_PRECISON;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            collateral,
            totalCollateralToRedeem,
            user,
            msg.sender
        );
        //We need to burn the DSC.
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_HeathFactorNotImproved();
        }
    }

    /////////////////////////////////////////
    //  Private & Internal view Functions  //
    /////////////////////////////////////////
    /**
     * @dev Low-level internal function,do not call unless the function calling it is
     * checking for health factor being broken
     */
    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfof,
        address dscFrom
    ) private {
        s_DSCMintd[onBehalfof] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        //This conditional is hypothtically unreachable
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

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

    function _calculateHeathFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsed
    ) private pure returns (uint256) {
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        if (collateralValueInUsed == 0) {
            return type(uint256).max;
        }
        //(20000e18*50)/100 = 10000,000000000000000000
        uint256 collateralAdjustedForThreshold = (collateralValueInUsed *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISON;
        //1000,000000000000000000
        //1.000000000000000000
        //0.500000000000000000
        console.log("collateralValueInUsed: ", collateralValueInUsed);
        console.log(
            "collateralAdjustedForThreshold: ",
            collateralAdjustedForThreshold
        );
        console.log("totalDscMinted: ", totalDscMinted);
        console.log(
            "healthFactor: ",
            (collateralAdjustedForThreshold * PRECISION) / totalDscMinted
        );
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; //47917066624767641279845705579
        //(*1e18)/=283589224001513204
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
        return _calculateHeathFactor(totalDscMinted, collateralValueInUsed);
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
    function getCollateralPriceFeed(
        address collateral
    ) public view returns (AggregatorV3Interface) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[collateral]
        );
        return priceFeed;
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function calculateTotalCollateralToRedeem(
        address collateral,
        uint256 debtToCover
    ) public view returns (uint256) {
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        //DSCAmountInUsd = 11000e18
        //collateral ether: 5.500000000000000000 ether
        //bouns: 0.550000000000000000 ether
        //And give them a 10% bonus
        //So we are givin the liquidator $110 of WTH,for 100DSC
        //We should implement amounts into a treasury
        //0.05 *0.1 = 0.005,Getting 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LUIQIDATION_BONUS) / LIQUIDATION_PRECISON;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        return totalCollateralToRedeem;
    }

    function setMintedDsc(
        address user,
        uint256 amount
    ) public returns (uint256) {
        s_DSCMintd[user] += amount;
        return s_DSCMintd[user];
    }

    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsed
    ) public pure returns (uint256) {
        return _calculateHeathFactor(totalDscMinted, collateralValueInUsed);
    }

    function getCollateralDeposited(
        address user,
        address collateralAddress
    ) public view returns (uint256) {
        return s_collateralDeposited[user][collateralAddress];
    }

    function getMinHealthFactor() public pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getMintedDsc(address user) public view returns (uint256) {
        return s_DSCMintd[user];
    }

    function getAccountInformation(
        address user
    )
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInfomation(user);
    }

    function getHealthFactor(address user) public view returns (uint256) {
        return _healthFactor(user);
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLastestRoundData();
        //0.005000000000000000
        //($11000e18 * 1e18)/($2000e8*1e10) = 5.500000000000000000 (5.5 ether)
        //uint256 u3 = (20001e18*1e18)/(2000e8 * 1e10); 在进行运算时 乘以 PRECISION 时为了保留 18个精度位
        //10.000500000000000000
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

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
        (, int256 price, , , ) = priceFeed.staleCheckLastestRoundData();
        //20000.000000000000000000
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // 2000 * 1e8 * 1e10 * 10 * 1e18 / 1e18
    }
}
