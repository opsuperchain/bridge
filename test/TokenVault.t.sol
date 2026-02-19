// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {TokenVault} from "../src/TokenVault.sol";
import {MockBridgeAdapter} from "./mocks/MockBridgeAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TokenVaultTest is Test {
    TokenVault vault;
    MockBridgeAdapter adapter;
    MockERC20 token;

    uint256 constant LOCAL_CHAIN = 10;
    uint256 constant REMOTE_CHAIN = 1;
    address constant FACTORY = address(0xFAC7);
    address constant RECIPIENT = address(0xCAFE);

    function setUp() public {
        vault = new TokenVault();
        adapter = new MockBridgeAdapter(REMOTE_CHAIN);
        token = new MockERC20("Test Token", "TT");
        adapter.registerFactory(address(vault), LOCAL_CHAIN, FACTORY);
    }

    function test_registerFactory() public view {
        assertEq(vault.factories(address(adapter), LOCAL_CHAIN), FACTORY);
    }

    function test_registerFactoryRevert_alreadySet() public {
        vm.expectRevert(TokenVault.FactoryAlreadyRegistered.selector);
        adapter.registerFactory(address(vault), LOCAL_CHAIN, address(0x1234));
    }

    function test_registerFactoryRevert_zeroAddress() public {
        MockBridgeAdapter adapter2 = new MockBridgeAdapter(REMOTE_CHAIN);
        vm.expectRevert(TokenVault.ZeroAddress.selector);
        adapter2.registerFactory(address(vault), 999, address(0));
    }

    function test_bridge() public {
        token.mint(address(this), 100e18);
        token.approve(address(vault), 100e18);

        vault.bridge(address(token), 50e18, address(adapter), LOCAL_CHAIN, RECIPIENT);

        assertEq(token.balanceOf(address(this)), 50e18);
        assertEq(token.balanceOf(address(vault)), 50e18);
        assertEq(adapter.messageCount(), 1);
    }

    function test_bridgeRevert_noFactory() public {
        MockBridgeAdapter adapter2 = new MockBridgeAdapter(REMOTE_CHAIN);
        token.mint(address(this), 100e18);
        token.approve(address(vault), 100e18);

        vm.expectRevert(TokenVault.FactoryNotRegistered.selector);
        vault.bridge(address(token), 50e18, address(adapter2), LOCAL_CHAIN, RECIPIENT);
    }

    function test_bridgeRevert_zeroAmount() public {
        token.mint(address(this), 100e18);
        token.approve(address(vault), 100e18);

        vm.expectRevert(TokenVault.ZeroAmount.selector);
        vault.bridge(address(token), 0, address(adapter), LOCAL_CHAIN, RECIPIENT);
    }

    function test_bridgeRevert_zeroRecipient() public {
        token.mint(address(this), 100e18);
        token.approve(address(vault), 100e18);

        vm.expectRevert(TokenVault.ZeroAddress.selector);
        vault.bridge(address(token), 50e18, address(adapter), LOCAL_CHAIN, address(0));
    }

    function test_onBridgeMessage_unlocks() public {
        token.mint(address(vault), 100e18);

        bytes memory payload = abi.encode(address(token), RECIPIENT, 30e18);
        vm.prank(address(adapter));
        vault.onBridgeMessage(LOCAL_CHAIN, FACTORY, payload);

        assertEq(token.balanceOf(RECIPIENT), 30e18);
        assertEq(token.balanceOf(address(vault)), 70e18);
    }

    function test_onBridgeMessageRevert_unknownAdapter() public {
        bytes memory payload = abi.encode(address(token), RECIPIENT, 1e18);
        vm.prank(address(0xBAD));
        vm.expectRevert(TokenVault.UnknownAdapter.selector);
        vault.onBridgeMessage(LOCAL_CHAIN, FACTORY, payload);
    }

    function test_onBridgeMessageRevert_wrongFactory() public {
        bytes memory payload = abi.encode(address(token), RECIPIENT, 1e18);
        vm.prank(address(adapter));
        vm.expectRevert(TokenVault.FactoryNotRegistered.selector);
        vault.onBridgeMessage(LOCAL_CHAIN, address(0xBAD), payload);
    }
}
