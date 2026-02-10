# 2bottles — Diamond Contract Architecture

## Executive Summary

**Product:** 2bottles  
**Version:** 2.0  
**Last Updated:** February 9, 2026  

2bottles is a dual-token ecosystem for the hospitality industry. This document focuses on the **Diamond Standard (EIP-2535)** smart contract architecture that powers the protocol.

---

## Table of Contents

1. [Why Diamond?](#why-diamond)
2. [Diamond Pattern Overview](#diamond-pattern-overview)
3. [Architecture Deep Dive](#architecture-deep-dive)
4. [Storage Pattern](#storage-pattern)
5. [Contract Files Reference](#contract-files-reference)
6. [Call Flow Walkthrough](#call-flow-walkthrough)
7. [Upgrading Facets](#upgrading-facets)
8. [Security Considerations](#security-considerations)
9. [Development Guide](#development-guide)

---

## Why Diamond?

Traditional smart contract development faces several limitations:

| Problem | Standard Contract | Diamond Pattern |
|---------|-------------------|-----------------|
| **24KB size limit** | Contract too large? You're stuck. | Split logic across unlimited facets. |
| **Upgradeability** | Proxy patterns have storage collision risks. | Structured storage slots per domain. |
| **Modularity** | One monolith or complex inheritance. | Plug-and-play facets. |
| **Gas efficiency** | Redeploy everything for one change. | Replace only the changed facet. |
| **Introspection** | Manual tracking of functions. | Built-in loupe tells you what's installed. |

The Diamond pattern (EIP-2535) solves these by introducing a **single proxy contract** (the Diamond) that delegates calls to multiple implementation contracts (facets).

---

## Diamond Pattern Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              USER / DAPP                                │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ call increment()
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              DIAMOND                                    │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  fallback() {                                                     │  │
│  │    1. Look up msg.sig in selectorToFacet mapping                  │  │
│  │    2. Get facet address for that selector                         │  │
│  │    3. delegatecall(facet, calldata)                               │  │
│  │    4. Return result                                               │  │
│  │  }                                                                │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  STORAGE (shared by all facets via delegatecall):                       │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐          │
│  │ DiamondStorage  │  │ TokenStorage    │  │ StakingStorage  │          │
│  │ (slot 0x123...) │  │ (slot 0x456...) │  │ (slot 0x789...) │          │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘          │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
           ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
           │ DiamondCut   │ │ Loupe        │ │ YourFeature  │
           │ Facet        │ │ Facet        │ │ Facet        │
           │              │ │              │ │              │
           │ diamondCut() │ │ facets()     │ │ increment()  │
           │              │ │ facetAddr()  │ │ getCount()   │
           └──────────────┘ └──────────────┘ └──────────────┘
```

### Core Concepts

| Term | Definition |
|------|------------|
| **Diamond** | The main contract users interact with. Holds all storage, routes calls via `fallback()`. |
| **Facet** | A stateless contract containing function implementations. Multiple facets = modular features. |
| **Selector** | First 4 bytes of a function signature hash (e.g., `bytes4(keccak256("transfer(address,uint256)"))`). |
| **DiamondCut** | The operation of adding, replacing, or removing function selectors from the Diamond. |
| **Loupe** | Introspection functions that let you query which facets and functions are installed. |

---

## Architecture Deep Dive

### The Diamond Contract

The Diamond is minimal by design. Its only job is to:

1. **Store the selector→facet mapping** (via `LibDiamond`)
2. **Delegate calls** to the correct facet based on `msg.sig`

```solidity
// Diamond.sol (simplified)
fallback() external payable {
    // 1. Look up which facet handles this function selector
    address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
    require(facet != address(0), "Function does not exist");
    
    // 2. Forward the call via delegatecall
    assembly {
        calldatacopy(0, 0, calldatasize())
        let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
        returndatacopy(0, 0, returndatasize())
        switch result
        case 0 { revert(0, returndatasize()) }
        default { return(0, returndatasize()) }
    }
}
```

**Key insight:** Because we use `delegatecall`, the facet code executes in the context of the Diamond's storage. This is how all facets share state.

### Facets

Facets are regular contracts, but they're designed to be called via `delegatecall`. They:

- **DO NOT** have their own meaningful storage (any storage they declare would collide)
- **DO** read/write shared storage via libraries (e.g., `LibDiamond.diamondStorage()`)
- **ARE** stateless from their own perspective

```solidity
// Example: OwnershipFacet.sol
contract OwnershipFacet is IERC173 {
    function owner() external view returns (address) {
        // Reads from Diamond's storage, not its own
        return LibDiamond.contractOwner();
    }
    
    function transferOwnership(address _newOwner) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }
}
```

### Standard Facets

EIP-2535 specifies these essential facets:

| Facet | Purpose | Functions |
|-------|---------|-----------|
| **DiamondCutFacet** | Upgrade management | `diamondCut(FacetCut[], address, bytes)` |
| **DiamondLoupeFacet** | Introspection | `facets()`, `facetFunctionSelectors()`, `facetAddresses()`, `facetAddress()` |
| **OwnershipFacet** | Access control | `owner()`, `transferOwnership()` |

Your application facets (e.g., `TokenFacet`, `StakingFacet`) are added on top of these.

---

## Storage Pattern

### The Problem

In a normal contract, storage is laid out sequentially:

```solidity
contract Normal {
    uint256 a;  // slot 0
    uint256 b;  // slot 1
}
```

With Diamond, multiple facets share the same storage. If two facets both declare `uint256 a`, they'd overwrite each other at slot 0.

### The Solution: Diamond Storage

Each domain of data is stored at a **unique, deterministic slot** calculated via `keccak256`:

```solidity
library LibDiamond {
    // This hash determines where DiamondStorage lives
    bytes32 constant DIAMOND_STORAGE_POSITION = 
        keccak256("diamond.standard.diamond.storage");
    
    struct DiamondStorage {
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        mapping(address => bytes4[]) facetFunctionSelectors;
        address[] facetAddresses;
        address contractOwner;
        mapping(bytes4 => bool) supportedInterfaces;
    }
    
    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }
}
```

### Adding Your Own Storage

For each new feature domain, create a storage library:

```solidity
library LibToken {
    bytes32 constant TOKEN_STORAGE_POSITION = 
        keccak256("twobottles.token.storage");
    
    struct TokenStorage {
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
    }
    
    function tokenStorage() internal pure returns (TokenStorage storage ts) {
        bytes32 position = TOKEN_STORAGE_POSITION;
        assembly {
            ts.slot := position
        }
    }
}
```

**Why this works:**
- `keccak256("diamond.standard.diamond.storage")` produces a 256-bit hash
- This hash becomes the storage slot position
- Different strings → different slots → no collisions
- The struct is laid out starting at that slot

### Storage Layout Visualization

```
Storage Slots:
┌─────────────────────────────────────────────────────────────────────┐
│ Slot 0                    (unused - we never use low slots)        │
│ Slot 1                    (unused)                                 │
│ ...                                                                │
│ Slot 0x123abc...          DiamondStorage starts here               │
│   ├── selectorToFacetAndPosition mapping                           │
│   ├── facetFunctionSelectors mapping                               │
│   ├── facetAddresses array                                         │
│   ├── contractOwner                                                │
│   └── supportedInterfaces mapping                                  │
│ ...                                                                │
│ Slot 0x456def...          TokenStorage starts here                 │
│   ├── name                                                         │
│   ├── symbol                                                       │
│   ├── decimals                                                     │
│   ├── totalSupply                                                  │
│   ├── balances mapping                                             │
│   └── allowances mapping                                           │
│ ...                                                                │
│ Slot 0x789ghi...          StakingStorage starts here               │
│   └── (staking-specific data)                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Contract Files Reference

### Directory Structure

```
contracts/
├── Diamond.sol                    # Main proxy contract
├── interfaces/
│   ├── IDiamondCut.sol           # Cut operation interface
│   ├── IDiamondLoupe.sol         # Introspection interface  
│   └── IERC173.sol               # Ownership interface
├── libraries/
│   └── LibDiamond.sol            # Core storage & helpers
└── facets/
    ├── DiamondCutFacet.sol       # Implements diamondCut()
    ├── DiamondLoupeFacet.sol     # Implements loupe functions
    └── OwnershipFacet.sol        # Implements owner/transfer
```

### File-by-File Breakdown

#### `Diamond.sol`
The entry point. Users interact with this address forever, regardless of upgrades.

- **Constructor:** Sets initial owner via `LibDiamond.setContractOwner()`
- **fallback():** Routes calls to facets via selector lookup + delegatecall
- **receive():** Accepts ETH transfers

#### `interfaces/IDiamondCut.sol`
Defines the upgrade interface:

```solidity
enum FacetCutAction { Add, Replace, Remove }

struct FacetCut {
    address facetAddress;      // Facet contract address
    FacetCutAction action;     // What to do
    bytes4[] functionSelectors; // Which functions
}

function diamondCut(
    FacetCut[] calldata _cut,
    address _init,             // Optional initializer contract
    bytes calldata _calldata   // Optional init calldata
) external;
```

#### `interfaces/IDiamondLoupe.sol`
Defines introspection:

```solidity
function facets() external view returns (Facet[] memory);
function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory);
function facetAddresses() external view returns (address[] memory);
function facetAddress(bytes4 _functionSelector) external view returns (address);
```

#### `interfaces/IERC173.sol`
Standard ownership interface:

```solidity
function owner() external view returns (address);
function transferOwnership(address _newOwner) external;
```

#### `libraries/LibDiamond.sol`
The heart of the Diamond pattern. Contains:

- **DiamondStorage struct:** Selector mappings, facet lists, owner
- **diamondStorage():** Returns storage pointer at fixed slot
- **setContractOwner() / contractOwner():** Owner management
- **enforceIsContractOwner():** Access control modifier-like function
- **addFunctions():** Register new selectors → facet
- **replaceFunctions():** Point existing selectors → new facet
- **removeFunctions():** Delete selectors from the Diamond
- **initializeDiamondCut():** Run initializer after cuts

#### `facets/DiamondCutFacet.sol`
Implements `diamondCut()`:

1. Enforces only owner can call
2. Loops through `FacetCut[]` array
3. Calls `LibDiamond.addFunctions/replaceFunctions/removeFunctions`
4. Emits `DiamondCut` event
5. Optionally calls initializer

#### `facets/DiamondLoupeFacet.sol`
Implements the four loupe functions by reading from `LibDiamond.diamondStorage()`.

#### `facets/OwnershipFacet.sol`
Simple owner getter/setter using `LibDiamond` helpers.

---

## Call Flow Walkthrough

Let's trace what happens when a user calls `owner()` on the Diamond:

### Step 1: User Sends Transaction

```
User calls: Diamond.owner()
msg.sig = 0x8da5cb5b (first 4 bytes of keccak256("owner()"))
```

### Step 2: Diamond fallback() Executes

```solidity
fallback() external payable {
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    
    // Look up: which facet implements 0x8da5cb5b?
    address facet = ds.selectorToFacetAndPosition[0x8da5cb5b].facetAddress;
    // facet = OwnershipFacet address
    
    require(facet != address(0), "Function does not exist");
    
    // Delegatecall to OwnershipFacet with original calldata
    assembly {
        calldatacopy(0, 0, calldatasize())
        let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
        // ...
    }
}
```

### Step 3: OwnershipFacet.owner() Runs

```solidity
function owner() external view returns (address) {
    return LibDiamond.contractOwner();
}
```

Because this is a `delegatecall`:
- `msg.sender` = original user
- Storage context = Diamond's storage
- `LibDiamond.diamondStorage()` returns Diamond's DiamondStorage

### Step 4: Result Returns

The owner address flows back through the delegatecall return, through the Diamond's fallback assembly, to the user.

---

## Upgrading Facets

### Adding a New Facet

```solidity
// 1. Deploy the new facet
TokenFacet tokenFacet = new TokenFacet();

// 2. Build the FacetCut
IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);

bytes4[] memory selectors = new bytes4[](4);
selectors[0] = TokenFacet.transfer.selector;
selectors[1] = TokenFacet.balanceOf.selector;
selectors[2] = TokenFacet.approve.selector;
selectors[3] = TokenFacet.transferFrom.selector;

cut[0] = IDiamondCut.FacetCut({
    facetAddress: address(tokenFacet),
    action: IDiamondCut.FacetCutAction.Add,
    functionSelectors: selectors
});

// 3. Execute the cut (as owner)
IDiamondCut(diamond).diamondCut(cut, address(0), "");
```

### Replacing Functions

Same pattern, but use `FacetCutAction.Replace`:

```solidity
cut[0] = IDiamondCut.FacetCut({
    facetAddress: address(newTokenFacet),  // New implementation
    action: IDiamondCut.FacetCutAction.Replace,
    functionSelectors: selectors
});
```

### Removing Functions

For removal, `facetAddress` must be `address(0)`:

```solidity
cut[0] = IDiamondCut.FacetCut({
    facetAddress: address(0),  // Must be zero for Remove
    action: IDiamondCut.FacetCutAction.Remove,
    functionSelectors: selectorsToRemove
});
```

### With Initialization

Pass an initializer contract and calldata to run setup after the cut:

```solidity
// Initializer contract
contract DiamondInit {
    function init(string memory name, string memory symbol) external {
        LibToken.TokenStorage storage ts = LibToken.tokenStorage();
        ts.name = name;
        ts.symbol = symbol;
        ts.decimals = 18;
    }
}

// Execute cut with init
IDiamondCut(diamond).diamondCut(
    cut,
    address(diamondInit),
    abi.encodeWithSelector(DiamondInit.init.selector, "2BTL", "2BTL")
);
```

---

## Security Considerations

### 1. Only Owner Can Cut

The `diamondCut()` function is protected:

```solidity
function diamondCut(...) external {
    LibDiamond.enforceIsContractOwner();  // Reverts if not owner
    // ...
}
```

**Production recommendation:** Use a multi-sig or governance timelock as owner.

### 2. Storage Collision Prevention

- Always use unique `keccak256()` strings for storage positions
- Never declare state variables directly in facets
- Document all storage slots in a central registry

### 3. Function Selector Collision

Two different functions can have the same 4-byte selector (rare but possible). The Diamond will reject adding a selector that already exists.

### 4. Delegatecall Risks

Facets run with Diamond's storage context. A malicious facet could:
- Overwrite owner
- Drain funds
- Corrupt state

**Mitigation:** Audit all facets thoroughly before adding.

### 5. Initializer Reentrancy

The `_init` callback in `diamondCut` runs via delegatecall. Ensure initializers are idempotent or use initialized flags.

### 6. Emergency Pause

Consider adding a pause mechanism in critical facets:

```solidity
library LibPause {
    bytes32 constant PAUSE_STORAGE = keccak256("twobottles.pause.storage");
    
    struct PauseStorage {
        bool paused;
    }
    
    function pauseStorage() internal pure returns (PauseStorage storage ps) {
        bytes32 position = PAUSE_STORAGE;
        assembly { ps.slot := position }
    }
    
    function enforceNotPaused() internal view {
        require(!pauseStorage().paused, "Contract is paused");
    }
}
```

---

## Development Guide

### Creating a New Facet

1. **Create storage library** (if new domain):

```solidity
// contracts/libraries/LibMyFeature.sol
library LibMyFeature {
    bytes32 constant STORAGE_POSITION = keccak256("twobottles.myfeature.storage");
    
    struct MyFeatureStorage {
        uint256 someValue;
        mapping(address => bool) someMapping;
    }
    
    function myFeatureStorage() internal pure returns (MyFeatureStorage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly { s.slot := position }
    }
}
```

2. **Create facet contract**:

```solidity
// contracts/facets/MyFeatureFacet.sol
import "../libraries/LibMyFeature.sol";
import "../libraries/LibDiamond.sol";

contract MyFeatureFacet {
    function setValue(uint256 _value) external {
        LibDiamond.enforceIsContractOwner();  // if owner-only
        LibMyFeature.MyFeatureStorage storage s = LibMyFeature.myFeatureStorage();
        s.someValue = _value;
    }
    
    function getValue() external view returns (uint256) {
        return LibMyFeature.myFeatureStorage().someValue;
    }
}
```

3. **Deploy and register**:

```typescript
// scripts/addMyFeature.ts
const facet = await MyFeatureFacet.deploy();
const selectors = getSelectors(facet);
await diamond.diamondCut([{
    facetAddress: facet.address,
    action: FacetCutAction.Add,
    functionSelectors: selectors
}], ethers.constants.AddressZero, "0x");
```

### Testing Pattern

```typescript
describe("MyFeatureFacet", () => {
    let diamond: Diamond;
    let myFeature: MyFeatureFacet;
    
    beforeEach(async () => {
        // Deploy Diamond with core facets
        diamond = await deployDiamond();
        
        // Add MyFeatureFacet
        const MyFeatureFacet = await ethers.getContractFactory("MyFeatureFacet");
        const facet = await MyFeatureFacet.deploy();
        await addFacet(diamond, facet);
        
        // Get interface to Diamond as MyFeatureFacet
        myFeature = await ethers.getContractAt("MyFeatureFacet", diamond.address);
    });
    
    it("should set and get value", async () => {
        await myFeature.setValue(42);
        expect(await myFeature.getValue()).to.equal(42);
    });
});
```

### Helper: Get Selectors

```typescript
function getSelectors(contract: Contract): string[] {
    const signatures = Object.keys(contract.interface.functions);
    return signatures.map(sig => contract.interface.getSighash(sig));
}
```

---

## Quick Reference

### Selector → Facet Lookup

```solidity
// How the Diamond routes calls:
address facet = diamondStorage().selectorToFacetAndPosition[msg.sig].facetAddress;
```

### Storage Slot Formula

```solidity
bytes32 slot = keccak256("your.unique.namespace.storage");
```

### FacetCut Actions

| Action | Value | facetAddress | Effect |
|--------|-------|--------------|--------|
| Add | 0 | Facet address | Register new selectors |
| Replace | 1 | New facet address | Point selectors to new facet |
| Remove | 2 | `address(0)` | Delete selectors |

### Key Events

```solidity
event DiamondCut(FacetCut[] _cut, address _init, bytes _calldata);
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

---

## Further Reading

- [EIP-2535: Diamonds](https://eips.ethereum.org/EIPS/eip-2535)
- [Diamond Reference Implementation](https://github.com/mudgen/diamond-3-hardhat)
- [Nick Mudge's Diamond Blog](https://eip2535diamonds.substack.com/)
