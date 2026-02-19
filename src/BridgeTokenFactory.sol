// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBridgeAdapter} from "./interfaces/IBridgeAdapter.sol";
import {IBridgeMessageReceiver} from "./interfaces/IBridgeMessageReceiver.sol";
import {BridgeToken} from "./BridgeToken.sol";

/// @title BridgeTokenFactory
/// @notice Deploys wrapped BridgeTokens via CREATE2 and handles bridge messages.
///         Lives on the local (hub) chain — OP Mainnet.
///         Fully permissionless: anyone can register vault pairings (immutable once set).
contract BridgeTokenFactory is IBridgeMessageReceiver, ReentrancyGuard {
    /// @notice salt => deployed BridgeToken address
    mapping(bytes32 => address) public deployedTokens;

    /// @notice adapter => remoteChainId => trusted vault address
    mapping(address => mapping(uint256 => address)) public vaults;

    /// @notice wrappedToken => adapter that created it
    mapping(address => address) public tokenAdapter;

    error VaultAlreadyRegistered();
    error VaultNotRegistered();
    error UnknownAdapter();
    error InvalidToken();
    error ZeroAddress();
    error ZeroAmount();

    event VaultRegistered(address indexed adapter, uint256 indexed remoteChainId, address vault);
    event TokenDeployed(address indexed token, uint256 indexed remoteChainId, address indexed remoteToken, address adapter);
    event TokensMinted(address indexed token, address indexed recipient, uint256 amount);
    event BridgedBack(address indexed token, address indexed recipient, uint256 amount, uint256 remoteChainId);

    /// @notice Register a trusted vault for an adapter + remote chain pair.
    ///         Only the adapter itself can register (msg.sender = adapter). Immutable once set.
    function registerVault(uint256 remoteChainId, address vault) external {
        if (vault == address(0)) revert ZeroAddress();
        address adapter = msg.sender;
        if (vaults[adapter][remoteChainId] != address(0)) revert VaultAlreadyRegistered();
        vaults[adapter][remoteChainId] = vault;
        emit VaultRegistered(adapter, remoteChainId, vault);
    }

    /// @notice Compute the CREATE2 salt for a (remoteChainId, remoteToken, adapter) tuple.
    function computeSalt(uint256 remoteChainId, address remoteToken, address adapter) public pure returns (bytes32) {
        return keccak256(abi.encode(remoteChainId, remoteToken, adapter));
    }

    /// @notice Compute the deterministic address for a BridgeToken before deployment.
    function computeAddress(uint256 remoteChainId, address remoteToken, address adapter) public view returns (address) {
        bytes32 salt = computeSalt(remoteChainId, remoteToken, adapter);
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(
                    abi.encodePacked(
                        type(BridgeToken).creationCode,
                        abi.encode(remoteChainId, remoteToken, address(this))
                    )
                )
            )
        );
        return address(uint160(uint256(hash)));
    }

    /// @notice Called by an adapter to deliver a bridge-in message from a remote vault.
    function onBridgeMessage(uint256 srcChainId, address srcSender, bytes calldata payload) external override nonReentrant {
        address adapter = msg.sender;
        if (vaults[adapter][srcChainId] == address(0)) revert UnknownAdapter();
        if (srcSender != vaults[adapter][srcChainId]) revert VaultNotRegistered();

        _processIncoming(srcChainId, adapter, payload);
    }

    /// @notice Burn wrapped tokens and send a bridge-out message to unlock on the remote chain.
    function bridgeBack(address wrappedToken, uint256 amount, address recipient) external payable nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        address adapter = tokenAdapter[wrappedToken];
        if (adapter == address(0)) revert InvalidToken();

        BridgeToken token = BridgeToken(wrappedToken);
        uint256 remoteChainId = token.remoteChainId();
        address remoteToken = token.remoteToken();

        address vault = vaults[adapter][remoteChainId];
        if (vault == address(0)) revert VaultNotRegistered();

        token.burn(msg.sender, amount);

        bytes memory payload = abi.encode(remoteToken, recipient, amount);
        IBridgeAdapter(adapter).sendMessage{value: msg.value}(remoteChainId, vault, payload);

        emit BridgedBack(wrappedToken, recipient, amount, remoteChainId);
    }

    function _processIncoming(uint256 srcChainId, address adapter, bytes calldata payload) internal {
        (address remoteToken, address recipient, uint256 amount, string memory tokenName, string memory tokenSymbol) =
            abi.decode(payload, (address, address, uint256, string, string));

        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        bytes32 salt = computeSalt(srcChainId, remoteToken, adapter);
        address token = deployedTokens[salt];

        if (token == address(0)) {
            token = address(new BridgeToken{salt: salt}(srcChainId, remoteToken, address(this)));
            BridgeToken(token).initialize(tokenName, tokenSymbol);
            deployedTokens[salt] = token;
            tokenAdapter[token] = adapter;
            emit TokenDeployed(token, srcChainId, remoteToken, adapter);
        }

        BridgeToken(token).mint(recipient, amount);
        emit TokensMinted(token, recipient, amount);
    }

    /// @notice Accept ETH refunds from adapters (e.g. LZ excess fee refund).
    receive() external payable {}
}
