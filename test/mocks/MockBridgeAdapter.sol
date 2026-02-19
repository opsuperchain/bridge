// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";
import {IBridgeMessageReceiver} from "../../src/interfaces/IBridgeMessageReceiver.sol";
import {BridgeTokenFactory} from "../../src/BridgeTokenFactory.sol";
import {TokenVault} from "../../src/TokenVault.sol";

/// @notice Mock adapter that stores pending messages and lets tests deliver them.
contract MockBridgeAdapter is IBridgeAdapter {
    struct Message {
        uint256 srcChainId;
        address srcSender;
        uint256 dstChainId;
        address receiver;
        bytes payload;
        bool delivered;
    }

    Message[] public messages;
    uint256 public mockChainId;

    constructor(uint256 mockChainId_) {
        mockChainId = mockChainId_;
    }

    function setMockChainId(uint256 newChainId) external {
        mockChainId = newChainId;
    }

    function sendMessage(
        uint256 dstChainId,
        address receiver,
        bytes calldata payload
    ) external payable override returns (bytes32 messageId) {
        messages.push(Message({
            srcChainId: mockChainId,
            srcSender: msg.sender,
            dstChainId: dstChainId,
            receiver: receiver,
            payload: payload,
            delivered: false
        }));
        return bytes32(messages.length - 1);
    }

    function estimateFee(uint256, address, bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    function messageCount() external view returns (uint256) {
        return messages.length;
    }

    function registerVault(address factory, uint256 remoteChainId, address vault) external {
        BridgeTokenFactory(payable(factory)).registerVault(remoteChainId, vault);
    }

    function registerFactory(address vault, uint256 localChainId, address factory) external {
        TokenVault(payable(vault)).registerFactory(localChainId, factory);
    }

    function deliverMessage(uint256 index) external {
        Message storage m = messages[index];
        require(!m.delivered, "already delivered");
        m.delivered = true;
        IBridgeMessageReceiver(m.receiver).onBridgeMessage(m.srcChainId, m.srcSender, m.payload);
    }
}
