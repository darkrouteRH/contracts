// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DarkStaking} from "../src/DarkStaking.sol";

contract MockDark {
    string public name = "DarkRoute";
    string public symbol = "DARK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public failTransfers;

    function setFail(bool v) external {
        failTransfers = v;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (failTransfers) return false;
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (failTransfers) return false;
        require(balanceOf[f] >= a, "bal");
        require(allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract DarkStakingTest is Test {
    MockDark dark;
    DarkStaking s;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        dark = new MockDark();
        s = new DarkStaking(address(dark));
        dark.mint(alice, 10_000_000e18);
        dark.mint(bob, 5_000_000e18);
        vm.prank(alice);
        dark.approve(address(s), type(uint256).max);
        vm.prank(bob);
        dark.approve(address(s), type(uint256).max);
    }

    // ---------------------------------------------------------------- staking

    function test_stake_movesTokensAndRecordsCommitment() public {
        vm.prank(alice);
        s.stake(1_000_000e18, 30);
        assertEq(s.stakedOf(alice), 1_000_000e18);
        assertEq(s.totalStaked(), 1_000_000e18);
        assertEq(dark.balanceOf(address(s)), 1_000_000e18);
        assertEq(dark.balanceOf(alice), 9_000_000e18);
        (uint256 amt, uint32 d, uint64 until) = s.commitmentOf(alice);
        assertEq(amt, 1_000_000e18);
        assertEq(d, 30);
        assertEq(until, block.timestamp + 30 days);
        assertTrue(s.boostActive(alice));
    }

    function test_stake_rejectsBadLockLength() public {
        vm.prank(alice);
        vm.expectRevert(DarkStaking.BadLock.selector);
        s.stake(1e18, 45);
    }

    function test_stake_rejectsZero() public {
        vm.prank(alice);
        vm.expectRevert(DarkStaking.ZeroAmount.selector);
        s.stake(0, 30);
    }

    /// Topping up must never shorten a commitment that is already running.
    function test_stake_againDoesNotShortenLock() public {
        vm.prank(alice);
        s.stake(1_000_000e18, 180);
        (,, uint64 first) = s.commitmentOf(alice);
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        s.stake(500_000e18, 30);
        (uint256 amt, uint32 d, uint64 until) = s.commitmentOf(alice);
        assertEq(amt, 1_500_000e18);
        assertEq(until, first, "a 30-day top-up shortened a running 180-day commitment");
        assertEq(d, 180);
    }

    function test_stake_againExtendsWhenLonger() public {
        vm.prank(alice);
        s.stake(1e18, 30);
        vm.prank(alice);
        s.stake(1e18, 180);
        (, uint32 d, uint64 until) = s.commitmentOf(alice);
        assertEq(until, block.timestamp + 180 days);
        assertEq(d, 180);
    }

    // ---------------------------------------------------------------- unstaking

    function test_unstake_afterMaturityReturnsEverything() public {
        vm.prank(alice);
        s.stake(2_500_000e18, 30);
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        s.unstake(2_500_000e18);
        assertEq(dark.balanceOf(alice), 10_000_000e18);
        assertEq(s.stakedOf(alice), 0);
        assertEq(s.totalStaked(), 0);
    }

    /// The published design: leaving early is allowed and costs nothing but the boost.
    function test_unstake_earlyIsAllowedAndNothingIsBurned() public {
        vm.prank(alice);
        s.stake(1_000_000e18, 180);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        s.unstake(1_000_000e18);
        assertEq(dark.balanceOf(alice), 10_000_000e18, "an early exit lost tokens");
        assertFalse(s.boostActive(alice));
    }

    function test_unstake_partialEndsTheBoost() public {
        vm.prank(alice);
        s.stake(1_000_000e18, 90);
        assertTrue(s.boostActive(alice));
        vm.prank(alice);
        s.unstake(1e18);
        assertFalse(s.boostActive(alice), "a partial exit kept the boost alive");
        assertEq(s.stakedOf(alice), 1_000_000e18 - 1e18);
    }

    function test_unstake_moreThanStakedReverts() public {
        vm.prank(alice);
        s.stake(1e18, 30);
        vm.prank(alice);
        vm.expectRevert(DarkStaking.InsufficientStake.selector);
        s.unstake(2e18);
    }

    /// The whole point of the contract: nobody else can take your position.
    function test_unstake_cannotTouchSomeoneElsesStake() public {
        vm.prank(alice);
        s.stake(1_000_000e18, 30);
        vm.prank(bob);
        vm.expectRevert(DarkStaking.InsufficientStake.selector);
        s.unstake(1_000_000e18);
        assertEq(s.stakedOf(alice), 1_000_000e18);
    }

    // ---------------------------------------------------------------- tier reading

    function test_tierBalance_countsStakedPlusHeld() public {
        assertEq(s.tierBalance(alice), 10_000_000e18);
        vm.prank(alice);
        s.stake(4_000_000e18, 30);
        assertEq(s.tierBalance(alice), 10_000_000e18, "staking changed the tier balance");
    }

    function test_boost_expiresOnItsOwn() public {
        vm.prank(alice);
        s.stake(1e18, 30);
        assertTrue(s.boostActive(alice));
        vm.warp(block.timestamp + 30 days + 1);
        assertFalse(s.boostActive(alice));
        assertEq(s.stakedOf(alice), 1e18, "maturity moved tokens on its own");
    }

    // ---------------------------------------------------------------- failure modes

    function test_stake_revertsIfTokenTransferFails() public {
        dark.setFail(true);
        vm.prank(alice);
        vm.expectRevert(DarkStaking.TransferFailed.selector);
        s.stake(1e18, 30);
        assertEq(s.totalStaked(), 0);
    }

    // ---------------------------------------------------------------- invariants

    function testFuzz_contractAlwaysCoversTotalStaked(uint96 a, uint96 b) public {
        uint256 amtA = uint256(a) % 10_000_000e18;
        uint256 amtB = uint256(b) % 5_000_000e18;
        if (amtA > 0) {
            vm.prank(alice);
            s.stake(amtA, 30);
        }
        if (amtB > 0) {
            vm.prank(bob);
            s.stake(amtB, 90);
        }
        assertEq(s.totalStaked(), amtA + amtB);
        assertGe(dark.balanceOf(address(s)), s.totalStaked(), "contract holds less than it owes");
    }

    function testFuzz_everyStakeIsFullyRecoverable(uint96 a) public {
        uint256 amt = uint256(a) % 10_000_000e18;
        vm.assume(amt > 0);
        uint256 before = dark.balanceOf(alice);
        vm.prank(alice);
        s.stake(amt, 180);
        vm.prank(alice);
        s.unstake(amt);
        assertEq(dark.balanceOf(alice), before, "tokens went missing on a round trip");
    }
}
