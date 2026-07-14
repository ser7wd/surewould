// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/LaunchpadFactory.sol";
import "../test/mocks/MockUniswapV2Router.sol";

/// @notice One-command deploy for the Stampede launchpad.
///
/// TESTNET (no Uniswap deployed there): deploys MockUniswapV2Router as a stand-in,
/// then the factory pointed at it. Set USE_MOCK_ROUTER=true.
///
/// MAINNET: uses the real Uniswap V2 Router02 on Robinhood Chain.
/// Set USE_MOCK_ROUTER=false and ROUTER=0x89e5db8b5aa49aa85ac63f691524311aeb649eba
///
/// Required env vars:
///   PRIVATE_KEY       — throwaway deployer key, funded with ETH on the target chain
///   FEE_RECIPIENT     — your personal wallet; receives the 1% trade fees
///   USE_MOCK_ROUTER   — "true" on testnet, "false" on mainnet
///   ROUTER            — (mainnet only) the Uniswap V2 Router02 address
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        bool useMock = vm.envBool("USE_MOCK_ROUTER");

        vm.startBroadcast(pk);

        address router;
        if (useMock) {
            MockUniswapV2Router mock = new MockUniswapV2Router();
            router = address(mock);
            console.log("MockUniswapV2Router deployed:", router);
        } else {
            router = vm.envAddress("ROUTER");
            console.log("Using existing router:", router);
        }

        // Curve parameters — env-overridable, defaulting to mainnet reference values.
        // Testnet demo scale: VIRTUAL_ETH=1100000000000000 THRESHOLD=3000000000000000 (wei)
        uint256 virtualEth = vm.envOr("VIRTUAL_ETH", uint256(1.1 ether));
        uint256 virtualTokens = vm.envOr("VIRTUAL_TOKENS", uint256(1_073_000_000 * 1e18));
        uint256 threshold = vm.envOr("THRESHOLD", uint256(3 ether));

        LaunchpadFactory factory = new LaunchpadFactory(router, feeRecipient, virtualEth, virtualTokens, threshold);
        console.log("Curve: virtualEth (wei):", virtualEth);
        console.log("Curve: migration threshold (wei):", threshold);
        console.log("LaunchpadFactory deployed:", address(factory));
        console.log("Fee recipient:", feeRecipient);

        vm.stopBroadcast();
    }
}
