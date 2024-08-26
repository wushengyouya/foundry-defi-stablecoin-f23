// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title DecentralizedStableCoin
/// @author WSYY
/// Collateral: Exogenous (ETH & BTC)
/// Minting: Algorithmic
/// Relative Stability:Pegged to USD
/// This is the contract meat to be  governed by DSCEngine.This contract is just the ERC20 implementation of our stablecoin system.
contract DecentralizedStableCoin is ERC20, ERC20Burnable, Ownable {
    //errors
    error DecentralizeStableCoin_MustBeMoreThanZero();
    error DecentralizeStableCoin_BurnAmountExceedsBalance();
    error DecentralizeStableCoin_NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        if (_amount < 0) {
            revert DecentralizeStableCoin_MustBeMoreThanZero();
        }
        if (balanceOf(msg.sender) < _amount) {
            revert DecentralizeStableCoin_BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizeStableCoin_NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizeStableCoin_MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
