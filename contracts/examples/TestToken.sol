// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from '../lib/ERC20.sol';

contract TestERC20 is ERC20('TEST', 'TST') {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}