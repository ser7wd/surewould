// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Bare-bones stand-in for a Uniswap V2 router, used only in tests.
/// Pulls in the token + ETH exactly like the real addLiquidityETH would, and mints
/// a fake LP token to whatever `to` address is passed — enough to verify our factory
/// wires the migration correctly without depending on a real Uniswap deployment.
contract MockUniswapV2Router is ERC20 {
    event LiquidityAdded(address indexed token, uint256 amountToken, uint256 amountETH, address to);

    constructor() ERC20("Mock LP", "MLP") {}

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 /* amountTokenMin */,
        uint256 /* amountETHMin */,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        require(block.timestamp <= deadline, "mock router: expired");
        require(IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired), "mock router: token pull failed");

        liquidity = amountTokenDesired + msg.value; // arbitrary but deterministic, fine for tests
        _mint(to, liquidity);

        emit LiquidityAdded(token, amountTokenDesired, msg.value, to);
        return (amountTokenDesired, msg.value, liquidity);
    }

    receive() external payable {}
}
