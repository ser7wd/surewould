// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock router that behaves like the real Uniswap V2 router does when the pair
/// already exists at a different ratio: it uses only part of the ETH sent and refunds
/// the rest to msg.sender. Used to regression-test that a griefer pre-seeding the pair
/// cannot permanently brick a migration.
contract MockRefundingRouter is ERC20 {
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

        // Simulate a pre-seeded pair at a skewed ratio: only half the ETH is needed.
        amountETH = msg.value / 2;
        uint256 refund = msg.value - amountETH;
        (bool sent, ) = msg.sender.call{value: refund}("");
        require(sent, "mock router: refund failed"); // exactly what the real router does

        liquidity = amountTokenDesired + amountETH;
        _mint(to, liquidity);
        return (amountTokenDesired, amountETH, liquidity);
    }

    receive() external payable {}
}
