// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IBridgeMessageReceiver {
    function onBridgeMessage(
        uint256 srcChainId,
        address srcSender,
        bytes calldata payload
    ) external;
}
