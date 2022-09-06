pragma solidity ^0.8.0;
// SPDX-License-Identifier: MIT

import "../openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Upgrade.sol";

abstract contract SampleUpgradeable is ERC1967Upgrade {
    bool initialized = false;

    function initializer(bytes calldata data) public {
        require(!initialized, "already initialized");
        _initializer(data);
        initialized = true;
    }

    function _initializer(bytes calldata data) virtual internal;
}

contract SampleMarketplaceUpgradeableProxy is TransparentUpgradeableProxy {
    constructor(address logic, address admin) TransparentUpgradeableProxy(logic, admin, "") {
}}

contract SampleNftUpgradeableProxy is TransparentUpgradeableProxy {
    constructor(address logic, address admin) TransparentUpgradeableProxy(logic, admin, "") {
}}
