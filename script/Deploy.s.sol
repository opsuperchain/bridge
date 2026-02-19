// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {BridgeTokenFactory} from "../src/BridgeTokenFactory.sol";
import {TokenVault} from "../src/TokenVault.sol";

// Deterministic deployment proxy (same address on all EVM chains)
// See https://github.com/Arachnid/deterministic-deployment-proxy
address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

/// @notice Deploy BridgeTokenFactory and/or TokenVault via the deterministic deployer.
///         Uses the same salt so contracts get the same address on every chain.
contract Deploy is Script {
    bytes32 constant SALT = bytes32(0); // use zero salt for simplicity

    function run() external {
        vm.startBroadcast();

        address factory = _deploy(type(BridgeTokenFactory).creationCode, "BridgeTokenFactory");
        address vault = _deploy(type(TokenVault).creationCode, "TokenVault");

        console.log("Factory:", factory);
        console.log("Vault:  ", vault);

        vm.stopBroadcast();
    }

    /// @notice Deploy only the factory (e.g. on OP Mainnet hub)
    function deployFactory() external {
        vm.startBroadcast();
        address factory = _deploy(type(BridgeTokenFactory).creationCode, "BridgeTokenFactory");
        console.log("Factory:", factory);
        vm.stopBroadcast();
    }

    /// @notice Deploy only the vault (e.g. on a spoke chain)
    function deployVault() external {
        vm.startBroadcast();
        address vault = _deploy(type(TokenVault).creationCode, "TokenVault");
        console.log("Vault:", vault);
        vm.stopBroadcast();
    }

    /// @notice Compute addresses without deploying
    function predict() external view {
        address factory = _predict(type(BridgeTokenFactory).creationCode);
        address vault = _predict(type(TokenVault).creationCode);
        console.log("Factory:", factory);
        console.log("Vault:  ", vault);
    }

    function _deploy(bytes memory creationCode, string memory name) internal returns (address deployed) {
        deployed = _predict(creationCode);

        if (deployed.code.length > 0) {
            console.log(string.concat(name, " already deployed at"), deployed);
            return deployed;
        }

        bytes memory payload = abi.encodePacked(SALT, creationCode);
        (bool success,) = CREATE2_DEPLOYER.call(payload);
        require(success, string.concat(name, " deploy failed"));
        require(deployed.code.length > 0, string.concat(name, " deploy verification failed"));

        console.log(string.concat(name, " deployed at"), deployed);
    }

    function _predict(bytes memory creationCode) internal pure returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                CREATE2_DEPLOYER,
                SALT,
                keccak256(creationCode)
            )
        );
        return address(uint160(uint256(hash)));
    }
}
