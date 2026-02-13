// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title BTLTokenWrapper
 * @notice Standard ERC20 adapter for the Diamond's 2BTL token
 * @dev Provides a standalone ERC20 contract address that DEXes, wallets, and
 *      DeFi protocols can interact with normally. All state (balances, allowances,
 *      supply) lives in the Diamond; the wrapper delegates every call through.
 *
 *      SETUP:
 *      1. Deploy with the Diamond proxy address
 *      2. Register via `btlSetWrapper(address)` on the Diamond
 */
interface IBTLTokenDiamond {
    function btlName() external view returns (string memory);
    function btlSymbol() external view returns (string memory);
    function btlDecimals() external pure returns (uint8);
    function btlTotalSupply() external view returns (uint256);
    function btlBalanceOf(address account) external view returns (uint256);
    function btlAllowance(address owner, address spender) external view returns (uint256);
    function btlWrapperTransfer(address from, address to, uint256 amount) external returns (bool);
    function btlWrapperTransferFrom(address spender, address from, address to, uint256 amount) external returns (bool);
    function btlWrapperApprove(address owner_, address spender, uint256 amount) external returns (bool);
}

contract BTLTokenWrapper {

    address public immutable diamond;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address _diamond) {
        require(_diamond != address(0), "BTLWrapper: Invalid diamond");
        diamond = _diamond;
    }

    // ============ ERC20 View Functions ============

    function name() external view returns (string memory) {
        return IBTLTokenDiamond(diamond).btlName();
    }

    function symbol() external view returns (string memory) {
        return IBTLTokenDiamond(diamond).btlSymbol();
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view returns (uint256) {
        return IBTLTokenDiamond(diamond).btlTotalSupply();
    }

    function balanceOf(address account) external view returns (uint256) {
        return IBTLTokenDiamond(diamond).btlBalanceOf(account);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return IBTLTokenDiamond(diamond).btlAllowance(owner, spender);
    }

    // ============ ERC20 State-Changing Functions ============

    function transfer(address to, uint256 amount) external returns (bool) {
        bool success = IBTLTokenDiamond(diamond).btlWrapperTransfer(msg.sender, to, amount);
        if (success) emit Transfer(msg.sender, to, amount);
        return success;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        bool success = IBTLTokenDiamond(diamond).btlWrapperTransferFrom(msg.sender, from, to, amount);
        if (success) emit Transfer(from, to, amount);
        return success;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        bool success = IBTLTokenDiamond(diamond).btlWrapperApprove(msg.sender, spender, amount);
        if (success) emit Approval(msg.sender, spender, amount);
        return success;
    }
}
