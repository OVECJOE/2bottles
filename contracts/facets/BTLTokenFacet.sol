// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";

/**
 * @title BTLTokenFacet
 * @notice Implements the 2BTL token - the rewards and governance token
 * @dev Standard ERC20 with additional features:
 *      - 0.5% transfer fee (goes to treasury)
 *      - Minting for rewards (only by authorized roles)
 *      - Burning for deflationary mechanism
 *      
 *      2BTL is earned by:
 *      - Checking in at venues
 *      - Referring friends
 *      - Participating in governance
 *      
 *      2BTL is used for:
 *      - Staking to mint PROOF
 *      - Governance voting
 *      - Earning protocol revenue share
 */
contract BTLTokenFacet {
    
    // ============ Events ============
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TransferFeeCollected(address indexed from, uint256 feeAmount);

    // ============ ERC20 View Functions ============

    function btlName() external view returns (string memory) {
        return LibAppStorage.appStorage().btlName;
    }

    function btlSymbol() external view returns (string memory) {
        return LibAppStorage.appStorage().btlSymbol;
    }

    function btlDecimals() external pure returns (uint8) {
        return 18;
    }

    function btlTotalSupply() external view returns (uint256) {
        return LibAppStorage.appStorage().btlTotalSupply;
    }

    function btlBalanceOf(address account) external view returns (uint256) {
        return LibAppStorage.appStorage().btlBalances[account];
    }

    function btlAllowance(address owner, address spender) external view returns (uint256) {
        return LibAppStorage.appStorage().btlAllowances[owner][spender];
    }

    // ============ ERC20 Transfer Functions ============

    /**
     * @notice Transfer 2BTL tokens (includes 0.5% fee)
     */
    function btlTransfer(address to, uint256 amount) external returns (bool) {
        LibAppStorage.enforceNotPaused();
        _btlTransfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Transfer 2BTL tokens from another account
     */
    function btlTransferFrom(address from, address to, uint256 amount) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        
        uint256 currentAllowance = s.btlAllowances[from][msg.sender];
        require(currentAllowance >= amount, "BTL: Insufficient allowance");
        
        if (currentAllowance != type(uint256).max) {
            unchecked {
                s.btlAllowances[from][msg.sender] = currentAllowance - amount;
            }
        }
        
        _btlTransfer(from, to, amount);
        return true;
    }

    /**
     * @notice Approve a spender to use your 2BTL
     */
    function btlApprove(address spender, uint256 amount) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        
        s.btlAllowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Increase allowance for a spender
     */
    function btlIncreaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        
        s.btlAllowances[msg.sender][spender] += addedValue;
        emit Approval(msg.sender, spender, s.btlAllowances[msg.sender][spender]);
        return true;
    }

    /**
     * @notice Decrease allowance for a spender
     */
    function btlDecreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        
        uint256 currentAllowance = s.btlAllowances[msg.sender][spender];
        require(currentAllowance >= subtractedValue, "BTL: Allowance below zero");
        
        unchecked {
            s.btlAllowances[msg.sender][spender] = currentAllowance - subtractedValue;
        }
        emit Approval(msg.sender, spender, s.btlAllowances[msg.sender][spender]);
        return true;
    }

    // ============ Administrative Functions ============

    /**
     * @notice Mint new 2BTL tokens (only authorized roles)
     */
    function btlMint(address to, uint256 amount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(
            s.roles[LibAppStorage.ORACLE_ROLE][msg.sender] || 
            s.roles[LibAppStorage.ADMIN_ROLE][msg.sender],
            "BTL: Not authorized to mint"
        );
        LibAppStorage.enforceNotPaused();
        
        s.btlBalances[to] += amount;
        s.btlTotalSupply += amount;
        
        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Burn 2BTL tokens (anyone can burn their own)
     */
    function btlBurn(uint256 amount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(s.btlBalances[msg.sender] >= amount, "BTL: Insufficient balance");
        
        unchecked {
            s.btlBalances[msg.sender] -= amount;
            s.btlTotalSupply -= amount;
        }
        
        emit Transfer(msg.sender, address(0), amount);
    }

    /**
     * @notice Set the transfer fee (admin only)
     */
    function btlSetTransferFee(uint256 feeBasisPoints) external {
        LibAppStorage.enforceIsAdmin();
        require(feeBasisPoints <= 1000, "BTL: Fee cannot exceed 10%");
        LibAppStorage.appStorage().btlTransferFee = feeBasisPoints;
    }

    /**
     * @notice Get current transfer fee in basis points
     */
    function btlGetTransferFee() external view returns (uint256) {
        return LibAppStorage.appStorage().btlTransferFee;
    }

    // ============ Internal Functions ============

    function _btlTransfer(address from, address to, uint256 amount) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        require(from != address(0), "BTL: Transfer from zero address");
        require(to != address(0), "BTL: Transfer to zero address");
        require(s.btlBalances[from] >= amount, "BTL: Insufficient balance");
        
        // Calculate fee (0.5% = 50 basis points default)
        uint256 fee = (amount * s.btlTransferFee) / LibAppStorage.BASIS_POINTS;
        uint256 amountAfterFee = amount - fee;
        
        unchecked {
            s.btlBalances[from] -= amount;
            s.btlBalances[to] += amountAfterFee;
        }
        
        // Fee goes to treasury (contract address)
        if (fee > 0) {
            s.btlBalances[address(this)] += fee;
            emit TransferFeeCollected(from, fee);
            emit Transfer(from, address(this), fee);
        }
        
        emit Transfer(from, to, amountAfterFee);
    }
}
