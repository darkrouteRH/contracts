// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DarkBurner} from "../src/DarkBurner.sol";

/// Mirrors the real token: burnFrom exists, mint does not, no owner.
contract MockBurnableDark {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(uint256 supply, address to) {
        totalSupply = supply;
        balanceOf[to] = supply;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function burnFrom(address account, uint256 amount) external {
        require(balanceOf[account] >= amount, "bal");
        require(allowance[account][msg.sender] >= amount, "allow");
        allowance[account][msg.sender] -= amount;
        balanceOf[account] -= amount;
        totalSupply -= amount;
    }
}

contract DarkBurnerTest is Test {
    MockBurnableDark dark;
    DarkBurner b;
    address treasury = address(0x7EA);
    address stranger = address(0x5EE);
    uint256 constant SUPPLY = 1_000_000_000e18;

    event Burned(address indexed by, uint256 amount, uint256 totalBurned, string note);

    function setUp() public {
        dark = new MockBurnableDark(SUPPLY, treasury);
        b = new DarkBurner(address(dark));
        vm.prank(treasury);
        dark.approve(address(b), type(uint256).max);
    }

    function test_burn_reducesTotalSupplyForReal() public {
        vm.prank(treasury);
        b.burn(1_000_000e18, "fees 2026-09-08");
        assertEq(dark.totalSupply(), SUPPLY - 1_000_000e18, "supply did not actually fall");
        assertEq(dark.balanceOf(treasury), SUPPLY - 1_000_000e18);
        assertEq(b.totalBurned(), 1_000_000e18);
        assertEq(b.burnCount(), 1);
        assertEq(b.burnedBy(treasury), 1_000_000e18);
    }

    /// The contract must never sit on tokens — there is then nothing to steal from it.
    function test_burn_contractNeverHoldsABalance() public {
        vm.prank(treasury);
        b.burn(5_000e18, "x");
        assertEq(dark.balanceOf(address(b)), 0, "burner is holding tokens");
    }

    function test_burn_emitsTheNoteAndRunningTotal() public {
        vm.expectEmit(true, false, false, true);
        emit Burned(treasury, 250e18, 250e18, "desk profit");
        vm.prank(treasury);
        b.burn(250e18, "desk profit");
    }

    function test_burn_accumulatesAcrossCalls() public {
        vm.startPrank(treasury);
        b.burn(100e18, "a");
        b.burn(400e18, "b");
        vm.stopPrank();
        assertEq(b.totalBurned(), 500e18);
        assertEq(b.burnCount(), 2);
        assertEq(dark.totalSupply(), SUPPLY - 500e18);
    }

    /// Separate sources are tracked separately, so the wall can show protocol burns apart.
    function test_burn_tracksEachSourceSeparately() public {
        vm.prank(treasury);
        dark.approve(address(b), type(uint256).max);
        vm.prank(treasury);
        b.burn(300e18, "fees");

        // give the stranger something of their own to burn
        vm.prank(treasury);
        dark.approve(address(this), type(uint256).max);
        dark.burnFrom(treasury, 0); // no-op, keeps the mock honest
        MockBurnableDark d2 = new MockBurnableDark(1000e18, stranger);
        DarkBurner b2 = new DarkBurner(address(d2));
        vm.prank(stranger);
        d2.approve(address(b2), type(uint256).max);
        vm.prank(stranger);
        b2.burn(100e18, "mine");

        assertEq(b.burnedBy(treasury), 300e18);
        assertEq(b.burnedBy(stranger), 0);
        assertEq(b2.burnedBy(stranger), 100e18);
    }

    function test_burn_rejectsZero() public {
        vm.prank(treasury);
        vm.expectRevert(DarkBurner.ZeroAmount.selector);
        b.burn(0, "nothing");
    }

    function test_burn_rejectsOverlongNote() public {
        string memory long = "0123456789012345678901234567890123456789012345678901234567890123456789";
        vm.prank(treasury);
        vm.expectRevert(DarkBurner.NoteTooLong.selector);
        b.burn(1e18, long);
    }

    function test_burn_acceptsNoteAtTheLimit() public {
        string memory exact = "0123456789012345678901234567890123456789012345678901234567890123"; // 64
        assertEq(bytes(exact).length, 64);
        vm.prank(treasury);
        b.burn(1e18, exact);
        assertEq(b.totalBurned(), 1e18);
    }

    /// Accounting must not drift when the token rejects the burn.
    function test_burn_withoutApprovalRevertsAndRecordsNothing() public {
        vm.prank(stranger);
        vm.expectRevert();
        b.burn(1e18, "no allowance");
        assertEq(b.totalBurned(), 0);
        assertEq(b.burnCount(), 0);
    }

    function test_supplyRemaining_tracksTheToken() public {
        assertEq(b.supplyRemaining(), SUPPLY);
        vm.prank(treasury);
        b.burn(1e18, "x");
        assertEq(b.supplyRemaining(), SUPPLY - 1e18);
    }

    function testFuzz_totalBurnedAlwaysMatchesSupplyDrop(uint96 a, uint96 c) public {
        uint256 x = uint256(a) % 1000e18;
        uint256 y = uint256(c) % 1000e18;
        vm.assume(x > 0 && y > 0);
        vm.startPrank(treasury);
        b.burn(x, "1");
        b.burn(y, "2");
        vm.stopPrank();
        assertEq(b.totalBurned(), x + y);
        assertEq(dark.totalSupply(), SUPPLY - b.totalBurned(), "ledger and supply disagree");
    }
}
