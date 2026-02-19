// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {BridgeTokenFactory} from "../src/BridgeTokenFactory.sol";
import {TokenVault} from "../src/TokenVault.sol";
import {LzBridgeAdapter} from "../src/adapters/LzBridgeAdapter.sol";

// Deterministic deployment proxy (same address on all EVM chains)
address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

/// @notice Deploy everything on one chain + configure in a single atomic transaction.
///         Run on EACH chain. All config (peers, chain mappings, registrations) is
///         write-once so this script is idempotent — safe to re-run.
contract DeployAndRegister is Script {
    bytes32 constant SALT = bytes32(0);

    // LayerZero v2 Endpoint (same address on all chains)
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    // LayerZero Endpoint IDs
    uint32 constant BASE_EID = 30184;
    uint32 constant OP_EID = 30111;

    // OP Mainnet is the hub
    uint256 constant HUB_CHAIN_ID = 10;

    // Default gas limit for LZ message execution
    uint128 constant DST_GAS_LIMIT = 500_000;

    function run() external {
        // Predict core contract addresses (same on all chains)
        address factory = _predictCreate2(type(BridgeTokenFactory).creationCode);
        address vault = _predictCreate2(type(TokenVault).creationCode);

        vm.startBroadcast();

        // 1. Deploy core contracts via deterministic deployer
        _deployCreate2(type(BridgeTokenFactory).creationCode, "BridgeTokenFactory");
        _deployCreate2(type(TokenVault).creationCode, "TokenVault");

        // 2. Deploy LZ adapter
        uint32 localEid = _getLocalEid();
        LzBridgeAdapter adapter = new LzBridgeAdapter(LZ_ENDPOINT, localEid, DST_GAS_LIMIT);

        // 3. Map chains (write-once, safe to call)
        _tryMapChain(adapter, 8453, BASE_EID);
        _tryMapChain(adapter, 10, OP_EID);

        // 4. Register pairings
        if (block.chainid == HUB_CHAIN_ID) {
            _tryRegisterVault(adapter, factory, 8453, vault);
        } else {
            _tryRegisterFactory(adapter, vault, HUB_CHAIN_ID, factory);
        }

        // NOTE: setPeer must be called separately after BOTH adapters are deployed,
        // since you need the remote adapter address. Use the setPeer script or cast.

        console.log("--- Deployed on chain", block.chainid, "---");
        console.log("Factory:", factory);
        console.log("Vault:  ", vault);
        console.log("Adapter:", address(adapter));

        vm.stopBroadcast();
    }

    function _deployCreate2(bytes memory creationCode, string memory name) internal returns (address deployed) {
        deployed = _predictCreate2(creationCode);
        if (deployed.code.length > 0) {
            console.log(string.concat(name, " already deployed"));
            return deployed;
        }
        (bool success,) = CREATE2_DEPLOYER.call(abi.encodePacked(SALT, creationCode));
        require(success && deployed.code.length > 0, string.concat(name, " deploy failed"));
    }

    function _predictCreate2(bytes memory creationCode) internal pure returns (address) {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, SALT, keccak256(creationCode))
        ))));
    }

    function _tryMapChain(LzBridgeAdapter adapter, uint256 chainId, uint32 eid) internal {
        if (adapter.chainIdToEid(chainId) == 0) {
            adapter.mapChain(chainId, eid);
        }
    }

    function _tryRegisterVault(LzBridgeAdapter adapter, address factory, uint256 chainId, address vault) internal {
        if (BridgeTokenFactory(payable(factory)).vaults(address(adapter), chainId) == address(0)) {
            adapter.registerVault(factory, chainId, vault);
        }
    }

    function _tryRegisterFactory(LzBridgeAdapter adapter, address vault, uint256 chainId, address factory) internal {
        if (TokenVault(payable(vault)).factories(address(adapter), chainId) == address(0)) {
            adapter.registerFactory(vault, chainId, factory);
        }
    }

    function _getLocalEid() internal view returns (uint32) {
        if (block.chainid == 8453) return BASE_EID;
        if (block.chainid == 10) return OP_EID;
        revert("Unsupported chain");
    }
}
