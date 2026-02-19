// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {BridgeTokenFactory} from "../src/BridgeTokenFactory.sol";
import {TokenVault} from "../src/TokenVault.sol";
import {BridgeToken} from "../src/BridgeToken.sol";
import {MockBridgeAdapter} from "./mocks/MockBridgeAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Full round-trip: lock → deliver → mint → burn → deliver → unlock
contract EndToEndTest is Test {
    BridgeTokenFactory factory;
    TokenVault vault;
    MockERC20 remoteERC20;
    MockBridgeAdapter adapter;

    uint256 constant REMOTE_CHAIN = 1;
    uint256 constant LOCAL_CHAIN = 10;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        factory = new BridgeTokenFactory();
        vault = new TokenVault();
        remoteERC20 = new MockERC20("Virtuals", "VIRTUAL");

        // Single adapter — we switch mockChainId to simulate each direction
        adapter = new MockBridgeAdapter(REMOTE_CHAIN);

        // Adapter registers itself on both sides
        adapter.registerVault(address(factory), REMOTE_CHAIN, address(vault));
        adapter.registerFactory(address(vault), LOCAL_CHAIN, address(factory));
    }

    function test_fullRoundTrip() public {
        // --- Bridge In: Remote → Local ---

        // Alice has 1000 VIRTUAL on remote chain
        remoteERC20.mint(alice, 1000e18);

        // Adapter is on the remote chain (srcChainId = REMOTE_CHAIN)
        adapter.setMockChainId(REMOTE_CHAIN);

        // Alice approves vault and bridges 500 VIRTUAL
        vm.startPrank(alice);
        remoteERC20.approve(address(vault), 500e18);
        vault.bridge(address(remoteERC20), 500e18, address(adapter), LOCAL_CHAIN, alice);
        vm.stopPrank();

        // Vault now holds 500 VIRTUAL
        assertEq(remoteERC20.balanceOf(address(vault)), 500e18);
        assertEq(remoteERC20.balanceOf(alice), 500e18);

        // Predict the wrapped token address
        address predicted = factory.computeAddress(REMOTE_CHAIN, address(remoteERC20), address(adapter));

        // Deliver the message (simulates cross-chain relay)
        adapter.deliverMessage(0);

        // Verify BridgeToken was deployed and minted
        bytes32 salt = factory.computeSalt(REMOTE_CHAIN, address(remoteERC20), address(adapter));
        address wrappedAddr = factory.deployedTokens(salt);
        assertEq(wrappedAddr, predicted);

        BridgeToken wrapped = BridgeToken(wrappedAddr);
        assertEq(wrapped.balanceOf(alice), 500e18);
        assertEq(wrapped.name(), "Virtuals");
        assertEq(wrapped.symbol(), "VIRTUAL");
        assertEq(wrapped.remoteChainId(), REMOTE_CHAIN);
        assertEq(wrapped.remoteToken(), address(remoteERC20));

        // --- Bridge Out: Local → Remote ---

        // Switch adapter to local chain for return messages
        adapter.setMockChainId(LOCAL_CHAIN);

        // Alice bridges 200 wrapped VIRTUAL back
        vm.prank(alice);
        factory.bridgeBack(wrappedAddr, 200e18, alice);

        // Wrapped tokens were burned
        assertEq(wrapped.balanceOf(alice), 300e18);

        // Deliver the return message to the vault
        adapter.deliverMessage(1);

        // Alice's original tokens are unlocked
        assertEq(remoteERC20.balanceOf(alice), 700e18);
        assertEq(remoteERC20.balanceOf(address(vault)), 300e18);
    }

    function test_bridgeToRecipient() public {
        adapter.setMockChainId(REMOTE_CHAIN);

        remoteERC20.mint(alice, 100e18);

        vm.startPrank(alice);
        remoteERC20.approve(address(vault), 100e18);
        vault.bridge(address(remoteERC20), 100e18, address(adapter), LOCAL_CHAIN, bob);
        vm.stopPrank();

        adapter.deliverMessage(0);

        bytes32 salt = factory.computeSalt(REMOTE_CHAIN, address(remoteERC20), address(adapter));
        address wrappedAddr = factory.deployedTokens(salt);
        assertEq(BridgeToken(wrappedAddr).balanceOf(bob), 100e18);
    }

    function test_multipleBridgesShareToken() public {
        adapter.setMockChainId(REMOTE_CHAIN);

        remoteERC20.mint(alice, 200e18);

        vm.startPrank(alice);
        remoteERC20.approve(address(vault), 200e18);
        vault.bridge(address(remoteERC20), 100e18, address(adapter), LOCAL_CHAIN, alice);
        vault.bridge(address(remoteERC20), 100e18, address(adapter), LOCAL_CHAIN, bob);
        vm.stopPrank();

        adapter.deliverMessage(0);
        adapter.deliverMessage(1);

        bytes32 salt = factory.computeSalt(REMOTE_CHAIN, address(remoteERC20), address(adapter));
        address wrappedAddr = factory.deployedTokens(salt);
        assertEq(BridgeToken(wrappedAddr).balanceOf(alice), 100e18);
        assertEq(BridgeToken(wrappedAddr).balanceOf(bob), 100e18);
    }
}
