// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";

import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    OfferItem,
    OrderParameters,
    ReceivedItem,
    SpentItem
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {BasicOrderFulfiller} from "./BasicOrderFulfiller.sol";

import {CriteriaResolution} from "./CriteriaResolution.sol";

import {AmountDeriver} from "./AmountDeriver.sol";

import {
    _revertInsufficientNativeTokensSupplied,
    _revertInvalidNativeOfferItem
} from "seaport-types/src/lib/ConsiderationErrors.sol";

import {
    AccumulatorDisarmed,
    ConsiderationItem_recipient_offset,
    ReceivedItem_amount_offset,
    ReceivedItem_recipient_offset
} from "seaport-types/src/lib/ConsiderationConstants.sol";

/**
 * @title OrderFulfiller
 * @author 0age
 * @notice OrderFulfiller contains logic related to order fulfillment where a
 *         single order is being fulfilled and where basic order fulfillment is
 *         not available as an option.
 */
contract OrderFulfiller is BasicOrderFulfiller, CriteriaResolution, AmountDeriver {
    /**
     * @dev Derive and set hashes, reference chainId, and associated domain
     *      separator during deployment.
     *
     * @param conduitController A contract that deploys conduits, or proxies
     *                          that may optionally be used to transfer approved
     *                          ERC20/721/1155 tokens.
     */
    constructor(address conduitController) BasicOrderFulfiller(conduitController) {}
}
