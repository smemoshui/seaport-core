// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Side, ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";

import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Execution,
    Fulfillment,
    FulfillmentComponent,
    OfferItem,
    OrderParameters,
    ReceivedItem,
    OrderProbility
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {OrderFulfiller} from "./OrderFulfiller.sol";

import {FulfillmentApplier} from "./FulfillmentApplier.sol";

import {
    _revertConsiderationNotMet,
    _revertInsufficientNativeTokensSupplied,
    _revertInvalidNativeOfferItem,
    _revertNoSpecifiedOrdersAvailable
} from "seaport-types/src/lib/ConsiderationErrors.sol";

import {
    AccumulatorDisarmed,
    ConsiderationItem_recipient_offset,
    Execution_offerer_offset,
    NonMatchSelector_InvalidErrorValue,
    NonMatchSelector_MagicMask,
    OneWord,
    OneWordShift,
    OrdersMatchedTopic0,
    ReceivedItem_amount_offset,
    ReceivedItem_recipient_offset,
    TwoWords
} from "seaport-types/src/lib/ConsiderationConstants.sol";
import "hardhat/console.sol";

/**
 * @title OrderCombiner
 * @author 0age
 * @notice OrderCombiner contains logic for fulfilling combinations of orders,
 *         either by matching offer items to consideration items or by
 *         fulfilling orders where available.
 */
contract OrderCombiner is OrderFulfiller, FulfillmentApplier {
    /**
     * @dev Derive and set hashes, reference chainId, and associated domain
     *      separator during deployment.
     *
     * @param conduitController A contract that deploys conduits, or proxies
     *                          that may optionally be used to transfer approved
     *                          ERC20/721/1155 tokens.
     */
    constructor(address conduitController) OrderFulfiller(conduitController) {}

     /**
     * @dev Internal function to validate a group of orders, update their
     *      statuses, reduce amounts by their previously filled fractions, apply
     *      criteria resolvers, and emit OrderFulfilled events. Note that this
     *      function needs to be called before
     *      _aggregateValidFulfillmentConsiderationItems to set the memory
     *      layout that _aggregateValidFulfillmentConsiderationItems depends on.
     *
     * @param advancedOrders    The advanced orders to validate and reduce by
     *                          their previously filled amounts.
     * @param maximumFulfilled  The maximum number of orders to fulfill.
     *
     * @return orderHashes     The hashes of the orders being fulfilled.
     */
    function _validateOrdersAndFulfillWithRandom(
        AdvancedOrder[] memory advancedOrders,
        bytes32[] memory existingOrderHahes,
        uint256 maximumFulfilled,
        OrderProbility[] memory orderProbility
    ) internal returns (bytes32[] memory orderHashes) {
        // Ensure this function cannot be triggered during a reentrant call.
        _setReentrancyGuard(true); // Native tokens accepted during execution.

        // Declare an error buffer indicating status of any native offer items.
        // Native tokens may only be provided as part of contract orders or when
        // fulfilling via matchOrders or matchAdvancedOrders; if bits indicating
        // these conditions are not met have been set, throw.
        uint256 invalidNativeOfferItemErrorBuffer;

        // Use assembly to set the value for the second bit of the error buffer.
        // 这里是个奇怪的地方 如果我随便改名字和参数 这里是不是不一样了
        assembly {
            /**
             * Use the 231st bit of the error buffer to indicate whether the
             * current function is not matchAdvancedOrders or matchOrders.
             *
             * sig                                func
             * -----------------------------------------------------------------
             * 1010100000010111010001000 0 000100 matchOrders
             * 1111001011010001001010110 0 010010 matchAdvancedOrders
             * 1110110110011000101001010 1 110100 fulfillAvailableOrders
             * 1000011100100000000110110 1 000001 fulfillAvailableAdvancedOrders
             *                           ^ 7th bit
             */
            invalidNativeOfferItemErrorBuffer := and(NonMatchSelector_MagicMask, calldataload(0))
        }

        // Declare variables for later use.
        AdvancedOrder memory advancedOrder;
        uint256 terminalMemoryOffset;

        unchecked {
            // Read length of orders array and place on the stack.
            uint256 totalOrders = advancedOrders.length;

            // Track the order hash for each order being fulfilled.
            orderHashes = new bytes32[](totalOrders);

            // Determine the memory offset to terminate on during loops.
            terminalMemoryOffset = (totalOrders + 1) << OneWordShift;
        }

        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Declare inner variables.
            OfferItem[] memory offer;
            ConsiderationItem[] memory consideration;

            // Iterate over each order.
            for (uint256 i = OneWord; i < terminalMemoryOffset; i += OneWord) {
                // Retrieve order using assembly to bypass out-of-range check.
                assembly {
                    advancedOrder := mload(add(advancedOrders, i))
                }

                // Determine if max number orders have already been fulfilled.
                if (maximumFulfilled == 0) {
                    // Mark fill fraction as zero as the order will not be used.
                    advancedOrder.numerator = 0;

                    // Continue iterating through the remaining orders.
                    continue;
                }

                // Validate it, update status, and determine fraction to fill.
                OrderParameters memory orderParameters = advancedOrder.parameters;
                bytes32 orderHash = _assertConsiderationLengthAndGetOrderHash(orderParameters);
                require(checkIfOrderHashesExists(existingOrderHahes, orderHash), "Mismatch orders data with request id");
                (uint256 numerator, uint256 denominator) = _getLastMatchStatus(orderHash);
                (uint256 luckyNumerator, uint256 luckyDenominator) = checkIfProbilityExists(orderProbility, orderHash);

                // Do not track hash or adjust prices if order is not fulfilled.
                if (numerator == 0) {
                    // Mark fill fraction as zero if the order is not fulfilled.
                    advancedOrder.numerator = 0;

                    // Continue iterating through the remaining orders.
                    continue;
                }

                // Otherwise, track the order hash in question.
                // OneWordShift 0x5 所以是32位 正好是bytes32
                assembly {
                    mstore(add(orderHashes, i), orderHash)
                }

                // Decrement the number of fulfilled orders.
                // Skip underflow check as the condition before
                // implies that maximumFulfilled > 0.
                --maximumFulfilled;

                // Place the start time for the order on the stack.
                uint256 startTime = advancedOrder.parameters.startTime;

                // Place the end time for the order on the stack.
                uint256 endTime = advancedOrder.parameters.endTime;

                // Retrieve array of offer items for the order in question.
                offer = advancedOrder.parameters.offer;

                // Read length of offer array and place on the stack.
                uint256 totalOfferItems = offer.length;

                {
                    // Determine the order type, used to check for eligibility
                    // for native token offer items as well as for the presence
                    // of restricted and contract orders (or non-open orders).
                    OrderType orderType = advancedOrder.parameters.orderType;

                    // Utilize assembly to efficiently check for order types.
                    // Note that these checks expect that there are no order
                    // types beyond the current set (0-4) and will need to be
                    // modified if more order types are added.
                    assembly {
                        // Declare a variable indicating if the order is not a
                        // contract order. Cache in scratch space to avoid stack
                        // depth errors.
                        let isNonContract := lt(orderType, 4)
                        mstore(0, isNonContract)
                    }
                }

                // Iterate over each offer item on the order.
                for (uint256 j = 0; j < totalOfferItems; ++j) {
                    // Retrieve the offer item.
                    OfferItem memory offerItem = offer[j];

                    // If the offer item is for the native token and the order
                    // type is not a contract order type, set the first bit of
                    // the error buffer to true.
                    assembly {
                        invalidNativeOfferItemErrorBuffer :=
                            or(invalidNativeOfferItemErrorBuffer, lt(mload(offerItem), mload(0)))
                    }

                    // Apply order fill fraction to offer item end amount.
                    uint256 endAmount = _getFraction(numerator, denominator, offerItem.endAmount);

                    // Reuse same fraction if start and end amounts are equal.
                    if (offerItem.startAmount == offerItem.endAmount) {
                        // Apply derived amount to both start and end amount.
                        offerItem.startAmount = endAmount;
                    } else {
                        // Apply order fill fraction to offer item start amount.
                        offerItem.startAmount = _getFraction(numerator, denominator, offerItem.startAmount);
                    }

                    uint256 currentAmount = _locateLuckyAmount(
                        offerItem.startAmount,
                        endAmount,
                        luckyNumerator,
                        luckyDenominator,
                        false // round up
                    );

                    // Do not change offer amount
                    // Update amounts in memory to match the current amount.
                    offerItem.startAmount = currentAmount;
                    // Note that the end amount is used to track extra amount.
                    offerItem.endAmount = endAmount - currentAmount;
                }

                // Retrieve array of consideration items for order in question.
                consideration = (advancedOrder.parameters.consideration);

                // Read length of consideration array and place on the stack.
                uint256 totalConsiderationItems = consideration.length;

                // Iterate over each consideration item on the order.
                for (uint256 j = 0; j < totalConsiderationItems; ++j) {
                    // Retrieve the consideration item.
                    ConsiderationItem memory considerationItem = (consideration[j]);

                    // Apply fraction to consideration item end amount.
                    uint256 endAmount = _getFraction(numerator, denominator, considerationItem.endAmount);

                    // Reuse same fraction if start and end amounts are equal.
                    if (considerationItem.startAmount == considerationItem.endAmount) {
                        // Apply derived amount to both start and end amount.
                        considerationItem.startAmount = endAmount;
                    } else {
                        // Apply fraction to consideration item start amount.
                        considerationItem.startAmount =
                            _getFraction(numerator, denominator, considerationItem.startAmount);
                    }

                    // Adjust consideration amount using current time; round up.
                    uint256 currentAmount = _locateLuckyAmount(
                        considerationItem.startAmount,
                        endAmount,
                        luckyNumerator,
                        luckyDenominator,
                        true // round up
                    );
                    considerationItem.startAmount = currentAmount;

                    // Utilize assembly to manually "shift" the recipient value,
                    // then to copy the start amount to the recipient.
                    // Note that this sets up the memory layout that is
                    // subsequently relied upon by
                    // _aggregateValidFulfillmentConsiderationItems.
                    assembly {
                        // Derive the pointer to the recipient using the item
                        // pointer along with the offset to the recipient.
                        let considerationItemRecipientPtr :=
                            add(
                                considerationItem,
                                ConsiderationItem_recipient_offset // recipient
                            )

                        // Write recipient to endAmount, as endAmount is not
                        // used from this point on and can be repurposed to fit
                        // the layout of a ReceivedItem.
                        mstore(
                            add(
                                considerationItem,
                                ReceivedItem_recipient_offset // old endAmount
                            ),
                            mload(considerationItemRecipientPtr)
                        )

                        // Write startAmount to recipient, as recipient is not
                        // used from this point on and can be repurposed to
                        // track received amounts.
                        mstore(considerationItemRecipientPtr, currentAmount)
                    }
                }
            }
        }

        // If the first bit is set, a native offer item was encountered on an
        // order that is not a contract order. If the 231st bit is set in the
        // error buffer, the current function is not matchOrders or
        // matchAdvancedOrders. If the value is 1 + (1 << 230), then both the
        // 1st and 231st bits were set; in that case, revert with an error.
        if (invalidNativeOfferItemErrorBuffer == NonMatchSelector_InvalidErrorValue) {
            _revertInvalidNativeOfferItem();
        }
        // Emit an event for each order signifying that it has been fulfilled.
        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            bytes32 orderHash;

            // Iterate over each order.
            for (uint256 i = OneWord; i < terminalMemoryOffset; i += OneWord) {
                assembly {
                    orderHash := mload(add(orderHashes, i))
                }

                // Do not emit an event if no order hash is present.
                if (orderHash == bytes32(0)) {
                    continue;
                }

                // Retrieve order using assembly to bypass out-of-range check.
                assembly {
                    advancedOrder := mload(add(advancedOrders, i))
                }

                // Retrieve parameters for the order in question.
                OrderParameters memory orderParameters = (advancedOrder.parameters);

                // Emit an OrderFulfilled event.
                _emitOrderFulfilledEvent(
                    orderHash,
                    orderParameters.offerer,
                    orderParameters.zone,
                    address(this),
                    orderParameters.offer,
                    orderParameters.consideration
                );
            }
        }
    }

    function checkIfOrderHashesExists(bytes32[] memory orderHashes, bytes32 orderHash) internal returns(bool) {
        for(uint i = 0; i < orderHashes.length; ++i) {
            if(orderHashes[i] == orderHash) {
                return true;
            }
        }
        return false;
    }

    function checkIfProbilityExists(OrderProbility[] memory orderProbility, bytes32 orderHash) internal returns(uint256, uint256) {
        for(uint i = 0; i < orderProbility.length; i++) {
            if(orderProbility[i].orderHash == orderHash) {
                return (orderProbility[i].numerator, orderProbility[i].denominator);
            }
        }
        return (1, 1);
    }

    function _validateAndPrepareOrdersWithRandom(
        AdvancedOrder[] memory advancedOrders,
        bool revertOnInvalid,
        uint256 maximumFulfilled
    ) internal returns (uint120[] memory numerators, uint120[] memory denominators, bytes32[] memory orderHashes) {
        // Ensure this function cannot be triggered during a reentrant call.
        _setReentrancyGuard(true); // Native tokens accepted during execution.

        // Declare variables for later use.
        AdvancedOrder memory advancedOrder;
        uint256 terminalMemoryOffset;

        unchecked {
            // Read length of orders array and place on the stack.
            uint256 totalOrders = advancedOrders.length;

            // Track the order hash for each order being fulfilled.
            orderHashes = new bytes32[](totalOrders);
            numerators = new uint120[](totalOrders);
            denominators = new uint120[](totalOrders);

            // Determine the memory offset to terminate on during loops.
            terminalMemoryOffset = (totalOrders + 1) << OneWordShift;
        }
        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Declare inner variables.
            OfferItem[] memory offer;
            ConsiderationItem[] memory consideration;

            // Iterate over each order.
            for (uint256 i = OneWord; i < terminalMemoryOffset; i += OneWord) {
                // Retrieve order using assembly to bypass out-of-range check.
                assembly {
                    advancedOrder := mload(add(advancedOrders, i))
                }

                // Determine if max number orders have already been fulfilled.
                if (maximumFulfilled == 0) {
                    // Mark fill fraction as zero as the order will not be used.
                    advancedOrder.numerator = 0;

                    // Continue iterating through the remaining orders.
                    continue;
                }

                // Validate it, update status, and determine fraction to fill.
                (bytes32 orderHash, uint120 numerator, uint120 denominator) =
                    _validateOrderAndUpdateStatus(advancedOrder, revertOnInvalid);
                // Do not track hash or adjust prices if order is not fulfilled.
                if (numerator == 0) {
                    // Mark fill fraction as zero if the order is not fulfilled.
                    advancedOrder.numerator = 0;

                    // Continue iterating through the remaining orders.
                    continue;
                }

                // Otherwise, track the order hash in question.
                // OneWordShift 0x5 所以是32位 正好是bytes32
                assembly {
                    mstore(add(orderHashes, i), orderHash)
                }

                numerators[i/OneWord - 1] = numerator;
                denominators[i/OneWord - 1] = denominator;

                // Decrement the number of fulfilled orders.
                // Skip underflow check as the condition before
                // implies that maximumFulfilled > 0.
                --maximumFulfilled;

                // Place the start time for the order on the stack.
                uint256 startTime = advancedOrder.parameters.startTime;

                // Place the end time for the order on the stack.
                uint256 endTime = advancedOrder.parameters.endTime;

                // Retrieve array of offer items for the order in question.
                offer = advancedOrder.parameters.offer;

                // Read length of offer array and place on the stack.
                uint256 totalOfferItems = offer.length;

                // Iterate over each offer item on the order.
                for (uint256 j = 0; j < totalOfferItems; ++j) {
                    // Retrieve the offer item.
                    OfferItem memory offerItem = offer[j];

                    // Apply order fill fraction to offer item end amount.
                    // 这个numerator 和 denominator还是要看懂
                    uint256 endAmount = _getFraction(numerator, denominator, offerItem.endAmount);

                    // Reuse same fraction if start and end amounts are equal.
                    if (offerItem.startAmount == offerItem.endAmount) {
                        // Apply derived amount to both start and end amount.
                        offerItem.startAmount = endAmount;
                    } else {
                        // Apply order fill fraction to offer item start amount.
                        offerItem.startAmount = _getFraction(numerator, denominator, offerItem.startAmount);
                    }

                    // Update amounts in memory to match the current amount.
                    // Note that the end amount is used to track spent amounts.
                    offerItem.startAmount = offerItem.endAmount;
                }
                console.log("Finish one order");
            }
        }
    }


     /**
     * @dev Internal function to perform a final check that each consideration
     *      item for an arbitrary number of fulfilled orders has been met and to
     *      trigger associated executions, transferring the respective items.
     *
     * @param advancedOrders  The orders to check and perform executions for.
     * @param executions      An array of elements indicating the sequence of
     *                        transfers to perform when fulfilling the given
     *                        orders.
     * @param orderHashes     An array of order hashes for each order.
     *
     * @return returnBack      An array of booleans indicating if each order
     *                         with an index corresponding to the index of the
     *                         returned boolean was fulfillable or not.
     */
    function _performFinalChecksAndExecuteOrdersWithRandom(
        AdvancedOrder[] memory advancedOrders,
        Execution[] memory executions,
        bytes32[] memory orderHashes
    ) internal returns (bool) {
        // Retrieve the length of the advanced orders array and place on stack.
        uint256 totalOrders = advancedOrders.length;

        // Initialize array for tracking available orders.
        bool[] memory availableOrders = new bool[](totalOrders);

        bool returnBack = false;
        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Iterate over each order.
            for (uint256 i = 0; i < totalOrders; ++i) {
                // Retrieve the order in question.
                AdvancedOrder memory advancedOrder = advancedOrders[i];

                // Skip the order in question if not being not fulfilled.
                if (advancedOrder.numerator == 0) {
                    // Explicitly set availableOrders at the given index to
                    // guard against the possibility of dirtied memory.
                    availableOrders[i] = false;
                    continue;
                }

                // Mark the order as available.
                availableOrders[i] = true;

                // Retrieve the order parameters.
                OrderParameters memory parameters = advancedOrder.parameters;

                {
                    // Read consideration items & ensure they are fulfilled.
                    ConsiderationItem[] memory consideration = (parameters.consideration);

                    // Read length of consideration array & place on stack.
                    uint256 totalConsiderationItems = consideration.length;

                    // Iterate over each consideration item.
                    for (uint256 j = 0; j < totalConsiderationItems; ++j) {
                        ConsiderationItem memory considerationItem = (consideration[j]);

                        // Retrieve remaining amount on consideration item.
                        uint256 unmetAmount = considerationItem.startAmount;

                        // Revert if the remaining amount is not zero.
                        if (unmetAmount != 0) {
                            returnBack = true;
                            break;
                        }

                        // Utilize assembly to restore the original value.
                        assembly {
                            // Write recipient to startAmount.
                            mstore(
                                add(considerationItem, ReceivedItem_amount_offset),
                                mload(add(considerationItem, ConsiderationItem_recipient_offset))
                            )
                        }
                    }
                }
                // revert all execution back
                if(returnBack){
                    break;
                }
            }

            for (uint256 i = 0; i < totalOrders; ++i){
                // Retrieve the order in question.
                AdvancedOrder memory advancedOrder = advancedOrders[i];

                // Skip the order in question if not being not fulfilled.
                if (advancedOrder.numerator == 0) {
                    // Explicitly set availableOrders at the given index to
                    // guard against the possibility of dirtied memory.
                    availableOrders[i] = false;
                    continue;
                }

                bytes memory accumulator;
                // Retrieve the order parameters.
                OrderParameters memory parameters = advancedOrder.parameters;
                // Retrieve offer items.
                OfferItem[] memory offer = parameters.offer;

                // Read length of offer array & place on the stack.
                uint256 totalOfferItems = offer.length;

                // Iterate over each offer item to restore it.
                for (uint256 j = 0; j < totalOfferItems; ++j) {
                    // Retrieve the offer item in question.
                    OfferItem memory offerItem = offer[j];

                    // Transfer to recipient if unspent amount is not zero.
                    // Note that the transfer will not be reflected in the
                    // executions array.
                    if (offerItem.startAmount != 0 || offerItem.endAmount != 0) {
                        offerItem.startAmount = offerItem.startAmount + offerItem.endAmount;
                        uint256 originalEndAmount = _replaceEndAmountWithRecipient(offerItem, parameters.offerer);

                        // Transfer excess offer item amount to recipient.
                        _toOfferItemInput(_transferFromPool)(
                            offerItem, address(this), parameters.conduitKey, accumulator
                        );
                        // Restore the original endAmount in offerItem.
                        assembly {
                            mstore(add(offerItem, ReceivedItem_recipient_offset), originalEndAmount)
                        }
                    }
                }
            }
        }

        console.log("Transfer execution or return back");
        {
            // Declare a variable for the available native token balance.
            uint256 nativeTokenBalance;

            // Retrieve the length of the executions array and place on stack.
            uint256 totalExecutions = executions.length;
            bytes memory accumulator;
            // Iterate over each execution.
            for (uint256 i = 0; i < totalExecutions;) {
                // Retrieve the execution and the associated received item.
                Execution memory execution = executions[i];
                ReceivedItem memory item = execution.item;

                // If execution transfers native tokens, reduce value available.
                if (item.itemType == ItemType.NATIVE) {
                    // Get the current available balance of native tokens.
                    assembly {
                        nativeTokenBalance := selfbalance()
                    }

                    // Ensure that sufficient native tokens are still available.
                    if (item.amount > nativeTokenBalance) {
                        _revertInsufficientNativeTokensSupplied();
                    }
                }

                // Transfer the item specified by the execution.
                if(returnBack){
                    item.recipient = payable(execution.offerer);
                }
                _transferFromPool(item, address(this), execution.conduitKey, accumulator);

                // Skip overflow check as for loop is indexed starting at zero.
                unchecked {
                    ++i;
                }
            }
        }
        // Determine whether any native token balance remains.
        uint256 remainingNativeTokenBalance;
        assembly {
            remainingNativeTokenBalance := selfbalance()
        }

        // Return any remaining native token balance to the caller.
        if (remainingNativeTokenBalance != 0) {
            _transferNativeTokens(payable(msg.sender), remainingNativeTokenBalance);
        }

        // Clear the reentrancy guard.
        _clearReentrancyGuard();

        // Return the array containing available orders.
        return returnBack;
    }


    /**
     * @dev Internal function to emit an OrdersMatched event using the same
     *      memory region as the existing order hash array.
     *
     * @param orderHashes An array of order hashes to include as an argument for
     *                    the OrdersMatched event.
     */
    function _emitOrdersMatched(bytes32[] memory orderHashes) internal {
        assembly {
            // Load the array length from memory.
            let length := mload(orderHashes)

            // Get the full size of the event data - one word for the offset,
            // one for the array length and one per hash.
            let dataSize := add(TwoWords, shl(OneWordShift, length))

            // Get pointer to start of data, reusing word before array length
            // for the offset.
            let dataPointer := sub(orderHashes, OneWord)

            // Cache the existing word in memory at the offset pointer.
            let cache := mload(dataPointer)

            // Write an offset of 32.
            mstore(dataPointer, OneWord)

            // Emit the OrdersMatched event.
            log1(dataPointer, dataSize, OrdersMatchedTopic0)

            // Restore the cached word.
            mstore(dataPointer, cache)
        }
    }

    /**
     * @dev Internal function to match an arbitrary number of full or partial
     *      orders, each with an arbitrary number of items for offer and
     *      consideration, supplying criteria resolvers containing specific
     *      token identifiers and associated proofs as well as fulfillments
     *      allocating offer components to consideration components.
     *
     * @param advancedOrders    The advanced orders to match. Note that both the
     *                          offerer and fulfiller on each order must first
     *                          approve this contract (or their conduit if
     *                          indicated by the order) to transfer any relevant
     *                          tokens on their behalf and each consideration
     *                          recipient must implement `onERC1155Received` in
     *                          order to receive ERC1155 tokens. Also note that
     *                          the offer and consideration components for each
     *                          order must have no remainder after multiplying
     *                          the respective amount with the supplied fraction
     *                          in order for the group of partial fills to be
     *                          considered valid.
     * @param fulfillments      An array of elements allocating offer components
     *                          to consideration components. Note that each
     *                          consideration component must be fully met in
     *                          order for the match operation to be valid.
     * @return executions An array of elements indicating the sequence of
     *                    transfers performed as part of matching the given
     *                    orders.
     */
    function _matchAdvancedOrdersWithRandom(
        AdvancedOrder[] memory advancedOrders,
        Fulfillment[] memory fulfillments,
        bytes32[] memory existingOrderHahes,
        OrderProbility[] memory orderProbility
    ) internal returns (Execution[] memory executions, bool returnBack) {
        // Validate orders, update order status, and determine item amounts.
        (   
            bytes32[] memory orderHashes
        ) = _validateOrdersAndFulfillWithRandom(
            advancedOrders,
            existingOrderHahes,
            advancedOrders.length,
            orderProbility
        );

        // Fulfill the orders using the supplied fulfillments and recipient.
        return _fulfillAdvancedOrdersWithRandom(advancedOrders, fulfillments, orderHashes);
    }

    // Just do simple validation and calculate order hash
    function prepareOrdersWithRandom(
        AdvancedOrder[] memory advancedOrders,
        uint256[] memory premiumOrderIndexes,
        address[] memory recipients
    ) internal returns (Execution[] memory executions, bytes32[] memory orderHashes) {
        // Validate orders, update order status, and determine item amounts.
        uint120[] memory numerators;
        uint120[] memory denominators;
        (numerators, denominators, orderHashes) = _validateAndPrepareOrdersWithRandom(
            advancedOrders,
            true, // Signifies that invalid orders should revert.
            advancedOrders.length
        );

        for(uint256 i = 0; i < premiumOrderIndexes.length; ++i) {
            require(advancedOrders[premiumOrderIndexes[i]].parameters.consideration.length == 0, "Invalid premium order");
        }

        // Retrieve fulfillments array length and place on the stack.
        (Fulfillment[] memory fulfillments, uint256[] memory premiumExecutionIndexes) = _buildOfferFulfillments(advancedOrders, premiumOrderIndexes);
        require(recipients.length == premiumExecutionIndexes.length, "Mismatch premium recipients");
        (premiumExecutionIndexes, recipients) = sortArray(premiumExecutionIndexes, recipients);
        uint256 totalOfferFulfillments = fulfillments.length;
        uint256 premiumIndex = 0;

        // Allocate an execution for each offer fulfillment.
        executions = new Execution[](totalOfferFulfillments);

        // Lock offer item to the contract
        unchecked {
            uint256 totalFilteredExecutions = 0;
            uint256 totalPremiumExecution = premiumExecutionIndexes.length;
            for (uint256 i = 0; i < totalOfferFulfillments; ++i) {
                Fulfillment memory fulfillment = fulfillments[i];
                address recipent = address(this);
                // Change recipent as the premium recipient
                if(premiumIndex < totalPremiumExecution) {
                    if(i == premiumExecutionIndexes[premiumIndex]) {
                        recipent = recipients[premiumIndex];
                        ++premiumIndex;
                    }
                }
                Execution memory execution = _aggregateAvailable(
                    advancedOrders,
                    Side.OFFER,
                    fulfillment.offerComponents,
                    bytes32(0), // not used
                    recipent
                );
                // If the execution is filterable...
                if (_isFilterableExecution(execution)) {
                    // Increment total filtered executions.
                    ++totalFilteredExecutions;
                } else {
                    // Otherwise, assign the execution to the executions array.
                    executions[i - totalFilteredExecutions] = execution;
                }
            }
            // If some number of executions have been filtered...
            if (totalFilteredExecutions != 0) {
                // reduce the total length of the executions array.
                assembly {
                    mstore(executions, sub(mload(executions), totalFilteredExecutions))
                }
            }
        }

        bytes memory accumulator = new bytes(AccumulatorDisarmed);

        // Declare a variable for the available native token balance.
        uint256 nativeTokenBalance;
        {
            // Retrieve the length of the executions array and place on stack.
            uint256 totalExecutions = executions.length;
            console.log("Total execution is", totalExecutions);

            // Iterate over each execution.
            for (uint256 i = 0; i < totalExecutions;) {
                // Retrieve the execution and the associated received item.
                Execution memory execution = executions[i];
                ReceivedItem memory item = execution.item;

                // If execution transfers native tokens, reduce value available.
                if (item.itemType == ItemType.NATIVE) {
                    // Get the current available balance of native tokens.
                    assembly {
                        nativeTokenBalance := selfbalance()
                    }

                    // Ensure that sufficient native tokens are still available.
                    if (item.amount > nativeTokenBalance) {
                        _revertInsufficientNativeTokensSupplied();
                    }
                }

                // Transfer the item specified by the execution.
                _transfer(item, execution.offerer, execution.conduitKey, accumulator);
                // Skip overflow check as for loop is indexed starting at zero.
                unchecked {
                    ++i;
                }
            }
        }
        // Trigger it
        _triggerIfArmed(accumulator);
        uint256 orderHashIndex = 0;
        uint256 totalOrderHash = orderHashes.length;
        premiumOrderIndexes = sortArray(premiumOrderIndexes);
        premiumIndex = 0;
        uint256 totalPremiumOrderLength = premiumOrderIndexes.length;
        for(uint256 i = 0; i < totalOrderHash; ++i) {
            if(premiumIndex < totalPremiumOrderLength) {
                if(i == premiumOrderIndexes[premiumIndex]){
                    ++premiumIndex;
                    continue;
                }
            }
            if(i != orderHashIndex){
                orderHashes[orderHashIndex] = orderHashes[i];
            }
            _storeLastMatchStatus(orderHashes[i], numerators[i], denominators[i]);
            ++orderHashIndex;
        }

        if (totalPremiumOrderLength != 0) {
            // reduce the total length of the order hashes
            assembly {
                mstore(orderHashes, sub(mload(orderHashes), totalPremiumOrderLength))
            }
        } 
    }

    function sortArray(uint256[] memory arr) private pure returns (uint256[] memory) {
        uint256 l = arr.length;
        for(uint256 i = 0; i < l; i++) {
            for(uint256 j = i+1; j < l ;j++) {
                if(arr[i] > arr[j]) {
                    uint256 temp = arr[i];
                    arr[i] = arr[j];
                    arr[j] = temp;
                }
            }
        }
        return arr;
    }

    function sortArray(uint256[] memory arr, address[] memory recipients) private pure returns (uint256[] memory, address[] memory) {
        uint256 l = arr.length;
        for(uint256 i = 0; i < l; i++) {
            for(uint256 j = i+1; j < l ;j++) {
                if(arr[i] > arr[j]) {
                    uint256 temp = arr[i];
                    arr[i] = arr[j];
                    arr[j] = temp;

                    address addr = recipients[i];
                    recipients[i] = recipients[j];
                    recipients[j] = addr;
                }
            }
        }
        return (arr, recipients);
    }

    function _buildOfferFulfillments(
        AdvancedOrder[] memory advancedOrders,
        uint256[] memory premiumOrderIndexes
    ) internal returns (Fulfillment[] memory fulfillments, uint256[] memory premiumExecutionIndexes) {
        uint256 ordersLength = advancedOrders.length;
        uint256[] memory totalFulfillments = new uint256[](ordersLength);
        uint256 currOffers = 0;
        for(uint256 i = 0; i < ordersLength; ++i) {
            totalFulfillments[i] = currOffers;
            currOffers = currOffers + advancedOrders[i].parameters.offer.length;
        }
        fulfillments = new Fulfillment[](currOffers);
        uint256 index = 0;
        for(uint256 i = 0; i < ordersLength; ++i) {
            uint256 offerLength = advancedOrders[i].parameters.offer.length;
            for(uint256 j = 0; j < offerLength; ++j) {
                Fulfillment memory temp;
                temp.offerComponents = new FulfillmentComponent[](1);
                temp.offerComponents[0].orderIndex = i;
                temp.offerComponents[0].itemIndex = j;
                fulfillments[index] = temp;
                ++index;
            }
        }

        currOffers = 0;
        uint256 premiumLength = premiumOrderIndexes.length;
        for(uint256 i = 0; i < premiumLength; ++i) {
            index = premiumOrderIndexes[i];
            require(index < ordersLength, "Invalid premium order index");
            currOffers = currOffers + advancedOrders[index].parameters.offer.length;
        }

        index = 0;
        premiumExecutionIndexes = new uint256[](currOffers);
        for(uint256 i = 0; i < premiumLength; ++i) {
            uint256 orderIndex = premiumOrderIndexes[i];
            uint256 offerStart = totalFulfillments[orderIndex];
            uint256 offerLength = advancedOrders[orderIndex].parameters.offer.length;
            for(uint256 j = 0; j < offerLength; ++j) {
                premiumExecutionIndexes[index] = offerStart + j;
                ++index;
            }
        }
    }

    /**
     * @dev Internal function to fulfill an arbitrary number of orders, either
     *      full or partial, after validating, adjusting amounts, and applying
     *      criteria resolvers.
     *
     * @param advancedOrders  The orders to match, including a fraction to
     *                        attempt to fill for each order.
     * @param fulfillments    An array of elements allocating offer components
     *                        to consideration components. Note that the final
     *                        amount of each consideration component must be
     *                        zero for a match operation to be considered valid.
     * @param orderHashes     An array of order hashes for each order.
     *
     * @return executions An array of elements indicating the sequence of
     *                    transfers performed as part of matching the given
     *                    orders.
     */
    function _fulfillAdvancedOrdersWithRandom(
        AdvancedOrder[] memory advancedOrders,
        Fulfillment[] memory fulfillments,
        bytes32[] memory orderHashes
    ) internal returns (Execution[] memory executions, bool) {
        // Retrieve fulfillments array length and place on the stack.
        uint256 totalFulfillments = fulfillments.length;

        // Allocate executions by fulfillment and apply them to each execution.
        executions = new Execution[](totalFulfillments);
        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Track number of filtered executions.
            uint256 totalFilteredExecutions = 0;

            // Iterate over each fulfillment.
            for (uint256 i = 0; i < totalFulfillments; ++i) {
                /// Retrieve the fulfillment in question.
                Fulfillment memory fulfillment = fulfillments[i];

                // Derive the execution corresponding with the fulfillment.
                // 这里是匹配的过程 可不可以修改这里？
                // 看起来是直接修改上面是最好的 不修改下面
                Execution memory execution = _applyFulfillment(
                    advancedOrders, fulfillment.offerComponents, fulfillment.considerationComponents, i
                );
                console.log("Built one execution");
                // If the execution is filterable...
                if (_isFilterableExecution(execution)) {
                    // Increment total filtered executions.
                    ++totalFilteredExecutions;
                } else {
                    // Otherwise, assign the execution to the executions array.
                    executions[i - totalFilteredExecutions] = execution;
                }
                // skip the following execution since it should fail
                if (_isZeroExecution(execution)) {
                    totalFilteredExecutions += totalFulfillments - i - 1;
                    break;
                }
            }

            // If some number of executions have been filtered...
            if (totalFilteredExecutions != 0) {
                // reduce the total length of the executions array.
                assembly {
                    mstore(executions, sub(mload(executions), totalFilteredExecutions))
                }
            }
        }
        // change offer instead of recipient
        // Perform final checks and execute orders.
        bool returnBack = _performFinalChecksAndExecuteOrdersWithRandom(advancedOrders, executions, orderHashes);

        if(!returnBack) {
            // Emit OrdersMatched event, providing an array of matched order hashes.
            _emitOrdersMatched(orderHashes);
        }

        // Return the executions array.
        return (executions, returnBack);
    }

    /**
     * @dev Internal pure function to determine whether a given execution is
     *      filterable and may be removed from the executions array. The offerer
     *      and the recipient must be the same address and the item type cannot
     *      indicate a native token transfer.
     *
     * @param execution The execution to check for filterability.
     *
     * @return filterable A boolean indicating whether the execution in question
     *                    can be filtered from the executions array.
     */
    function _isFilterableExecution(Execution memory execution) internal pure returns (bool filterable) {
        // Utilize assembly to efficiently determine if execution is filterable.
        assembly {
            // Retrieve the received item referenced by the execution.
            let item := mload(execution)

            // Determine whether the execution is filterable.
            filterable :=
                and(
                    // Determine if offerer and recipient are the same address.
                    eq(
                        // Retrieve the recipient's address from the received item.
                        mload(add(item, ReceivedItem_recipient_offset)),
                        // Retrieve the offerer's address from the execution.
                        mload(add(execution, Execution_offerer_offset))
                    ),
                    // Determine if received item's item type is non-zero, thereby
                    // indicating that the execution does not involve native tokens.
                    iszero(iszero(mload(item)))
                )
        }
    }

    function _isZeroExecution(Execution memory execution) internal pure returns (bool isZero) {
        // Utilize assembly to efficiently determine if execution is filterable.
        assembly {
            // Retrieve the received item referenced by the execution.
            let item := mload(execution)

            // Determine whether the execution amount is zero.
            isZero := iszero(mload(add(item, ReceivedItem_amount_offset)))
        }
    }
}
