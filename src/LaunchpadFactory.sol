// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./LaunchToken.sol";
import "./BondingCurve.sol";

interface IUniswapV2Router {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

/// @notice Deploys a token + bonding curve pair for each new launch, and handles
/// migrating a curve's raised ETH + remaining tokens into a real Uniswap V2 pool
/// once that curve's raise threshold is hit. LP tokens are sent to a burn address
/// so the initial liquidity can never be pulled by anyone, including the deployer.
contract LaunchpadFactory {
    address public immutable uniswapRouter;
    address public feeRecipient;
    address public owner;

    // --- Tunable launch parameters. Same for every token from this factory. ---
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;   // 1B tokens per launch
    uint256 public constant CURVE_ALLOCATION = 800_000_000 * 1e18; // 800M sellable on the curve
    // remaining 200M sits in this factory, reserved to pair with raised ETH at migration

    uint256 public constant VIRTUAL_ETH_RESERVES = 3 ether;                 // starting curve "depth" — tune this
    uint256 public constant VIRTUAL_TOKEN_RESERVES = 1_073_000_000 * 1e18;  // sets initial price
    // With the reserves above, the 800M curve allocation fully depletes at ~8.79 ETH of net
    // (post-fee) inflow. MIGRATION_THRESHOLD must stay comfortably below that or large buys
    // near the threshold can revert instead of migrating. 8 ETH leaves ~0.79 ETH of headroom.
    uint256 public constant MIGRATION_THRESHOLD = 8 ether;

    mapping(address => address) public curveOf;  // token => its curve
    mapping(address => bool) public isCurve;      // curve => is a real curve from this factory
    address[] public allTokens;

    event TokenLaunched(address indexed token, address indexed curve, address indexed creator, string name, string symbol);
    event MigrationComplete(address indexed token, uint256 ethAmount, uint256 tokenAmount, uint256 lpTokens);

    constructor(address uniswapRouter_, address feeRecipient_) {
        uniswapRouter = uniswapRouter_;
        feeRecipient = feeRecipient_;
        owner = msg.sender;
    }

    /// @notice Anyone can launch a token. No admin approval, matching pump.fun's permissionless model.
    function launch(string calldata name, string calldata symbol) external returns (address tokenAddr, address curveAddr) {
        // Curve must exist before the token, since the token mints directly to the curve's address.
        BondingCurve curve = new BondingCurve(
            address(this),
            feeRecipient,
            VIRTUAL_ETH_RESERVES,
            VIRTUAL_TOKEN_RESERVES,
            MIGRATION_THRESHOLD
        );

        LaunchToken newToken = new LaunchToken(
            name,
            symbol,
            TOTAL_SUPPLY,
            address(curve),
            address(this),
            CURVE_ALLOCATION
        );

        curve.initialize(address(newToken), CURVE_ALLOCATION);

        curveOf[address(newToken)] = address(curve);
        isCurve[address(curve)] = true;
        allTokens.push(address(newToken));

        emit TokenLaunched(address(newToken), address(curve), msg.sender, name, symbol);
        return (address(newToken), address(curve));
    }

    /// @dev Called by a BondingCurve once it hits its migration threshold. Combines the
    /// ETH and leftover tokens it forwards with this factory's reserved 200M allocation,
    /// deposits both into a fresh Uniswap V2 pool, and burns the LP tokens.
    function completeMigration(address token, uint256 curveLeftoverTokens) external payable {
        require(isCurve[msg.sender], "factory: caller not a known curve");
        require(curveOf[token] == msg.sender, "factory: token/curve mismatch");

        uint256 tokensForLP = IERC20(token).balanceOf(address(this));

        IERC20(token).approve(uniswapRouter, tokensForLP);

        (, , uint256 lpTokens) = IUniswapV2Router(uniswapRouter).addLiquidityETH{value: msg.value}(
            token,
            tokensForLP,
            0, // TODO: replace with real slippage bounds before using with real funds
            0,
            address(0xdead), // burned — nobody, including this contract's owner, can withdraw this liquidity
            block.timestamp + 600
        );

        emit MigrationComplete(token, msg.value, curveLeftoverTokens, lpTokens);
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function setFeeRecipient(address newRecipient) external {
        require(msg.sender == owner, "factory: not owner");
        feeRecipient = newRecipient;
    }

    /// @dev The Uniswap V2 router refunds excess ETH to msg.sender when the pair already
    /// exists at a different ratio (e.g. someone pre-created and seeded the pair to grief
    /// a launch). Without this, that refund would revert and permanently brick the
    /// migration — and with it every buy that crosses the threshold.
    receive() external payable {}
}
