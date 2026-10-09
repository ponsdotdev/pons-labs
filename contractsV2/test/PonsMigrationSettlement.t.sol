// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PonsMigrationSettlement} from "../src/v2/testing/migr/PonsMigrationSettlement.sol";

interface Vm {
    function expectRevert(bytes4 selector) external;
    function prank(address sender) external;
    function warp(uint256 timestamp) external;
}

contract TestToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TaxToken is TestToken {
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - 1;
        return true;
    }
}

contract PonsMigrationSettlementTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant RECIPIENT_A = address(0xA11CE);
    address private constant RECIPIENT_B = address(0xB0B);
    address private constant LP_RECIPIENT = address(0x1A);
    bytes32 private constant CAMPAIGN = keccak256("campaign");

    TestToken private token;
    PonsMigrationSettlement private settlement;

    function setUp() public {
        token = new TestToken();
        settlement =
            new PonsMigrationSettlement(address(token), LP_RECIPIENT, CAMPAIGN, uint64(block.timestamp + 7 days));
        token.mint(address(this), 1_000 ether);
        token.approve(address(settlement), type(uint256).max);
    }

    function testFundIsSponsorOnlyAndExact() public {
        settlement.fund(100 ether);
        _assertEq(token.balanceOf(address(settlement)), 100 ether);

        vm.prank(RECIPIENT_A);
        vm.expectRevert(PonsMigrationSettlement.Unauthorized.selector);
        settlement.fund(1 ether);
    }

    function testFundRejectsTransferTaxToken() public {
        TaxToken taxed = new TaxToken();
        PonsMigrationSettlement taxedSettlement =
            new PonsMigrationSettlement(address(taxed), LP_RECIPIENT, CAMPAIGN, uint64(block.timestamp + 7 days));
        taxed.mint(address(this), 10 ether);
        taxed.approve(address(taxedSettlement), type(uint256).max);

        vm.expectRevert(PonsMigrationSettlement.UnsupportedToken.selector);
        taxedSettlement.fund(10 ether);
        _assertEq(taxed.balanceOf(address(taxedSettlement)), 0);
    }

    function testFinalizeAndClaimTwoLeafTree() public {
        uint256 amountA = 30 ether;
        uint256 amountB = 20 ether;
        bytes32 leafA = _leaf(0, RECIPIENT_A, amountA);
        bytes32 leafB = _leaf(1, RECIPIENT_B, amountB);
        bytes32 root = _hashPair(leafA, leafB);

        settlement.fund(75 ether);
        settlement.finalize(root, amountA + amountB, 25 ether);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        settlement.claim(0, RECIPIENT_A, amountA, proof);

        _assertEq(token.balanceOf(RECIPIENT_A), amountA);
        _assertEq(settlement.claimed(), amountA);
        _assertTrue(settlement.claimedIndex(0));

        vm.expectRevert(PonsMigrationSettlement.AlreadyClaimed.selector);
        settlement.claim(0, RECIPIENT_A, amountA, proof);
    }

    function testClaimRejectsInvalidProof() public {
        bytes32 leaf = _leaf(0, RECIPIENT_A, 10 ether);
        settlement.fund(20 ether);
        settlement.finalize(leaf, 10 ether, 10 ether);

        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = bytes32(uint256(1));
        vm.expectRevert(PonsMigrationSettlement.InvalidProof.selector);
        settlement.claim(0, RECIPIENT_A, 10 ether, badProof);
    }

    function testReleaseLiquidityIsOneShot() public {
        settlement.fund(20 ether);
        settlement.finalize(bytes32(uint256(1)), 10 ether, 10 ether);
        settlement.releaseLiquidity();

        _assertEq(token.balanceOf(LP_RECIPIENT), 10 ether);
        vm.expectRevert(PonsMigrationSettlement.InvalidState.selector);
        settlement.releaseLiquidity();
    }

    function testRecoverExcessPreservesAllReserves() public {
        settlement.fund(25 ether);
        settlement.finalize(bytes32(uint256(1)), 10 ether, 10 ether);
        token.mint(address(settlement), 5 ether);

        settlement.recoverExcess();
        _assertEq(token.balanceOf(address(settlement)), 20 ether);
        _assertEq(token.balanceOf(address(this)), 985 ether);
    }

    function testCancelOnlyAfterDeadline() public {
        settlement.fund(20 ether);
        vm.expectRevert(PonsMigrationSettlement.InvalidState.selector);
        settlement.cancel();

        vm.warp(block.timestamp + 7 days + 1);
        settlement.cancel();
        _assertEq(token.balanceOf(address(settlement)), 0);
        _assertEq(token.balanceOf(address(this)), 1_000 ether);
    }

    function testFinalizeCannotOverReserveOrRunTwice() public {
        settlement.fund(20 ether);
        vm.expectRevert(PonsMigrationSettlement.InvalidInput.selector);
        settlement.finalize(bytes32(uint256(1)), 11 ether, 10 ether);

        settlement.finalize(bytes32(uint256(1)), 10 ether, 10 ether);
        vm.expectRevert(PonsMigrationSettlement.InvalidState.selector);
        settlement.finalize(bytes32(uint256(2)), 10 ether, 10 ether);
    }

    function _leaf(uint256 index, address recipient, uint256 amount) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(settlement), CAMPAIGN, index, recipient, amount));
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _assertEq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "not equal");
    }

    function _assertTrue(bool value) private pure {
        require(value, "not true");
    }
}
