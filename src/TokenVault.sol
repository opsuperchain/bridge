// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBridgeAdapter} from "./interfaces/IBridgeAdapter.sol";
import {IBridgeMessageReceiver} from "./interfaces/IBridgeMessageReceiver.sol";

/// @title TokenVault
/// @notice Locks/unlocks ERC20 tokens on a remote (spoke) chain.
///         Paired with a BridgeTokenFactory on the local (hub) chain.
///         Fully permissionless: anyone can register factory pairings (immutable once set).
contract TokenVault is IBridgeMessageReceiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice adapter => localChainId => trusted factory address
    mapping(address => mapping(uint256 => address)) public factories;

    error FactoryAlreadyRegistered();
    error FactoryNotRegistered();
    error UnknownAdapter();
    error ZeroAddress();
    error ZeroAmount();

    event FactoryRegistered(address indexed adapter, uint256 indexed localChainId, address factory);
    event TokensLocked(address indexed token, address indexed sender, uint256 amount, uint256 dstChainId, address recipient);
    event TokensUnlocked(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Register a trusted factory for an adapter + local chain pair.
    ///         Only the adapter itself can register (msg.sender = adapter). Immutable once set.
    function registerFactory(uint256 localChainId, address factory) external {
        if (factory == address(0)) revert ZeroAddress();
        address adapter = msg.sender;
        if (factories[adapter][localChainId] != address(0)) revert FactoryAlreadyRegistered();
        factories[adapter][localChainId] = factory;
        emit FactoryRegistered(adapter, localChainId, factory);
    }

    /// @notice Lock tokens and send a bridge message to the factory on the local chain.
    function bridge(
        address token,
        uint256 amount,
        address adapter,
        uint256 dstChainId,
        address recipient
    ) external payable nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        address factory = factories[adapter][dstChainId];
        if (factory == address(0)) revert FactoryNotRegistered();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = IERC20(token).balanceOf(address(this)) - balanceBefore;

        string memory tokenName = IERC20Metadata(token).name();
        string memory tokenSymbol = IERC20Metadata(token).symbol();

        bytes memory payload = abi.encode(token, recipient, actualAmount, tokenName, tokenSymbol);
        IBridgeAdapter(adapter).sendMessage{value: msg.value}(dstChainId, factory, payload);

        emit TokensLocked(token, msg.sender, actualAmount, dstChainId, recipient);
    }

    /// @notice Called by an adapter to deliver a bridge-back message from the factory.
    function onBridgeMessage(uint256 srcChainId, address srcSender, bytes calldata payload) external override nonReentrant {
        address adapter = msg.sender;
        address factory = factories[adapter][srcChainId];
        if (factory == address(0)) revert UnknownAdapter();
        if (srcSender != factory) revert FactoryNotRegistered();

        (address token, address recipient, uint256 amount) =
            abi.decode(payload, (address, address, uint256));

        IERC20(token).safeTransfer(recipient, amount);

        emit TokensUnlocked(token, recipient, amount);
    }

    /// @notice Accept ETH refunds from adapters (e.g. LZ excess fee refund).
    receive() external payable {}
}
