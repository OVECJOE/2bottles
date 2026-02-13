// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title PROOFTokenWrapper
 * @notice Standard ERC20 adapter for the Diamond's PROOF stable token
 * @dev Provides a standalone ERC20 contract address for external integrations.
 *      All state (balances, allowances, supply) lives in the Diamond;
 *      the wrapper delegates every call through.
 *
 *      SETUP:
 *      1. Deploy with the Diamond proxy address
 *      2. Register via `proofSetWrapper(address)` on the Diamond
 */
interface IPROOFTokenDiamond {
    function proofName() external view returns (string memory);
    function proofSymbol() external view returns (string memory);
    function proofDecimals() external pure returns (uint8);
    function proofTotalSupply() external view returns (uint256);
    function proofBalanceOf(address account) external view returns (uint256);
    function proofAllowance(address owner, address spender) external view returns (uint256);
    function proofWrapperTransfer(address from, address to, uint256 amount) external returns (bool);
    function proofWrapperTransferFrom(address spender, address from, address to, uint256 amount) external returns (bool);
    function proofWrapperApprove(address owner_, address spender, uint256 amount) external returns (bool);
}

contract PROOFTokenWrapper {

    address public immutable diamond;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address _diamond) {
        require(_diamond != address(0), "PROOFWrapper: Invalid diamond");
        diamond = _diamond;
    }

    // ============ ERC20 View Functions ============

    function name() external view returns (string memory) {
        return IPROOFTokenDiamond(diamond).proofName();
    }

    function symbol() external view returns (string memory) {
        return IPROOFTokenDiamond(diamond).proofSymbol();
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function totalSupply() external view returns (uint256) {
        return IPROOFTokenDiamond(diamond).proofTotalSupply();
    }

    function balanceOf(address account) external view returns (uint256) {
        return IPROOFTokenDiamond(diamond).proofBalanceOf(account);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return IPROOFTokenDiamond(diamond).proofAllowance(owner, spender);
    }

    // ============ ERC20 State-Changing Functions ============

    function transfer(address to, uint256 amount) external returns (bool) {
        bool success = IPROOFTokenDiamond(diamond).proofWrapperTransfer(msg.sender, to, amount);
        if (success) emit Transfer(msg.sender, to, amount);
        return success;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        bool success = IPROOFTokenDiamond(diamond).proofWrapperTransferFrom(msg.sender, from, to, amount);
        if (success) emit Transfer(from, to, amount);
        return success;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        bool success = IPROOFTokenDiamond(diamond).proofWrapperApprove(msg.sender, spender, amount);
        if (success) emit Approval(msg.sender, spender, amount);
        return success;
    }
}
