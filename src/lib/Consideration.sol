// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ConsiderationInterface} from "seaport-types/src/interfaces/ConsiderationInterface.sol";

import {
    AdvancedOrder,
    BasicOrderParameters,
    CriteriaResolver,
    Execution,
    Fulfillment,
    FulfillmentComponent,
    Order,
    OrderComponents,
    ReceivedItem,
    OrderProbility
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {OrderCombiner} from "./OrderCombiner.sol";

import {CalldataStart, CalldataPointer} from "seaport-types/src/helpers/PointerLibraries.sol";
import "hardhat/console.sol";

import {
    Offset_fulfillAdvancedOrder_criteriaResolvers,
    Offset_fulfillAvailableAdvancedOrders_cnsdrationFlflmnts,
    Offset_fulfillAvailableAdvancedOrders_criteriaResolvers,
    Offset_fulfillAvailableAdvancedOrders_offerFulfillments,
    Offset_fulfillAvailableOrders_considerationFulfillments,
    Offset_fulfillAvailableOrders_offerFulfillments,
    Offset_matchAdvancedOrders_criteriaResolvers,
    Offset_matchAdvancedOrders_fulfillments,
    Offset_matchOrders_fulfillments,
    OrderParameters_counter_offset
} from "seaport-types/src/lib/ConsiderationConstants.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IVRFInterface {
  function requestRandomWords(uint32) external returns (uint256 requestId);
}

/**
 * @title Consideration
 * @author 0age (0age.eth)
 * @custom:coauthor d1ll0n (d1ll0n.eth)
 * @custom:coauthor transmissions11 (t11s.eth)
 * @custom:coauthor James Wenzel (emo.eth)
 * @custom:version 1.5
 * @notice Consideration is a generalized native token/ERC20/ERC721/ERC1155
 *         marketplace that provides lightweight methods for common routes as
 *         well as more flexible methods for composing advanced orders or groups
 *         of orders. Each order contains an arbitrary number of items that may
 *         be spent (the "offer") along with an arbitrary number of items that
 *         must be received back by the indicated recipients (the
 *         "consideration").
 */
contract Consideration is ConsiderationInterface, OrderCombiner, Ownable {
    address private _vrf_controller;
    mapping(uint256 => bytes32[]) private originalOrderHashes;
    mapping(address => bool) private members;
    /**
     * @notice Derive and set hashes, reference chainId, and associated domain
     *         separator during deployment.
     *
     * @param conduitController A contract that deploys conduits, or proxies
     *                          that may optionally be used to transfer approved
     *                          ERC20/721/1155 tokens.
     */
    constructor(address conduitController) OrderCombiner(conduitController) {
        _vrf_controller = address(0xC619D985a88e341B618C23a543B8Efe2c55D1b37);
    }

    event MatchSuccessOrNot(uint256 requestId, bool isSuccess);

    /**
     * @notice Accept native token transfers during execution that may then be
     *         used to facilitate native token transfers, where any tokens that
     *         remain will be transferred to the caller. Native tokens are only
     *         acceptable mid-fulfillment (and not during basic fulfillment).
     */
    receive() external payable {
        // Ensure the reentrancy guard is currently set to accept native tokens.
        _assertAcceptingNativeTokens();
    }

    /**
     * @notice Match an arbitrary number of orders, each with an arbitrary
     *         number of items for offer and consideration along with a set of
     *         fulfillments allocating offer components to consideration
     *         components. Note that this function does not support
     *         criteria-based or partial filling of orders (though filling the
     *         remainder of a partially-filled order is supported). Any unspent
     *         offer item amounts or native tokens will be transferred to the
     *         caller.
     *
     * @custom:param orders       The orders to match. Note that both the
     *                            offerer and fulfiller on each order must first
     *                            approve this contract (or their conduit if
     *                            indicated by the order) to transfer any
     *                            relevant tokens on their behalf and each
     *                            consideration recipient must implement
     *                            `onERC1155Received` to receive ERC1155 tokens.
     * @custom:param fulfillments An array of elements allocating offer
     *                            components to consideration components. Note
     *                            that each consideration component must be
     *                            fully met for the match operation to be valid,
     *                            and that any unspent offer items will be sent
     *                            unaggregated to the caller.
     *
     * @return executions An array of elements indicating the sequence of
     *                    transfers performed as part of matching the given
     *                    orders. Note that unspent offer item amounts or native
     *                    tokens will not be reflected as part of this array.
     */
    function matchOrdersWithRandom(
        /**
         * @custom:name orders
         */
        Order[] calldata,
        /**
         * @custom:name fulfillments
         */
        Fulfillment[] calldata,
        uint256 requestId,
        OrderProbility[] calldata orderProbility
    ) onlyMembers external payable override returns (Execution[] memory /* executions */ ) {
        bytes32[] memory existingOrderHahes = originalOrderHashes[requestId];
        (Execution[] memory executions, bool returnBack) = _matchAdvancedOrdersWithRandom(
            _toAdvancedOrdersReturnType(_decodeOrdersAsAdvancedOrders)(CalldataStart.pptr()),
            _toFulfillmentsReturnType(_decodeFulfillments)(CalldataStart.pptr(Offset_matchOrders_fulfillments)),
            existingOrderHahes,
            orderProbility
        );
        // change this if need partial fulfillment
        if(returnBack) {
            uint256 totalLength = existingOrderHahes.length;
            for(uint256 i = 0; i < totalLength; ++i) {
                _restoreOriginalStatus(existingOrderHahes[i]);
            }
        }
        delete originalOrderHashes[requestId];
        emit MatchSuccessOrNot(requestId, !returnBack);
        return executions;
    }

    function prepare(
        /**
         * @custom:name orders
         */
        Order[] calldata orders,
        uint256[] calldata premiumOrdersIndex,
        address[] calldata recipients,
        uint32 numWords
    ) onlyMembers external payable override returns (uint256)  {
        (
            Execution[] memory executions,
            bytes32[] memory orderHashes
        ) = prepareOrdersWithRandom(
            _toAdvancedOrdersReturnType(_decodeOrdersAsAdvancedOrders)(CalldataStart.pptr()),
            premiumOrdersIndex,
            recipients
        );
        uint256 requestId = IVRFInterface(_vrf_controller).requestRandomWords(numWords);
        // clear reetrancy guard
        _clearReentrancyGuard();
        originalOrderHashes[requestId] = orderHashes;
        return requestId;
    }

    /**
     * @notice Cancel an arbitrary number of orders. Note that only the offerer
     *         or the zone of a given order may cancel it. Callers should ensure
     *         that the intended order was cancelled by calling `getOrderStatus`
     *         and confirming that `isCancelled` returns `true`.
     *
     * @param orders The orders to cancel.
     *
     * @return cancelled A boolean indicating whether the supplied orders have
     *                   been successfully cancelled.
     */
    function cancel(OrderComponents[] calldata orders) external override returns (bool cancelled) {
        // Cancel the orders.
        cancelled = _cancel(orders);
    }

    /**
     * @notice Validate an arbitrary number of orders, thereby registering their
     *         signatures as valid and allowing the fulfiller to skip signature
     *         verification on fulfillment. Note that validated orders may still
     *         be unfulfillable due to invalid item amounts or other factors;
     *         callers should determine whether validated orders are fulfillable
     *         by simulating the fulfillment call prior to execution. Also note
     *         that anyone can validate a signed order, but only the offerer can
     *         validate an order without supplying a signature.
     *
     * @custom:param orders The orders to validate.
     *
     * @return validated A boolean indicating whether the supplied orders have
     *                   been successfully validated.
     */
    function validate(
        /**
         * @custom:name orders
         */
        Order[] calldata
    ) external override returns (bool /* validated */ ) {
        return _validate(_toOrdersReturnType(_decodeOrders)(CalldataStart.pptr()));
    }

    /**
     * @notice Cancel all orders from a given offerer with a given zone in bulk
     *         by incrementing a counter. Note that only the offerer may
     *         increment the counter.
     *
     * @return newCounter The new counter.
     */
    function incrementCounter() external override returns (uint256 newCounter) {
        // Increment current counter for the supplied offerer.  Note that the
        // counter is incremented by a large, quasi-random interval.
        newCounter = _incrementCounter();
    }

    /**
     * @notice Retrieve the order hash for a given order.
     *
     * @custom:param order The components of the order.
     *
     * @return orderHash The order hash.
     */
    function getOrderHash(
        /**
         * @custom:name order
         */
        OrderComponents calldata
    ) external view override returns (bytes32 orderHash) {
        CalldataPointer orderPointer = CalldataStart.pptr();

        // Derive order hash by supplying order parameters along with counter.
        orderHash = _deriveOrderHash(
            _toOrderParametersReturnType(_decodeOrderComponentsAsOrderParameters)(orderPointer),
            // Read order counter
            orderPointer.offset(OrderParameters_counter_offset).readUint256()
        );
    }

    /**
     * @notice Retrieve the status of a given order by hash, including whether
     *         the order has been cancelled or validated and the fraction of the
     *         order that has been filled. Since the _orderStatus[orderHash]
     *         does not get set for contract orders, getOrderStatus will always
     *         return (false, false, 0, 0) for those hashes. Note that this
     *         function is susceptible to view reentrancy and so should be used
     *         with care when calling from other contracts.
     *
     * @param orderHash The order hash in question.
     *
     * @return isValidated A boolean indicating whether the order in question
     *                     has been validated (i.e. previously approved or
     *                     partially filled).
     * @return isCancelled A boolean indicating whether the order in question
     *                     has been cancelled.
     * @return totalFilled The total portion of the order that has been filled
     *                     (i.e. the "numerator").
     * @return totalSize   The total size of the order that is either filled or
     *                     unfilled (i.e. the "denominator").
     */
    function getOrderStatus(bytes32 orderHash)
        external
        view
        override
        returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize)
    {
        // Retrieve the order status using the order hash.
        return _getOrderStatus(orderHash);
    }

    /**
     * @notice Retrieve the current counter for a given offerer.
     *
     * @param offerer The offerer in question.
     *
     * @return counter The current counter.
     */
    function getCounter(address offerer) external view override returns (uint256 counter) {
        // Return the counter for the supplied offerer.
        counter = _getCounter(offerer);
    }

    /**
     * @notice Retrieve configuration information for this contract.
     *
     * @return version           The contract version.
     * @return domainSeparator   The domain separator for this contract.
     * @return conduitController The conduit Controller set for this contract.
     */
    function information()
        external
        view
        override
        returns (string memory version, bytes32 domainSeparator, address conduitController)
    {
        // Return the information for this contract.
        return _information();
    }

    /**
     * @dev Gets the contract offerer nonce for the specified contract offerer.
     *      Note that this function is susceptible to view reentrancy and so
     *      should be used with care when calling from other contracts.
     *
     * @param contractOfferer The contract offerer for which to get the nonce.
     *
     * @return nonce The contract offerer nonce.
     */
    function getContractOffererNonce(address contractOfferer) external view override returns (uint256 nonce) {
        nonce = _contractNonces[contractOfferer];
    }

    /**
     * @notice Retrieve the name of this contract.
     *
     * @return contractName The name of this contract.
     */
    function name() external pure override returns (string memory /* contractName */ ) {
        // Return the name of the contract.
        return _name();
    }

    modifier onlyMembers() {
        require(members[msg.sender], "Only members can call the match with lucky");
        _;
    }

    function vrfOwner() public view returns (address) {
        return _vrf_controller;
    }

    function updateVRFAddress(address vrfController) public onlyOwner {
        _vrf_controller = vrfController;
    }

    function addMember(address addr) public onlyOwner {
        members[addr] = true;
    }

    function removeMember(address addr) public onlyOwner {
        delete members[addr];
    }

    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data) external returns (bytes4) {
        return this.onERC1155Received.selector;
    }
}
