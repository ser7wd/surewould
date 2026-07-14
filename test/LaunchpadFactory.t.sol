// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/LaunchpadFactory.sol";
import "../src/BondingCurve.sol";
import "../src/LaunchToken.sol";
import "./mocks/MockUniswapV2Router.sol";
import "./mocks/MockRefundingRouter.sol";

contract LaunchpadFactoryTest is Test {
    LaunchpadFactory factory;
    MockUniswapV2Router router;

    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        router = new MockUniswapV2Router();
        factory = new LaunchpadFactory(
            address(router), feeRecipient,
            1.1 ether, 1_073_000_000 * 1e18, 3 ether
        );

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _launch() internal returns (LaunchToken token, BondingCurve curve) {
        (address tokenAddr, address curveAddr) = factory.launch("Test Coin", "TEST");
        token = LaunchToken(tokenAddr);
        curve = BondingCurve(payable(curveAddr));
    }

    // ---------- Launch ----------

    function test_launch_setsUpTokenAndCurveCorrectly() public {
        (LaunchToken token, BondingCurve curve) = _launch();

        assertEq(token.totalSupply(), factory.TOTAL_SUPPLY());
        assertEq(token.balanceOf(address(curve)), factory.CURVE_ALLOCATION());
        assertEq(token.balanceOf(address(factory)), factory.TOTAL_SUPPLY() - factory.CURVE_ALLOCATION());
        assertEq(address(curve.token()), address(token));
        assertTrue(curve.initialized());
        assertFalse(curve.migrated());
        assertEq(factory.curveOf(address(token)), address(curve));
        assertTrue(factory.isCurve(address(curve)));
    }

    function test_launch_multipleTokensAreIndependent() public {
        (LaunchToken tokenA, BondingCurve curveA) = _launch();
        (LaunchToken tokenB, BondingCurve curveB) = _launch();

        assertTrue(address(tokenA) != address(tokenB));
        assertTrue(address(curveA) != address(curveB));
        assertEq(factory.tokenCount(), 2);

        // buying on one curve should not affect the other
        vm.prank(alice);
        curveA.buy{value: 1 ether}(0);

        assertGt(tokenA.balanceOf(alice), 0);
        assertEq(tokenB.balanceOf(alice), 0);
        assertEq(curveB.realEthReserves(), 0);
    }

    function test_curve_cannotBeInitializedTwice() public {
        (, BondingCurve curve) = _launch();
        vm.prank(address(factory));
        vm.expectRevert("curve: already initialized");
        curve.initialize(address(0xdead), 1);
    }

    function test_curve_onlyFactoryCanInitialize() public {
        BondingCurve freshCurve = new BondingCurve(address(factory), feeRecipient, 1.1 ether, 1_073_000_000e18, 3 ether);
        vm.expectRevert("curve: not factory");
        freshCurve.initialize(address(0xdead), 1);
    }

    // ---------- Buying ----------

    function test_buy_givesTokensAndTakesFee() public {
        (LaunchToken token, BondingCurve curve) = _launch();

        uint256 feeRecipientBefore = feeRecipient.balance;
        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        curve.buy{value: 1 ether}(0);

        uint256 expectedFee = (1 ether * curve.FEE_BPS()) / 10000;
        assertEq(feeRecipient.balance - feeRecipientBefore, expectedFee);
        assertEq(aliceEthBefore - alice.balance, 1 ether);
        assertGt(token.balanceOf(alice), 0);
        assertEq(curve.realEthReserves(), 1 ether - expectedFee);
    }

    function test_buy_priceRisesAsCurveIsBought() public {
        (, BondingCurve curve) = _launch();

        uint256 priceBefore = curve.getPrice();

        vm.prank(alice);
        curve.buy{value: 2 ether}(0);

        uint256 priceAfter = curve.getPrice();
        assertGt(priceAfter, priceBefore, "price should rise after a buy");
    }

    function test_buy_laterBuyersGetFewerTokensForSameEth() public {
        (LaunchToken token, BondingCurve curve) = _launch();

        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        uint256 aliceTokens = token.balanceOf(alice);

        vm.prank(bob);
        curve.buy{value: 1 ether}(0);
        uint256 bobTokens = token.balanceOf(bob);

        assertLt(bobTokens, aliceTokens, "buying into a pumped curve should yield fewer tokens for the same ETH");
    }

    function test_buy_revertsOnZeroEth() public {
        (, BondingCurve curve) = _launch();
        vm.expectRevert("curve: zero eth");
        vm.prank(alice);
        curve.buy{value: 0}(0);
    }

    function test_buy_revertsOnSlippage() public {
        (, BondingCurve curve) = _launch();

        // ask for an impossibly high minimum tokens out
        vm.expectRevert("curve: slippage");
        vm.prank(alice);
        curve.buy{value: 1 ether}(type(uint256).max);
    }

    function test_buy_revertsAfterMigration() public {
        (, BondingCurve curve) = _launch();

        vm.prank(alice);
        curve.buy{value: 3.1 ether}(0); // net 3.069 ETH clears the 3 ETH threshold, triggers migration
        assertTrue(curve.migrated());

        vm.expectRevert("curve: migrated");
        vm.prank(bob);
        curve.buy{value: 1 ether}(0);
    }

    // ---------- Selling ----------

    function test_sell_returnsEthMinusFee() public {
        (LaunchToken token, BondingCurve curve) = _launch();

        vm.startPrank(alice);
        curve.buy{value: 2 ether}(0);
        uint256 tokenBalance = token.balanceOf(alice);

        token.approve(address(curve), tokenBalance);
        uint256 ethBefore = alice.balance;
        curve.sell(tokenBalance, 0);
        vm.stopPrank();

        // alice should get back less than she put in, since both buy and sell take a 1% fee
        assertGt(alice.balance, ethBefore, "should receive some eth back");
        assertLt(alice.balance, ethBefore + 2 ether, "round trip should cost fees");
    }

    function test_sell_revertsOnSlippage() public {
        (LaunchToken token, BondingCurve curve) = _launch();

        vm.startPrank(alice);
        curve.buy{value: 2 ether}(0);
        uint256 tokenBalance = token.balanceOf(alice);
        token.approve(address(curve), tokenBalance);

        vm.expectRevert("curve: slippage");
        curve.sell(tokenBalance, type(uint256).max);
        vm.stopPrank();
    }

    function test_sell_revertsWithoutApproval() public {
        (LaunchToken token, BondingCurve curve) = _launch();

        vm.prank(alice);
        curve.buy{value: 2 ether}(0);

        uint256 tokenBalance = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientAllowance
        curve.sell(tokenBalance, 0);
    }

    function test_buyThenSell_roundTripDoesNotMintValue() public {
        (LaunchToken token, BondingCurve curve) = _launch();

        vm.startPrank(alice);
        curve.buy{value: 2.5 ether}(0);
        uint256 tokens = token.balanceOf(alice);
        token.approve(address(curve), tokens);
        curve.sell(tokens, 0);
        vm.stopPrank();

        // curve's real reserves should be back near zero (small dust from fee asymmetry aside)
        assertLt(curve.realEthReserves(), 0.01 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------- Migration ----------

    function test_migration_triggersAtThreshold() public {
        (, BondingCurve curve) = _launch();

        vm.prank(alice);
        curve.buy{value: 2.5 ether}(0);
        assertFalse(curve.migrated(), "should not migrate before threshold");

        vm.prank(bob);
        curve.buy{value: 0.6 ether}(0);
        assertTrue(curve.migrated(), "should migrate once threshold is crossed");
    }

    function test_migration_sendsLiquidityToRouterAndBurnsLP() public {
        (LaunchToken token, BondingCurve curve) = _launch();

        vm.prank(alice);
        curve.buy{value: 3.1 ether}(0);
        assertTrue(curve.migrated());

        // router should hold the paired tokens
        assertGt(token.balanceOf(address(router)), 0);
        // burn address should hold the LP tokens, not the factory or deployer
        assertGt(router.balanceOf(address(0xdead)), 0);
        assertEq(router.balanceOf(address(factory)), 0);

        // curve's real reserves should be zeroed out post-migration
        assertEq(curve.realEthReserves(), 0);
        assertEq(curve.realTokenReserves(), 0);
    }

    function test_migration_pairsFactoryReserveWithCurveLeftovers() public {
        (LaunchToken token, BondingCurve curve) = _launch();

        uint256 factoryReserveBefore = token.balanceOf(address(factory));
        assertEq(factoryReserveBefore, factory.TOTAL_SUPPLY() - factory.CURVE_ALLOCATION());

        vm.prank(alice);
        curve.buy{value: 3.1 ether}(0);

        // after migration, factory should have forwarded everything to the router
        assertEq(token.balanceOf(address(factory)), 0);
    }

    function test_migration_onlyCallableByKnownCurve() public {
        vm.expectRevert("factory: caller not a known curve");
        factory.completeMigration(address(0xdead), 0);
    }

    function test_migration_cannotBeTriggeredForMismatchedToken() public {
        (, BondingCurve curveA) = _launch();
        (LaunchToken tokenB, ) = _launch();

        vm.prank(address(curveA));
        vm.expectRevert("factory: token/curve mismatch");
        factory.completeMigration(address(tokenB), 0);
    }

    function test_migration_survivesRouterEthRefund() public {
        // Regression test: the real Uniswap router refunds excess ETH to msg.sender when
        // the pair already exists at a different ratio (e.g. a griefer pre-seeded it).
        // If the factory can't receive that refund, migration reverts forever.
        MockRefundingRouter refundingRouter = new MockRefundingRouter();
        LaunchpadFactory factory2 = new LaunchpadFactory(
            address(refundingRouter), feeRecipient,
            1.1 ether, 1_073_000_000 * 1e18, 3 ether
        );

        (address tokenAddr, address curveAddr) = factory2.launch("Griefed Coin", "GRIEF");
        BondingCurve curve = BondingCurve(payable(curveAddr));

        vm.prank(alice);
        curve.buy{value: 3.1 ether}(0); // must not revert despite the router refunding half the ETH

        assertTrue(curve.migrated(), "migration should complete even when the router refunds ETH");
        assertGt(refundingRouter.balanceOf(address(0xdead)), 0, "LP should still be burned");
        assertGt(address(factory2).balance, 0, "factory should hold the refunded ETH");
        assertEq(LaunchToken(tokenAddr).balanceOf(address(factory2)), 0);
    }

    // ---------- Admin ----------

    function test_setFeeRecipient_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("factory: not owner");
        factory.setFeeRecipient(alice);

        factory.setFeeRecipient(alice); // called by test contract, which deployed the factory
        assertEq(factory.feeRecipient(), alice);
    }

    // ---------- Fuzz ----------

    function testFuzz_buy_neverGivesOutMoreThanRealTokenReserves(uint96 ethAmount) public {
        vm.assume(ethAmount > 0.001 ether && ethAmount < 2.9 ether); // stay under migration threshold
        (LaunchToken token, BondingCurve curve) = _launch();

        uint256 reservesBefore = curve.realTokenReserves();

        vm.prank(alice);
        curve.buy{value: ethAmount}(0);

        assertLe(token.balanceOf(alice), reservesBefore);
        assertGe(curve.realTokenReserves(), 0);
    }
}
