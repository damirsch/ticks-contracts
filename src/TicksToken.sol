// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title TICKS
/// @notice A standard OpenZeppelin ERC-20 with a fixed supply, minted once at deployment.
///         There is no owner, no minting after deployment, no transfer tax, no blacklist and no pause.
///         After deployment nobody, the team included, has any special power over the token.
contract TicksToken is ERC20, ERC20Permit {
    constructor(string memory name_, string memory symbol_, uint256 supply, address recipient)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(recipient, supply);
    }
}
