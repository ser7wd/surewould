// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILaunchpadFactory {
    function completeMigration(address token, uint256 curveLeftoverTokens) external payable;
}

/// @notice Constant-product (x*y=k) bonding curve for a single token, pump.fun-style.
/// Deployed by LaunchpadFactory BEFORE the token exists (chicken-and-egg problem),
/// then wired up once via initialize(). Trading is permissionless from that point on.
///
/// "Virtual" reserves shape the price curve from token zero without needing real
/// liquidity seeded up front. "Real" reserves track what's actually been collected/sold,
/// and that's what determines migration and what gets paired into the Uniswap pool.
contract BondingCurve is ReentrancyGuard {
    address public immutable factory;
    address public feeRecipient;

    IERC20 public token;
    bool public initialized;

    uint256 public virtualEthReserves;
    uint256 public virtualTokenReserves;
    uint256 public realEthReserves;
    uint256 public realTokenReserves;

    uint256 public constant FEE_BPS = 100; // 1% per trade, sent to feeRecipient
    uint256 public immutable migrationThreshold; // real ETH raised that triggers migration

    bool public migrated;

    event Trade(address indexed trader, bool isBuy, uint256 ethAmount, uint256 tokenAmount, uint256 newPriceWei);
    event Migrated(uint256 ethAmount, uint256 tokenAmount);

    modifier onlyFactory() {
        require(msg.sender == factory, "curve: not factory");
        _;
    }

    constructor(
        address factory_,
        address feeRecipient_,
        uint256 virtualEthReserves_,
        uint256 virtualTokenReserves_,
        uint256 migrationThreshold_
    ) {
        factory = factory_;
        feeRecipient = feeRecipient_;
        virtualEthReserves = virtualEthReserves_;
        virtualTokenReserves = virtualTokenReserves_;
        migrationThreshold = migrationThreshold_;
    }

    /// @dev One-time setup call from the factory right after the token is deployed.
    function initialize(address token_, uint256 realTokenReserves_) external onlyFactory {
        require(!initialized, "curve: already initialized");
        token = IERC20(token_);
        realTokenReserves = realTokenReserves_;
        initialized = true;
    }

    /// @notice Current spot price in wei per whole token (18 decimals).
    function getPrice() public view returns (uint256) {
        return (virtualEthReserves * 1e18) / virtualTokenReserves;
    }

    function buy(uint256 minTokensOut) external payable nonReentrant {
        require(initialized, "curve: not initialized");
        require(!migrated, "curve: migrated");
        require(msg.value > 0, "curve: zero eth");

        uint256 fee = (msg.value * FEE_BPS) / 10000;
        uint256 ethIn = msg.value - fee;

        uint256 k = virtualEthReserves * virtualTokenReserves;
        uint256 newVirtualEthReserves = virtualEthReserves + ethIn;
        uint256 newVirtualTokenReserves = k / newVirtualEthReserves;
        uint256 tokensOut = virtualTokenReserves - newVirtualTokenReserves;

        require(tokensOut <= realTokenReserves, "curve: insufficient token liquidity");
        require(tokensOut >= minTokensOut, "curve: slippage");

        virtualEthReserves = newVirtualEthReserves;
        virtualTokenReserves = newVirtualTokenReserves;
        realEthReserves += ethIn;
        realTokenReserves -= tokensOut;

        if (fee > 0) {
            (bool sentFee, ) = feeRecipient.call{value: fee}("");
            require(sentFee, "curve: fee transfer failed");
        }

        require(token.transfer(msg.sender, tokensOut), "curve: token transfer failed");

        emit Trade(msg.sender, true, msg.value, tokensOut, getPrice());

        if (realEthReserves >= migrationThreshold) {
            _migrate();
        }
    }

    function sell(uint256 tokenAmount, uint256 minEthOut) external nonReentrant {
        require(initialized, "curve: not initialized");
        require(!migrated, "curve: migrated");
        require(tokenAmount > 0, "curve: zero tokens");

        uint256 k = virtualEthReserves * virtualTokenReserves;
        uint256 newVirtualTokenReserves = virtualTokenReserves + tokenAmount;
        uint256 newVirtualEthReserves = k / newVirtualTokenReserves;
        uint256 ethOut = virtualEthReserves - newVirtualEthReserves;
        // Integer division during buy/sell can round such that reversing a buy exactly
        // computes an ethOut a wei or two above what's actually in realEthReserves.
        // Clamp rather than revert — the curve should never attempt to pay out more
        // real ETH than it actually holds.
        if (ethOut > realEthReserves) {
            ethOut = realEthReserves;
        }

        uint256 fee = (ethOut * FEE_BPS) / 10000;
        uint256 ethToUser = ethOut - fee;

        require(ethToUser >= minEthOut, "curve: slippage");

        virtualEthReserves = newVirtualEthReserves;
        virtualTokenReserves = newVirtualTokenReserves;
        realEthReserves -= ethOut;
        realTokenReserves += tokenAmount;

        require(token.transferFrom(msg.sender, address(this), tokenAmount), "curve: token transferFrom failed");

        if (fee > 0) {
            (bool sentFee, ) = feeRecipient.call{value: fee}("");
            require(sentFee, "curve: fee transfer failed");
        }
        (bool sent, ) = msg.sender.call{value: ethToUser}("");
        require(sent, "curve: eth transfer failed");

        emit Trade(msg.sender, false, ethOut, tokenAmount, getPrice());
    }

    function _migrate() internal {
        migrated = true;
        uint256 ethAmount = realEthReserves;
        uint256 tokenAmount = realTokenReserves; // any unsold curve inventory rides along into the LP
        realEthReserves = 0;
        realTokenReserves = 0;

        if (tokenAmount > 0) {
            require(token.transfer(factory, tokenAmount), "curve: migration transfer failed");
        }

        ILaunchpadFactory(factory).completeMigration{value: ethAmount}(address(token), tokenAmount);

        emit Migrated(ethAmount, tokenAmount);
    }

    receive() external payable {
        revert("curve: use buy()");
    }
}
