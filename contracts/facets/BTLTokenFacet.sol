// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";
import "../libraries/LibReentrancyGuard.sol";
import "../libraries/LibVotes.sol";

/**
 * @title BTLTokenFacet
 * @notice The 2BTL rewards and governance token
 * @dev ERC20-like implementation with a configurable transfer fee and Compound-style
 *      vote checkpointing. Uses prefixed function names (`btlTransfer`, `btlApprove`, etc.)
 *      because two tokens share a single Diamond proxy. A standalone BTLTokenWrapper
 *      contract provides standard ERC20 compatibility for DEXes and wallets.
 *
 *      Every balance-changing operation writes a voting checkpoint via LibVotes,
 *      enabling snapshot-based governance in GovernanceFacet.
 */
contract BTLTokenFacet {

    // ============ Events ============
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TransferFeeCollected(address indexed from, uint256 feeAmount);

    // ============ Modifiers ============
    modifier nonReentrant() {
        LibReentrancyGuard.nonReentrantBefore();
        _;
        LibReentrancyGuard.nonReentrantAfter();
    }

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

    // ============ ERC20 State-Changing Functions ============

    function btlTransfer(address to, uint256 amount) external nonReentrant returns (bool) {
        LibAppStorage.enforceNotPaused();
        _btlTransfer(msg.sender, to, amount);
        return true;
    }

    function btlTransferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
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

    function btlApprove(address spender, uint256 amount) external returns (bool) {
        LibAppStorage.enforceNotPaused();
        require(spender != address(0), "BTL: Approve to zero address");

        LibAppStorage.appStorage().btlAllowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function btlIncreaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();

        s.btlAllowances[msg.sender][spender] += addedValue;
        emit Approval(msg.sender, spender, s.btlAllowances[msg.sender][spender]);
        return true;
    }

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

    // ============ ERC20 Wrapper Support ============
    // These functions are callable ONLY by the registered BTL wrapper contract,
    // which relays the original msg.sender for standard ERC20 compatibility.

    function btlWrapperTransfer(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(msg.sender == s.btlWrapper, "BTL: Caller is not wrapper");
        LibAppStorage.enforceNotPaused();
        _btlTransfer(from, to, amount);
        return true;
    }

    function btlWrapperTransferFrom(address spender, address from, address to, uint256 amount) external nonReentrant returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(msg.sender == s.btlWrapper, "BTL: Caller is not wrapper");
        LibAppStorage.enforceNotPaused();

        uint256 currentAllowance = s.btlAllowances[from][spender];
        require(currentAllowance >= amount, "BTL: Insufficient allowance");

        if (currentAllowance != type(uint256).max) {
            unchecked {
                s.btlAllowances[from][spender] = currentAllowance - amount;
            }
        }

        _btlTransfer(from, to, amount);
        return true;
    }

    function btlWrapperApprove(address owner_, address spender, uint256 amount) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(msg.sender == s.btlWrapper, "BTL: Caller is not wrapper");
        LibAppStorage.enforceNotPaused();
        require(spender != address(0), "BTL: Approve to zero address");

        s.btlAllowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
        return true;
    }

    // ============ Administrative Functions ============

    function btlMint(address to, uint256 amount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(
            s.roles[LibAppStorage.ORACLE_ROLE][msg.sender] ||
            s.roles[LibAppStorage.ADMIN_ROLE][msg.sender],
            "BTL: Not authorized to mint"
        );
        LibAppStorage.enforceNotPaused();
        require(to != address(0), "BTL: Mint to zero address");

        s.btlBalances[to] += amount;
        s.btlTotalSupply += amount;

        // Update voting checkpoints
        LibVotes.transferVotingUnits(address(0), to, amount);

        emit Transfer(address(0), to, amount);
    }

    function btlBurn(uint256 amount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(s.btlBalances[msg.sender] >= amount, "BTL: Insufficient balance");

        unchecked {
            s.btlBalances[msg.sender] -= amount;
            s.btlTotalSupply -= amount;
        }

        // Update voting checkpoints
        LibVotes.transferVotingUnits(msg.sender, address(0), amount);

        emit Transfer(msg.sender, address(0), amount);
    }

    function btlSetTransferFee(uint256 feeBasisPoints) external {
        LibAppStorage.enforceIsAdmin();
        require(feeBasisPoints <= 1000, "BTL: Fee cannot exceed 10%");
        LibAppStorage.appStorage().btlTransferFee = feeBasisPoints;
    }

    function btlGetTransferFee() external view returns (uint256) {
        return LibAppStorage.appStorage().btlTransferFee;
    }

    function btlSetWrapper(address wrapper) external {
        LibAppStorage.enforceIsAdmin();
        require(wrapper != address(0), "BTL: Invalid wrapper address");
        LibAppStorage.appStorage().btlWrapper = wrapper;
    }

    // ============ Internal Functions ============

    function _btlTransfer(address from, address to, uint256 amount) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();

        require(from != address(0), "BTL: Transfer from zero address");
        require(to != address(0), "BTL: Transfer to zero address");
        require(s.btlBalances[from] >= amount, "BTL: Insufficient balance");

        // Calculate fee
        uint256 fee = (amount * s.btlTransferFee) / LibAppStorage.BASIS_POINTS;
        uint256 amountAfterFee = amount - fee;

        // Effects: update balances
        unchecked {
            s.btlBalances[from] -= amount;
            s.btlBalances[to] += amountAfterFee;
        }

        // Fee to treasury (contract address)
        if (fee > 0) {
            s.btlBalances[address(this)] += fee;
            LibVotes.transferVotingUnits(from, address(this), fee);
            emit TransferFeeCollected(from, fee);
            emit Transfer(from, address(this), fee);
        }

        // Update voting checkpoints for main transfer
        LibVotes.transferVotingUnits(from, to, amountAfterFee);

        emit Transfer(from, to, amountAfterFee);
    }
}
