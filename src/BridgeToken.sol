// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BridgeToken
/// @notice ERC20 representing a wrapped remote-chain token. Deployed via CREATE2
///         by BridgeTokenFactory. Name/symbol are set post-deploy via initialize()
///         so the CREATE2 address depends only on (remoteChainId, remoteToken, factory).
contract BridgeToken is ERC20 {
    uint256 public immutable remoteChainId;
    address public immutable remoteToken;
    address public immutable factory;

    string private _name;
    string private _symbol;
    bool private _initialized;

    error OnlyFactory();
    error AlreadyInitialized();

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    constructor(
        uint256 remoteChainId_,
        address remoteToken_,
        address factory_
    ) ERC20("", "") {
        remoteChainId = remoteChainId_;
        remoteToken = remoteToken_;
        factory = factory_;
    }

    function initialize(string memory name_, string memory symbol_) external onlyFactory {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function mint(address to, uint256 amount) external onlyFactory {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyFactory {
        _burn(from, amount);
    }
}
