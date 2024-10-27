// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AccessControlContract.sol";

contract TokenContract is 
    Initializable,
    ERC20Upgradeable
{
    AccessControlContract private accessControl;

    function initialize(
        string memory name,
        string memory symbol,
        address accessControlAddress
    ) public initializer {
        __ERC20_init(name, symbol);
        accessControl = AccessControlContract(accessControlAddress);
    }

    function mint(
        address to,
        uint256 amount
    ) public {
        require(accessControl.isMinter(msg.sender), "Only minter can mint tokens");
        _mint(to, amount);
    }
}