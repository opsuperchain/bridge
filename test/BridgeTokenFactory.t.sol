// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {BridgeTokenFactory} from "../src/BridgeTokenFactory.sol";
import {BridgeToken} from "../src/BridgeToken.sol";
import {MockBridgeAdapter} from "./mocks/MockBridgeAdapter.sol";

contract BridgeTokenFactoryTest is Test {
    BridgeTokenFactory factory;
    MockBridgeAdapter adapter;

    uint256 constant REMOTE_CHAIN = 1;
    address constant VAULT = address(0xAA17);
    address constant REMOTE_TOKEN = address(0xBEEF);
    address constant RECIPIENT = address(0xCAFE);

    function setUp() public {
        factory = new BridgeTokenFactory();
        adapter = new MockBridgeAdapter(REMOTE_CHAIN);
        adapter.registerVault(address(factory), REMOTE_CHAIN, VAULT);
    }

    function test_registerVault() public view {
        assertEq(factory.vaults(address(adapter), REMOTE_CHAIN), VAULT);
    }

    function test_registerVaultRevert_alreadySet() public {
        vm.expectRevert(BridgeTokenFactory.VaultAlreadyRegistered.selector);
        adapter.registerVault(address(factory), REMOTE_CHAIN, address(0x1234));
    }

    function test_registerVaultRevert_zeroAddress() public {
        MockBridgeAdapter adapter2 = new MockBridgeAdapter(REMOTE_CHAIN);
        vm.expectRevert(BridgeTokenFactory.ZeroAddress.selector);
        adapter2.registerVault(address(factory), 999, address(0));
    }

    function test_computeAddress_matchesDeployment() public {
        address predicted = factory.computeAddress(REMOTE_CHAIN, REMOTE_TOKEN, address(adapter));

        bytes memory payload = abi.encode(REMOTE_TOKEN, RECIPIENT, 100e18, "Test Token", "TT");
        vm.prank(address(adapter));
        factory.onBridgeMessage(REMOTE_CHAIN, VAULT, payload);

        bytes32 salt = factory.computeSalt(REMOTE_CHAIN, REMOTE_TOKEN, address(adapter));
        address deployed = factory.deployedTokens(salt);
        assertEq(deployed, predicted);
    }

    function test_onBridgeMessage_deploysAndMints() public {
        bytes memory payload = abi.encode(REMOTE_TOKEN, RECIPIENT, 50e18, "Remote Token", "RT");

        vm.prank(address(adapter));
        factory.onBridgeMessage(REMOTE_CHAIN, VAULT, payload);

        bytes32 salt = factory.computeSalt(REMOTE_CHAIN, REMOTE_TOKEN, address(adapter));
        address tokenAddr = factory.deployedTokens(salt);
        assertTrue(tokenAddr != address(0));

        BridgeToken token = BridgeToken(tokenAddr);
        assertEq(token.balanceOf(RECIPIENT), 50e18);
        assertEq(token.name(), "Remote Token");
        assertEq(token.symbol(), "RT");
        assertEq(token.remoteChainId(), REMOTE_CHAIN);
        assertEq(token.remoteToken(), REMOTE_TOKEN);
        assertEq(token.factory(), address(factory));
    }

    function test_onBridgeMessage_secondMintNoRedeploy() public {
        bytes memory payload = abi.encode(REMOTE_TOKEN, RECIPIENT, 50e18, "RT", "RT");

        vm.prank(address(adapter));
        factory.onBridgeMessage(REMOTE_CHAIN, VAULT, payload);

        bytes32 salt = factory.computeSalt(REMOTE_CHAIN, REMOTE_TOKEN, address(adapter));
        address firstAddr = factory.deployedTokens(salt);

        vm.prank(address(adapter));
        factory.onBridgeMessage(REMOTE_CHAIN, VAULT, payload);

        address secondAddr = factory.deployedTokens(salt);
        assertEq(firstAddr, secondAddr);
        assertEq(BridgeToken(firstAddr).balanceOf(RECIPIENT), 100e18);
    }

    function test_onBridgeMessageRevert_unknownAdapter() public {
        bytes memory payload = abi.encode(REMOTE_TOKEN, RECIPIENT, 1e18, "T", "T");
        vm.prank(address(0xBAD));
        vm.expectRevert(BridgeTokenFactory.UnknownAdapter.selector);
        factory.onBridgeMessage(REMOTE_CHAIN, VAULT, payload);
    }

    function test_onBridgeMessageRevert_wrongVault() public {
        bytes memory payload = abi.encode(REMOTE_TOKEN, RECIPIENT, 1e18, "T", "T");
        vm.prank(address(adapter));
        vm.expectRevert(BridgeTokenFactory.VaultNotRegistered.selector);
        factory.onBridgeMessage(REMOTE_CHAIN, address(0xBAD), payload);
    }

    function test_onBridgeMessageRevert_zeroAmount() public {
        bytes memory payload = abi.encode(REMOTE_TOKEN, RECIPIENT, 0, "T", "T");
        vm.prank(address(adapter));
        vm.expectRevert(BridgeTokenFactory.ZeroAmount.selector);
        factory.onBridgeMessage(REMOTE_CHAIN, VAULT, payload);
    }

    function test_bridgeBack() public {
        bytes memory inPayload = abi.encode(REMOTE_TOKEN, address(this), 100e18, "Token", "TK");
        vm.prank(address(adapter));
        factory.onBridgeMessage(REMOTE_CHAIN, VAULT, inPayload);

        bytes32 salt = factory.computeSalt(REMOTE_CHAIN, REMOTE_TOKEN, address(adapter));
        address tokenAddr = factory.deployedTokens(salt);

        factory.bridgeBack(tokenAddr, 30e18, RECIPIENT);

        assertEq(BridgeToken(tokenAddr).balanceOf(address(this)), 70e18);
        assertEq(adapter.messageCount(), 1);
    }

    function test_bridgeBackRevert_invalidToken() public {
        vm.expectRevert(BridgeTokenFactory.InvalidToken.selector);
        factory.bridgeBack(address(0x1234), 1e18, RECIPIENT);
    }

    function test_bridgeBackRevert_zeroAmount() public {
        bytes memory inPayload = abi.encode(REMOTE_TOKEN, address(this), 100e18, "Token", "TK");
        vm.prank(address(adapter));
        factory.onBridgeMessage(REMOTE_CHAIN, VAULT, inPayload);

        bytes32 salt = factory.computeSalt(REMOTE_CHAIN, REMOTE_TOKEN, address(adapter));
        address tokenAddr = factory.deployedTokens(salt);

        vm.expectRevert(BridgeTokenFactory.ZeroAmount.selector);
        factory.bridgeBack(tokenAddr, 0, RECIPIENT);
    }

    function test_bridgeBackRevert_zeroRecipient() public {
        bytes memory inPayload = abi.encode(REMOTE_TOKEN, address(this), 100e18, "Token", "TK");
        vm.prank(address(adapter));
        factory.onBridgeMessage(REMOTE_CHAIN, VAULT, inPayload);

        bytes32 salt = factory.computeSalt(REMOTE_CHAIN, REMOTE_TOKEN, address(adapter));
        address tokenAddr = factory.deployedTokens(salt);

        vm.expectRevert(BridgeTokenFactory.ZeroAddress.selector);
        factory.bridgeBack(tokenAddr, 10e18, address(0));
    }
}
