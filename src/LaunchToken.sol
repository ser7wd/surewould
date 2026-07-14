// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The token that gets created for every launch. Fixed supply, no owner mint,
/// no admin functions — everything about its distribution happens at construction.
contract LaunchToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address curve_,          // gets the sellable portion
        address factory_,        // gets the portion reserved for migration LP
        uint256 curveAllocation_
    ) ERC20(name_, symbol_) {
        require(curveAllocation_ <= totalSupply_, "token: bad allocation");
        _mint(curve_, curveAllocation_);
        if (totalSupply_ > curveAllocation_) {
            _mint(factory_, totalSupply_ - curveAllocation_);
        }
    }
}
