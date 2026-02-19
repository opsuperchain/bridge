// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IBridgeAdapter {
    function sendMessage(
        uint256 dstChainId,
        address receiver,
        bytes calldata payload
    ) external payable returns (bytes32 messageId);

    function estimateFee(
        uint256 dstChainId,
        address receiver,
        bytes calldata payload
    ) external view returns (uint256);
}
