// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IBridgeMessageReceiver} from "../interfaces/IBridgeMessageReceiver.sol";

/// @notice Minimal LayerZero v2 endpoint interface.
interface ILzEndpointV2 {
    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    function send(MessagingParams calldata _params, address _refundAddress)
        external payable returns (MessagingReceipt memory);

    function quote(MessagingParams calldata _params, address _sender)
        external view returns (MessagingFee memory);

    function setDelegate(address _delegate) external;
}

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

interface ILayerZeroReceiver {
    function allowInitializePath(Origin calldata _origin) external view returns (bool);
    function nextNonce(uint32 _eid, bytes32 _sender) external view returns (uint64);
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

/// @notice Minimal interfaces for registration (adapter calls these as msg.sender).
interface IBridgeTokenFactory {
    function registerVault(uint256 remoteChainId, address vault) external;
}

interface ITokenVault {
    function registerFactory(uint256 localChainId, address factory) external;
}

/// @title LzBridgeAdapter
/// @notice Fully immutable IBridgeAdapter using LayerZero v2.
///         No owner, no admin. All config is write-once (set once, locked forever).
contract LzBridgeAdapter is IBridgeAdapter, ILayerZeroReceiver {
    ILzEndpointV2 public immutable lzEndpoint;
    uint32 public immutable localEid;
    uint128 public immutable dstGasLimit;

    /// @notice Maps chain ID (EVM) => LayerZero endpoint ID. Write-once.
    mapping(uint256 => uint32) public chainIdToEid;
    /// @notice Maps LZ endpoint ID => EVM chain ID. Write-once.
    mapping(uint32 => uint256) public eidToChainId;
    /// @notice Trusted peer on each remote chain. Write-once.
    mapping(uint32 => bytes32) public peers;

    error InvalidPeer();
    error OnlyEndpoint();
    error NoPeer();
    error NoEidMapping();
    error AlreadySet();

    event PeerSet(uint32 indexed eid, address peer);
    event ChainMapped(uint256 indexed chainId, uint32 indexed eid);

    constructor(address endpoint_, uint32 localEid_, uint128 dstGasLimit_) {
        lzEndpoint = ILzEndpointV2(endpoint_);
        localEid = localEid_;
        dstGasLimit = dstGasLimit_;
    }

    // --- Write-once config (permissionless, immutable after first set) ---

    function setPeer(uint32 eid, address peer) external {
        if (peer == address(0)) revert NoEidMapping(); // zero address check
        if (peers[eid] != bytes32(0)) revert AlreadySet();
        peers[eid] = bytes32(uint256(uint160(peer)));
        emit PeerSet(eid, peer);
    }

    function mapChain(uint256 chainId, uint32 eid) external {
        if (chainIdToEid[chainId] != 0) revert AlreadySet();
        if (eidToChainId[eid] != 0) revert AlreadySet(); // guard reverse mapping too
        chainIdToEid[chainId] = eid;
        eidToChainId[eid] = chainId;
        emit ChainMapped(chainId, eid);
    }

    /// @notice Register vault on a factory. This adapter is msg.sender.
    function registerVault(address factory, uint256 remoteChainId, address vault) external {
        IBridgeTokenFactory(factory).registerVault(remoteChainId, vault);
    }

    /// @notice Register factory on a vault. This adapter is msg.sender.
    function registerFactory(address vault, uint256 localChainId, address factory) external {
        ITokenVault(vault).registerFactory(localChainId, factory);
    }

    // --- IBridgeAdapter ---

    function sendMessage(
        uint256 dstChainId,
        address receiver,
        bytes calldata payload
    ) external payable override returns (bytes32 messageId) {
        uint32 dstEid = chainIdToEid[dstChainId];
        if (dstEid == 0) revert NoEidMapping();

        bytes32 peer = peers[dstEid];
        if (peer == bytes32(0)) revert NoPeer();

        bytes memory lzMessage = abi.encode(msg.sender, receiver, payload);
        bytes memory options = _buildOptions();

        ILzEndpointV2.MessagingParams memory params = ILzEndpointV2.MessagingParams({
            dstEid: dstEid,
            receiver: peer,
            message: lzMessage,
            options: options,
            payInLzToken: false
        });

        ILzEndpointV2.MessagingReceipt memory receipt =
            lzEndpoint.send{value: msg.value}(params, msg.sender);

        return receipt.guid;
    }

    function estimateFee(
        uint256 dstChainId,
        address receiver,
        bytes calldata payload
    ) external view override returns (uint256) {
        uint32 dstEid = chainIdToEid[dstChainId];
        if (dstEid == 0) revert NoEidMapping();

        bytes32 peer = peers[dstEid];
        if (peer == bytes32(0)) revert NoPeer();

        bytes memory lzMessage = abi.encode(msg.sender, receiver, payload);
        bytes memory options = _buildOptions();

        ILzEndpointV2.MessagingParams memory params = ILzEndpointV2.MessagingParams({
            dstEid: dstEid,
            receiver: peer,
            message: lzMessage,
            options: options,
            payInLzToken: false
        });

        ILzEndpointV2.MessagingFee memory fee = lzEndpoint.quote(params, address(this));
        return fee.nativeFee;
    }

    // --- ILayerZeroReceiver ---

    function lzReceive(
        Origin calldata _origin,
        bytes32,
        bytes calldata _message,
        address,
        bytes calldata
    ) external payable override {
        if (msg.sender != address(lzEndpoint)) revert OnlyEndpoint();
        if (peers[_origin.srcEid] != _origin.sender) revert InvalidPeer();

        uint256 srcChainId = eidToChainId[_origin.srcEid];
        if (srcChainId == 0) revert NoEidMapping();

        (address srcSender, address receiver, bytes memory payload) =
            abi.decode(_message, (address, address, bytes));

        IBridgeMessageReceiver(receiver).onBridgeMessage(srcChainId, srcSender, payload);
    }

    function allowInitializePath(Origin calldata _origin) external view override returns (bool) {
        return peers[_origin.srcEid] == _origin.sender;
    }

    function nextNonce(uint32, bytes32) external pure override returns (uint64) {
        return 0;
    }

    // --- Internal ---

    /// @notice Build LZ v2 executor options (Type 3).
    function _buildOptions() internal view returns (bytes memory) {
        return abi.encodePacked(
            uint16(3),      // options type 3
            uint8(1),       // worker id: executor
            uint16(17),     // param length
            uint8(1),       // option type: lzReceive gas
            dstGasLimit     // gas limit
        );
    }
}
