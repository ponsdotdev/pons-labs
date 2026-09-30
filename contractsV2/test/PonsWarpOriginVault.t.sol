// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PonsWarpOriginVault} from "../src/v2/testing/warp/PonsWarpOriginVault.sol";

interface Vm {
    function addr(uint256 privateKey) external returns (address);
    function expectRevert(bytes4 selector) external;
    function prank(address sender) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 timestamp) external;
}

contract WarpTestToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
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

contract WarpTaxToken is WarpTestToken {
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - 1;
        return true;
    }
}

contract PonsWarpOriginVaultTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 private constant RELEASE_TYPEHASH =
        keccak256("Release(bytes32 burnId,bytes32 solanaMint,address recipient,uint256 amount,uint256 deadline)");
    bytes32 private constant MINT = keccak256("solana mint");
    bytes32 private constant SOLANA_RECIPIENT = keccak256("solana recipient");
    address private constant RECIPIENT = address(0xA11CE);
    uint256 private constant VALIDATOR_KEY_A = 0xA11CE;
    uint256 private constant VALIDATOR_KEY_B = 0xB0B;

    WarpTestToken private token;
    PonsWarpOriginVault private vault;

    function setUp() public {
        token = new WarpTestToken();
        address[] memory validators = new address[](2);
        validators[0] = vm.addr(VALIDATOR_KEY_A);
        validators[1] = vm.addr(VALIDATOR_KEY_B);
        vault = new PonsWarpOriginVault(address(token), MINT, address(this), validators, 2);
        token.mint(address(this), 100 ether);
        token.approve(address(vault), type(uint256).max);
    }

    function testDepositTracksSequentialIdsAndExactBalance() public {
        uint256 first = vault.deposit(10 ether, SOLANA_RECIPIENT);
        uint256 second = vault.deposit(5 ether, bytes32(uint256(2)));

        _assertEq(first, 0);
        _assertEq(second, 1);
        _assertEq(vault.nextDepositId(), 2);
        _assertEq(token.balanceOf(address(vault)), 15 ether);
    }

    function testDepositRejectsTaxedTransfer() public {
        WarpTaxToken taxed = new WarpTaxToken();
        address[] memory validators = new address[](1);
        validators[0] = vm.addr(VALIDATOR_KEY_A);
        PonsWarpOriginVault taxedVault = new PonsWarpOriginVault(address(taxed), MINT, address(this), validators, 1);
        taxed.mint(address(this), 10 ether);
        taxed.approve(address(taxedVault), type(uint256).max);

        vm.expectRevert(PonsWarpOriginVault.UnsupportedToken.selector);
        taxedVault.deposit(10 ether, SOLANA_RECIPIENT);
        _assertEq(taxed.balanceOf(address(taxedVault)), 0);
    }

    function testOnlyControllerCanPauseAndPausedVaultRejectsDeposits() public {
        vm.prank(RECIPIENT);
        vm.expectRevert(PonsWarpOriginVault.Unauthorized.selector);
        vault.setDepositsPaused(true);

        vault.setDepositsPaused(true);
        vm.expectRevert(PonsWarpOriginVault.InvalidState.selector);
        vault.deposit(1 ether, SOLANA_RECIPIENT);
    }

    function testReleaseRequiresSortedQuorumAndCannotReplay() public {
        vault.deposit(20 ether, SOLANA_RECIPIENT);
        bytes32 burnId = keccak256("burn one");
        uint256 deadline = block.timestamp + 1 days;
        bytes[] memory signatures = _sortedSignatures(burnId, RECIPIENT, 7 ether, deadline);

        vault.release(burnId, RECIPIENT, 7 ether, deadline, signatures);
        _assertEq(token.balanceOf(RECIPIENT), 7 ether);
        _assertEq(token.balanceOf(address(vault)), 13 ether);
        _assertTrue(vault.usedBurn(burnId));

        vm.expectRevert(PonsWarpOriginVault.InvalidState.selector);
        vault.release(burnId, RECIPIENT, 7 ether, deadline, signatures);
    }

    function testReleaseRejectsInsufficientAndUnsortedSignatures() public {
        vault.deposit(20 ether, SOLANA_RECIPIENT);
        bytes32 burnId = keccak256("burn two");
        uint256 deadline = block.timestamp + 1 days;
        bytes[] memory sorted = _sortedSignatures(burnId, RECIPIENT, 7 ether, deadline);
        bytes[] memory one = new bytes[](1);
        one[0] = sorted[0];

        vm.expectRevert(PonsWarpOriginVault.InsufficientQuorum.selector);
        vault.release(burnId, RECIPIENT, 7 ether, deadline, one);

        bytes memory swap = sorted[0];
        sorted[0] = sorted[1];
        sorted[1] = swap;
        vm.expectRevert(PonsWarpOriginVault.InvalidSignature.selector);
        vault.release(burnId, RECIPIENT, 7 ether, deadline, sorted);
    }

    function testReleaseSignatureBindsRecipientAmountAndDomain() public {
        vault.deposit(20 ether, SOLANA_RECIPIENT);
        bytes32 burnId = keccak256("burn three");
        uint256 deadline = block.timestamp + 1 days;
        bytes[] memory signatures = _sortedSignatures(burnId, RECIPIENT, 7 ether, deadline);

        vm.expectRevert(PonsWarpOriginVault.InvalidSignature.selector);
        vault.release(burnId, address(0xBEEF), 7 ether, deadline, signatures);
        vm.expectRevert(PonsWarpOriginVault.InvalidSignature.selector);
        vault.release(burnId, RECIPIENT, 8 ether, deadline, signatures);
    }

    function testExpiredReleaseDoesNotConsumeBurnId() public {
        vault.deposit(20 ether, SOLANA_RECIPIENT);
        bytes32 burnId = keccak256("burn four");
        uint256 deadline = block.timestamp + 1 days;
        bytes[] memory signatures = _sortedSignatures(burnId, RECIPIENT, 7 ether, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(PonsWarpOriginVault.InvalidInput.selector);
        vault.release(burnId, RECIPIENT, 7 ether, deadline, signatures);
        _assertTrue(!vault.usedBurn(burnId));
    }

    function _sortedSignatures(bytes32 burnId, address recipient, uint256 amount, uint256 deadline)
        private
        returns (bytes[] memory signatures)
    {
        bytes32 structHash = keccak256(abi.encode(RELEASE_TYPEHASH, burnId, MINT, recipient, amount, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        bytes memory signatureA = _sign(VALIDATOR_KEY_A, digest);
        bytes memory signatureB = _sign(VALIDATOR_KEY_B, digest);
        signatures = new bytes[](2);
        if (vm.addr(VALIDATOR_KEY_A) < vm.addr(VALIDATOR_KEY_B)) {
            signatures[0] = signatureA;
            signatures[1] = signatureB;
        } else {
            signatures[0] = signatureB;
            signatures[1] = signatureA;
        }
    }

    function _sign(uint256 privateKey, bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _assertEq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "not equal");
    }

    function _assertTrue(bool value) private pure {
        require(value, "not true");
    }
}
