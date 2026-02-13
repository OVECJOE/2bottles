// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../interfaces/IERC20.sol";

/**
 * @title LibSafeERC20
 * @notice Safe ERC20 transfer wrappers that handle non-standard return values
 * @dev Some tokens (like USDT) don't return bool from transfer/approve.
 *      This library handles both compliant and non-compliant tokens.
 */
library LibSafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // SafeApprove pattern: if setting non-zero, first set to 0 (for USDT-like tokens)
        if (value > 0) {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance > 0) {
                _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            }
        }
        _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, value)));
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}
