// SPDX-License-Identifier: MIT
// //Have our invariant aka properties
// //What are our invariants
// //1. The total supply of DSC should be less than the total value of collateral
// //2. Getter view funtions should be never revert <- evergreen invariant
pragma solidity ^0.8.22;

contract A {

}
// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dscEngine;
//     DecentralizedStableCoin dsc;
//     HelperConfig helperConig;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dscEngine, helperConig) = deployer.run();
//         (, , weth, wbtc, ) = helperConig.activeNetworkConfig();
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         //get the value of all the collateral in the protocol
//         uint256 totalDsc = IERC20(dsc).totalSupply();
//         uint256 totalWethInUsd = dscEngine.getUsdValue(
//             weth,
//             IERC20(weth).balanceOf(address(dscEngine))
//         );
//         uint256 totalWbtcInUsd = dscEngine.getUsdValue(
//             wbtc,
//             IERC20(wbtc).balanceOf(address(dscEngine))
//         );
//         console.log("wethInUsd:", totalWbtcInUsd);
//         console.log("wbtcInUsd", totalWbtcInUsd);
//         console.log("totalDsc:", totalDsc);
//         assert(totalWethInUsd + totalWbtcInUsd >= totalDsc);
//     }
// }
