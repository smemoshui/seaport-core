// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ConduitInterface} from "seaport-types/src/interfaces/ConduitInterface.sol";

import {ConduitItemType} from "seaport-types/src/conduit/lib/ConduitEnums.sol";

import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";

import {ReceivedItem} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {Verifiers} from "./Verifiers.sol";

import {TokenTransferrer} from "./TokenTransferrer.sol";

import {
    Accumulator_array_length_ptr,
    Accumulator_array_offset_ptr,
    Accumulator_array_offset,
    Accumulator_conduitKey_ptr,
    Accumulator_itemSizeOffsetDifference,
    Accumulator_selector_ptr,
    AccumulatorArmed,
    AccumulatorDisarmed,
    Conduit_transferItem_amount_ptr,
    Conduit_transferItem_from_ptr,
    Conduit_transferItem_identifier_ptr,
    Conduit_transferItem_size,
    Conduit_transferItem_to_ptr,
    Conduit_transferItem_token_ptr,
    FreeMemoryPointerSlot,
    OneWord,
    TwoWords
} from "seaport-types/src/lib/ConsiderationConstants.sol";

import {
    Error_selector_offset,
    NativeTokenTransferGenericFailure_error_account_ptr,
    NativeTokenTransferGenericFailure_error_amount_ptr,
    NativeTokenTransferGenericFailure_error_length,
    NativeTokenTransferGenericFailure_error_selector
} from "seaport-types/src/lib/ConsiderationErrorConstants.sol";

import {
    _revertInvalidCallToConduit,
    _revertInvalidConduit,
    _revertInvalidERC721TransferAmount,
    _revertUnusedItemParameters
} from "seaport-types/src/lib/ConsiderationErrors.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Executor
 * @author 0age
 * @notice Executor contains functions related to processing executions (i.e.
 *         transferring items, either directly or via conduits).
 */
contract Executor is Verifiers, TokenTransferrer {
    /**
     * @dev Derive and set hashes, reference chainId, and associated domain
     *      separator during deployment.
     *
     * @param conduitController A contract that deploys conduits, or proxies
     *                          that may optionally be used to transfer approved
     *                          ERC20/721/1155 tokens.
     */
    constructor(address conduitController) Verifiers(conduitController) {}

    /**
     * @dev Internal function to transfer a given item, either directly or via
     *      a corresponding conduit.
     *
     * @param item        The item to transfer, including an amount and a
     *                    recipient.
     * @param from        The account supplying the item.
     * @param conduitKey  A bytes32 value indicating what corresponding conduit,
     *                    if any, to source token approvals from. The zero hash
     *                    signifies that no conduit should be used, with direct
     *                    approvals set on this contract.
     * @param accumulator An open-ended array that collects transfers to execute
     *                    against a given conduit in a single call.
     */
    function _transfer(ReceivedItem memory item, address from, bytes32 conduitKey, bytes memory accumulator) internal {
        // If the item type indicates Ether or a native token...
        if (item.itemType == ItemType.NATIVE) {
            // Ensure neither the token nor the identifier parameters are set.
            if ((uint160(item.token) | item.identifier) != 0) {
                _revertUnusedItemParameters();
            }

            // transfer the native tokens to the recipient.
            _transferNativeTokens(item.recipient, item.amount);
        } else if (item.itemType == ItemType.ERC20) {
            // Ensure that no identifier is supplied.
            if (item.identifier != 0) {
                _revertUnusedItemParameters();
            }

            // Transfer ERC20 tokens from the source to the recipient.
            _transferERC20(item.token, from, item.recipient, item.amount, conduitKey, accumulator);
        } else if (item.itemType == ItemType.ERC721) {
            // Transfer ERC721 token from the source to the recipient.
            _transferERC721(item.token, from, item.recipient, item.identifier, item.amount, conduitKey, accumulator);
        } else {
            // Transfer ERC1155 token from the source to the recipient.
            _transferERC1155(item.token, from, item.recipient, item.identifier, item.amount, conduitKey, accumulator);
        }
    }

    /**
     * @dev Internal function to transfer Ether or other native tokens to a
     *      given recipient.
     *
     * @param to     The recipient of the transfer.
     * @param amount The amount to transfer.
     */
    function _transferNativeTokens(address payable to, uint256 amount) internal {
        // Ensure that the supplied amount is non-zero.
        _assertNonZeroAmount(amount);

        // Declare a variable indicating whether the call was successful or not.
        bool success;

        assembly {
            // Transfer the native token and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }

        // If the call fails...
        if (!success) {
            // Revert and pass the revert reason along if one was returned.
            _revertWithReasonIfOneIsReturned();

            // Otherwise, revert with a generic error message.
            assembly {
                // Store left-padded selector with push4, mem[28:32] = selector
                mstore(0, NativeTokenTransferGenericFailure_error_selector)

                // Write `to` and `amount` arguments.
                mstore(NativeTokenTransferGenericFailure_error_account_ptr, to)
                mstore(NativeTokenTransferGenericFailure_error_amount_ptr, amount)

                // revert(abi.encodeWithSignature(
                //     "NativeTokenTransferGenericFailure(address,uint256)",
                //     to,
                //     amount
                // ))
                revert(Error_selector_offset, NativeTokenTransferGenericFailure_error_length)
            }
        }
    }

    /**
     * @dev Internal function to transfer ERC20 tokens from a given originator
     *      to a given recipient using a given conduit if applicable. Sufficient
     *      approvals must be set on this contract or on a respective conduit.
     *
     * @param token       The ERC20 token to transfer.
     * @param from        The originator of the transfer.
     * @param to          The recipient of the transfer.
     * @param amount      The amount to transfer.
     * @param conduitKey  A bytes32 value indicating what corresponding conduit,
     *                    if any, to source token approvals from. The zero hash
     *                    signifies that no conduit should be used, with direct
     *                    approvals set on this contract.
     * @param accumulator An open-ended array that collects transfers to execute
     *                    against a given conduit in a single call.
     */
    function _transferERC20(
        address token,
        address from,
        address to,
        uint256 amount,
        bytes32 conduitKey,
        bytes memory accumulator
    ) internal {
        // Ensure that the supplied amount is non-zero.
        _assertNonZeroAmount(amount);

        // Trigger accumulated transfers if the conduits differ.
        _triggerIfArmedAndNotAccumulatable(accumulator, conduitKey);

        // If no conduit has been specified...
        if (conduitKey == bytes32(0)) {
            // Perform the token transfer directly.
            _performERC20Transfer(token, from, to, amount);
        } else {
            // Insert the call to the conduit into the accumulator.
            _insert(conduitKey, accumulator, ConduitItemType.ERC20, token, from, to, uint256(0), amount);
        }
    }

    /**
     * @dev Internal function to transfer a single ERC721 token from a given
     *      originator to a given recipient. Sufficient approvals must be set,
     *      either on the respective conduit or on this contract itself.
     *
     * @param token       The ERC721 token to transfer.
     * @param from        The originator of the transfer.
     * @param to          The recipient of the transfer.
     * @param identifier  The tokenId to transfer.
     * @param amount      The amount to transfer (must be 1 for ERC721).
     * @param conduitKey  A bytes32 value indicating what corresponding conduit,
     *                    if any, to source token approvals from. The zero hash
     *                    signifies that no conduit should be used, with direct
     *                    approvals set on this contract.
     * @param accumulator An open-ended array that collects transfers to execute
     *                    against a given conduit in a single call.
     */
    function _transferERC721(
        address token,
        address from,
        address to,
        uint256 identifier,
        uint256 amount,
        bytes32 conduitKey,
        bytes memory accumulator
    ) internal {
        // Trigger accumulated transfers if the conduits differ.
        _triggerIfArmedAndNotAccumulatable(accumulator, conduitKey);

        // If no conduit has been specified...
        if (conduitKey == bytes32(0)) {
            // Ensure that exactly one 721 item is being transferred.
            if (amount != 1) {
                _revertInvalidERC721TransferAmount(amount);
            }

            // Perform transfer via the token contract directly.
            _performERC721Transfer(token, from, to, identifier);
        } else {
            // Insert the call to the conduit into the accumulator.
            _insert(conduitKey, accumulator, ConduitItemType.ERC721, token, from, to, identifier, amount);
        }
    }

    /**
     * @dev Internal function to transfer ERC1155 tokens from a given originator
     *      to a given recipient. Sufficient approvals must be set, either on
     *      the respective conduit or on this contract itself.
     *
     * @param token       The ERC1155 token to transfer.
     * @param from        The originator of the transfer.
     * @param to          The recipient of the transfer.
     * @param identifier  The id to transfer.
     * @param amount      The amount to transfer.
     * @param conduitKey  A bytes32 value indicating what corresponding conduit,
     *                    if any, to source token approvals from. The zero hash
     *                    signifies that no conduit should be used, with direct
     *                    approvals set on this contract.
     * @param accumulator An open-ended array that collects transfers to execute
     *                    against a given conduit in a single call.
     */
    function _transferERC1155(
        address token,
        address from,
        address to,
        uint256 identifier,
        uint256 amount,
        bytes32 conduitKey,
        bytes memory accumulator
    ) internal {
        // Ensure that the supplied amount is non-zero.
        _assertNonZeroAmount(amount);

        // Trigger accumulated transfers if the conduits differ.
        _triggerIfArmedAndNotAccumulatable(accumulator, conduitKey);

        // If no conduit has been specified...
        if (conduitKey == bytes32(0)) {
            // Perform transfer via the token contract directly.
            _performERC1155Transfer(token, from, to, identifier, amount);
        } else {
            // Insert the call to the conduit into the accumulator.
            _insert(conduitKey, accumulator, ConduitItemType.ERC1155, token, from, to, identifier, amount);
        }
    }

    /**
     * @dev Internal function to trigger a call to the conduit currently held by
     *      the accumulator if the accumulator contains item transfers (i.e. it
     *      is "armed") and the supplied conduit key does not match the key held
     *      by the accumulator.
     *
     * @param accumulator An open-ended array that collects transfers to execute
     *                    against a given conduit in a single call.
     * @param conduitKey  A bytes32 value indicating what corresponding conduit,
     *                    if any, to source token approvals from. The zero hash
     *                    signifies that no conduit should be used, with direct
     *                    approvals set on this contract.
     */
    function _triggerIfArmedAndNotAccumulatable(bytes memory accumulator, bytes32 conduitKey) internal {
        // Retrieve the current conduit key from the accumulator.
        bytes32 accumulatorConduitKey = _getAccumulatorConduitKey(accumulator);

        // Perform conduit call if the set key does not match the supplied key.
        if (accumulatorConduitKey != conduitKey) {
            _triggerIfArmed(accumulator);
        }
    }

    /**
     * @dev Internal function to trigger a call to the conduit currently held by
     *      the accumulator if the accumulator contains item transfers (i.e. it
     *      is "armed").
     *
     * @param accumulator An open-ended array that collects transfers to execute
     *                    against a given conduit in a single call.
     */
    function _triggerIfArmed(bytes memory accumulator) internal {
        // Exit if the accumulator is not "armed".
        if (accumulator.length != AccumulatorArmed) {
            return;
        }

        // Retrieve the current conduit key from the accumulator.
        bytes32 accumulatorConduitKey = _getAccumulatorConduitKey(accumulator);

        // Perform conduit call.
        _trigger(accumulatorConduitKey, accumulator);
    }

    /**
     * @dev Internal function to trigger a call to the conduit corresponding to
     *      a given conduit key, supplying all accumulated item transfers. The
     *      accumulator will be "disarmed" and reset in the process.
     *
     * @param conduitKey  A bytes32 value indicating what corresponding conduit,
     *                    if any, to source token approvals from. The zero hash
     *                    signifies that no conduit should be used, with direct
     *                    approvals set on this contract.
     * @param accumulator An open-ended array that collects transfers to execute
     *                    against a given conduit in a single call.
     */
    function _trigger(bytes32 conduitKey, bytes memory accumulator) internal {
        // Declare variables for offset in memory & size of calldata to conduit.
        uint256 callDataOffset;
        uint256 callDataSize;

        // Call the conduit with all the accumulated transfers.
        assembly {
            // Call begins at third word; the first is length or "armed" status,
            // and the second is the current conduit key.
            callDataOffset := add(accumulator, TwoWords)

            // 68 + items * 192
            callDataSize :=
                add(
                    Accumulator_array_offset_ptr,
                    mul(mload(add(accumulator, Accumulator_array_length_ptr)), Conduit_transferItem_size)
                )
        }

        // Call conduit derived from conduit key & supply accumulated transfers.
        _callConduitUsingOffsets(conduitKey, callDataOffset, callDataSize);

        // Reset accumulator length to signal that it is now "disarmed".
        assembly {
            mstore(accumulator, AccumulatorDisarmed)
        }
    }

    /**
     * @dev Internal function to perform a call to the conduit corresponding to
     *      a given conduit key based on the offset and size of the calldata in
     *      question in memory.
     *
     * @param conduitKey     A bytes32 value indicating what corresponding
     *                       conduit, if any, to source token approvals from.
     *                       The zero hash signifies that no conduit should be
     *                       used, with direct approvals set on this contract.
     * @param callDataOffset The memory pointer where calldata is contained.
     * @param callDataSize   The size of calldata in memory.
     */
    function _callConduitUsingOffsets(bytes32 conduitKey, uint256 callDataOffset, uint256 callDataSize) internal {
        // Derive the address of the conduit using the conduit key.
        address conduit = _deriveConduit(conduitKey);

        bool success;
        bytes4 result;

        // call the conduit.
        assembly {
            // Ensure first word of scratch space is empty.
            mstore(0, 0)

            // Perform call, placing first word of return data in scratch space.
            success := call(gas(), conduit, 0, callDataOffset, callDataSize, 0, OneWord)

            // Take value from scratch space and place it on the stack.
            result := mload(0)
        }

        // If the call failed...
        if (!success) {
            // Pass along whatever revert reason was given by the conduit.
            _revertWithReasonIfOneIsReturned();

            // Otherwise, revert with a generic error.
            _revertInvalidCallToConduit(conduit);
        }

        // Ensure result was extracted and matches EIP-1271 magic value.
        if (result != ConduitInterface.execute.selector) {
            _revertInvalidConduit(conduitKey, conduit);
        }
    }

    /**
     * @dev Internal pure function to retrieve the current conduit key set for
     *      the accumulator.
     *
     * @param accumulator An open-ended array that collects transfers to execute
     *                    against a given conduit in a single call.
     *
     * @return accumulatorConduitKey The conduit key currently set for the
     *                               accumulator.
     */
    function _getAccumulatorConduitKey(bytes memory accumulator)
        internal
        pure
        returns (bytes32 accumulatorConduitKey)
    {
        // Retrieve the current conduit key from the accumulator.
        assembly {
            accumulatorConduitKey := mload(add(accumulator, Accumulator_conduitKey_ptr))
        }
    }

    /**
     * @dev Internal pure function to place an item transfer into an accumulator
     *      that collects a series of transfers to execute against a given
     *      conduit in a single call.
     *
     * @param conduitKey  A bytes32 value indicating what corresponding conduit,
     *                    if any, to source token approvals from. The zero hash
     *                    signifies that no conduit should be used, with direct
     *                    approvals set on this contract.
     * @param accumulator An open-ended array that collects transfers to execute
     *                    against a given conduit in a single call.
     * @param itemType    The type of the item to transfer.
     * @param token       The token to transfer.
     * @param from        The originator of the transfer.
     * @param to          The recipient of the transfer.
     * @param identifier  The tokenId to transfer.
     * @param amount      The amount to transfer.
     */
    function _insert(
        bytes32 conduitKey,
        bytes memory accumulator,
        ConduitItemType itemType,
        address token,
        address from,
        address to,
        uint256 identifier,
        uint256 amount
    ) internal pure {
        uint256 elements;
        // "Arm" and prime accumulator if it's not already armed. The sentinel
        // value is held in the length of the accumulator array.
        if (accumulator.length == AccumulatorDisarmed) {
            elements = 1;
            bytes4 selector = ConduitInterface.execute.selector;
            assembly {
                mstore(accumulator, AccumulatorArmed) // "arm" the accumulator.
                mstore(add(accumulator, Accumulator_conduitKey_ptr), conduitKey)
                mstore(add(accumulator, Accumulator_selector_ptr), selector)
                mstore(add(accumulator, Accumulator_array_offset_ptr), Accumulator_array_offset)
                mstore(add(accumulator, Accumulator_array_length_ptr), elements)
            }
        } else {
            // Otherwise, increase the number of elements by one.
            assembly {
                elements := add(mload(add(accumulator, Accumulator_array_length_ptr)), 1)
                mstore(add(accumulator, Accumulator_array_length_ptr), elements)
            }
        }

        // Insert the item.
        assembly {
            let itemPointer :=
                sub(add(accumulator, mul(elements, Conduit_transferItem_size)), Accumulator_itemSizeOffsetDifference)
            mstore(itemPointer, itemType)
            mstore(add(itemPointer, Conduit_transferItem_token_ptr), token)
            mstore(add(itemPointer, Conduit_transferItem_from_ptr), from)
            mstore(add(itemPointer, Conduit_transferItem_to_ptr), to)
            mstore(add(itemPointer, Conduit_transferItem_identifier_ptr), identifier)
            mstore(add(itemPointer, Conduit_transferItem_amount_ptr), amount)
        }
    }

    function _transferFromPool(ReceivedItem memory item, address from) internal {
        // If the item type indicates Ether or a native token...
        if (item.itemType == ItemType.NATIVE) {
            // Ensure neither the token nor the identifier parameters are set.
            if ((uint160(item.token) | item.identifier) != 0) {
                _revertUnusedItemParameters();
            }

            // transfer the native tokens to the recipient.
            _transferNativeTokens(item.recipient, item.amount);
        } else if (item.itemType == ItemType.ERC20) {
            // Ensure that no identifier is supplied.
            if (item.identifier != 0) {
                _revertUnusedItemParameters();
            }

            // Transfer ERC20 tokens from the source to the recipient.
            safeTransferERC20(item.token, from, item.recipient, item.amount);
        } else if (item.itemType == ItemType.ERC721) {
            if (item.amount != 1) {
                _revertInvalidERC721TransferAmount(item.amount);
            }

            // Perform transfer via the token contract directly.
            _performERC721Transfer(item.token, from, item.recipient, item.identifier);
        } else {
            // Transfer ERC1155 token from the source to the recipient.
            _performERC1155Transfer(item.token, from, item.recipient, item.identifier, item.amount);
        }
    }

    function safeTransferERC20(
        address _currency,
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        if (_from == _to) {
            return;
        }

        if (_from == address(this)) {
            IERC20(_currency).safeTransfer(_to, _amount);
        } else {
            IERC20(_currency).safeTransferFrom(_from, _to, _amount);
        }
    }
}
