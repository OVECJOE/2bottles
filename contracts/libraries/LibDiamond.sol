// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../interfaces/IDiamondCut.sol";
import "../interfaces/IDiamondLoupe.sol";

/**
 * @title LibDiamond
 * @notice Core library for the Diamond Pattern (EIP-2535)
 * @dev This library manages:
 *      - Facet addresses and function selectors
 *      - DiamondCut operations (add/replace/remove facets)
 *      - Contract ownership
 */
library LibDiamond {
    bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");

    struct FacetAddressAndSelectorPosition {
        address facetAddress;
        uint16 selectorPosition;
    }

    struct DiamondStorage {
        // selector => facetAddress and selector position in facetFunctionSelectors
        mapping(bytes4 => FacetAddressAndSelectorPosition) selectorToFacetAndPosition;
        // facetAddress => function selectors
        mapping(address => bytes4[]) facetFunctionSelectors;
        // list of facet addresses
        address[] facetAddresses;
        // owner
        address contractOwner;
        // supported interfaces (ERC-165)
        mapping(bytes4 => bool) supportedInterfaces;
    }

    // ============ Events ============
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);

    // ============ Custom Errors ============
    error NotContractOwner(address user, address owner);
    error NoSelectorsProvided();
    error CannotAddSelectorsToZeroAddress();
    error FunctionAlreadyExists(bytes4 selector);
    error CannotReplaceFunctionsFromZeroAddress();
    error CannotReplaceWithSameFunction(bytes4 selector);
    error FunctionDoesNotExist(bytes4 selector);
    error RemoveFacetAddressMustBeZero();
    error InitializationFailed(address init, bytes data);

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function setContractOwner(address _newOwner) internal {
        DiamondStorage storage ds = diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = _newOwner;
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    function contractOwner() internal view returns (address) {
        return diamondStorage().contractOwner;
    }

    function enforceIsContractOwner() internal view {
        if (msg.sender != diamondStorage().contractOwner) {
            revert NotContractOwner(msg.sender, diamondStorage().contractOwner);
        }
    }

    /**
     * @notice Main function to perform diamond cuts
     */
    function diamondCut(
        IDiamondCut.FacetCut[] memory _diamondCut,
        address _init,
        bytes memory _calldata
    ) internal {
        for (uint256 i = 0; i < _diamondCut.length; i++) {
            IDiamondCut.FacetCutAction action = _diamondCut[i].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                addFunctions(_diamondCut[i].facetAddress, _diamondCut[i].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                replaceFunctions(_diamondCut[i].facetAddress, _diamondCut[i].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                removeFunctions(address(0), _diamondCut[i].functionSelectors);
            }
        }
        emit DiamondCut(_diamondCut, _init, _calldata);
        initializeDiamondCut(_init, _calldata);
    }

    function addFunctions(address _facetAddress, bytes4[] memory _selectors) internal {
        if (_selectors.length == 0) revert NoSelectorsProvided();
        if (_facetAddress == address(0)) revert CannotAddSelectorsToZeroAddress();
        
        DiamondStorage storage ds = diamondStorage();
        enforceHasContractCode(_facetAddress);

        // if this is a new facet, add to facetAddresses
        if (ds.facetFunctionSelectors[_facetAddress].length == 0) {
            ds.facetAddresses.push(_facetAddress);
        }

        for (uint256 i = 0; i < _selectors.length; i++) {
            bytes4 selector = _selectors[i];
            if (ds.selectorToFacetAndPosition[selector].facetAddress != address(0)) {
                revert FunctionAlreadyExists(selector);
            }
            ds.facetFunctionSelectors[_facetAddress].push(selector);
            ds.selectorToFacetAndPosition[selector] = FacetAddressAndSelectorPosition({
                facetAddress: _facetAddress,
                selectorPosition: uint16(ds.facetFunctionSelectors[_facetAddress].length - 1)
            });
        }
    }

    function replaceFunctions(address _facetAddress, bytes4[] memory _selectors) internal {
        if (_selectors.length == 0) revert NoSelectorsProvided();
        if (_facetAddress == address(0)) revert CannotReplaceFunctionsFromZeroAddress();
        
        DiamondStorage storage ds = diamondStorage();
        enforceHasContractCode(_facetAddress);

        if (ds.facetFunctionSelectors[_facetAddress].length == 0) {
            ds.facetAddresses.push(_facetAddress);
        }

        for (uint256 i = 0; i < _selectors.length; i++) {
            bytes4 selector = _selectors[i];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacet == _facetAddress) revert CannotReplaceWithSameFunction(selector);
            if (oldFacet == address(0)) revert FunctionDoesNotExist(selector);

            // remove selector from old facet
            bytes4[] storage oldSelectors = ds.facetFunctionSelectors[oldFacet];
            uint16 selectorPos = ds.selectorToFacetAndPosition[selector].selectorPosition;
            uint256 lastPos = oldSelectors.length - 1;
            if (selectorPos != lastPos) {
                bytes4 lastSelector = oldSelectors[lastPos];
                oldSelectors[selectorPos] = lastSelector;
                ds.selectorToFacetAndPosition[lastSelector].selectorPosition = selectorPos;
            }
            oldSelectors.pop();

            // add selector to new facet
            ds.facetFunctionSelectors[_facetAddress].push(selector);
            ds.selectorToFacetAndPosition[selector] = FacetAddressAndSelectorPosition({
                facetAddress: _facetAddress,
                selectorPosition: uint16(ds.facetFunctionSelectors[_facetAddress].length - 1)
            });
        }
    }

    function removeFunctions(address _facetAddress, bytes4[] memory _selectors) internal {
        if (_selectors.length == 0) revert NoSelectorsProvided();
        if (_facetAddress != address(0)) revert RemoveFacetAddressMustBeZero();
        
        DiamondStorage storage ds = diamondStorage();

        for (uint256 i = 0; i < _selectors.length; i++) {
            bytes4 selector = _selectors[i];
            FacetAddressAndSelectorPosition memory old = ds.selectorToFacetAndPosition[selector];
            address oldFacet = old.facetAddress;
            if (oldFacet == address(0)) revert FunctionDoesNotExist(selector);

            // remove selector from old facet
            bytes4[] storage oldSelectors = ds.facetFunctionSelectors[oldFacet];
            uint256 lastPos = oldSelectors.length - 1;
            uint16 selectorPos = old.selectorPosition;
            if (selectorPos != lastPos) {
                bytes4 lastSelector = oldSelectors[lastPos];
                oldSelectors[selectorPos] = lastSelector;
                ds.selectorToFacetAndPosition[lastSelector].selectorPosition = selectorPos;
            }
            oldSelectors.pop();
            delete ds.selectorToFacetAndPosition[selector];

            // if no selectors left for facet, remove facetAddress
            if (oldSelectors.length == 0) {
                uint256 len = ds.facetAddresses.length;
                for (uint256 j = 0; j < len; j++) {
                    if (ds.facetAddresses[j] == oldFacet) {
                        uint256 last = ds.facetAddresses.length - 1;
                        if (j != last) {
                            ds.facetAddresses[j] = ds.facetAddresses[last];
                        }
                        ds.facetAddresses.pop();
                        break;
                    }
                }
            }
        }
    }

    function initializeDiamondCut(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) {
            require(_calldata.length == 0, "LibDiamond: _calldata must be empty if _init is zero");
            return;
        }
        enforceHasContractCode(_init);
        (bool success, bytes memory error) = _init.delegatecall(_calldata);
        if (!success) {
            if (error.length > 0) {
                assembly {
                    let size := mload(error)
                    revert(add(32, error), size)
                }
            }
            revert InitializationFailed(_init, _calldata);
        }
    }

    function enforceHasContractCode(address _contract) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }
        require(contractSize > 0, "LibDiamond: Address has no code");
    }

    function setSupportedInterface(bytes4 _interfaceId, bool _supported) internal {
        diamondStorage().supportedInterfaces[_interfaceId] = _supported;
    }

    function supportsInterface(bytes4 _interfaceId) internal view returns (bool) {
        return diamondStorage().supportedInterfaces[_interfaceId];
    }
}