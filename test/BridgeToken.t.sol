// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {BridgeToken} from "../src/BridgeToken.sol";

contract BridgeTokenTest is Test {
    BridgeToken token;
    address factory = address(this);
    uint256 remoteChainId = 1;
    address remoteToken = address(0xBEEF);

    function setUp() public {
        token = new BridgeToken(remoteChainId, remoteToken, factory);
        token.initialize("Wrapped BEEF", "wBEEF");
    }

    function test_immutables() public view {
        assertEq(token.remoteChainId(), remoteChainId);
        assertEq(token.remoteToken(), remoteToken);
        assertEq(token.factory(), factory);
    }

    function test_nameAndSymbol() public view {
        assertEq(token.name(), "Wrapped BEEF");
        assertEq(token.symbol(), "wBEEF");
    }

    function test_mint() public {
        token.mint(address(0xCAFE), 100e18);
        assertEq(token.balanceOf(address(0xCAFE)), 100e18);
    }

    function test_burn() public {
        token.mint(address(0xCAFE), 100e18);
        token.burn(address(0xCAFE), 40e18);
        assertEq(token.balanceOf(address(0xCAFE)), 60e18);
    }

    function test_mintRevert_notFactory() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(BridgeToken.OnlyFactory.selector);
        token.mint(address(0xCAFE), 1);
    }

    function test_burnRevert_notFactory() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(BridgeToken.OnlyFactory.selector);
        token.burn(address(0xCAFE), 1);
    }

    function test_initializeRevert_twice() public {
        vm.expectRevert(BridgeToken.AlreadyInitialized.selector);
        token.initialize("X", "Y");
    }

    function test_initializeRevert_notFactory() public {
        BridgeToken t2 = new BridgeToken(1, address(0xBEEF), address(this));
        vm.prank(address(0xDEAD));
        vm.expectRevert(BridgeToken.OnlyFactory.selector);
        t2.initialize("X", "Y");
    }
}
