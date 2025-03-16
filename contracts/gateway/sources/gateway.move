module gateway::gateway {
    use std::signer;
    use std::vector;
    use std::simple_map::{Self, SimpleMap};
    use std::string::{Self, String};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use aptos_framework::coin::{Self, Coin};
    use std::hash;
    use aptos_framework::bcs;
    use aptos_framework::timestamp;

    // Constants
    const MAX_BPS: u64 = 100000; // Maximum basis points (100%) for fee calculations
    const E_ZERO_ADDRESS: u64 = 1; // Error code for zero address validation
    const E_TOKEN_NOT_SUPPORTED: u64 = 2; // Error code for unsupported token
    const E_AMOUNT_ZERO: u64 = 3; // Error code for zero amount validation
    const E_INVALID_STATUS: u64 = 4; // Error code for invalid status value
    const E_ALREADY_INITIALIZED: u64 = 5; // Error code for contract already initialized
    const E_NOT_OWNER: u64 = 6; // Error code for non-owner access
    const E_NOT_AGGREGATOR: u64 = 7; // Error code for non-aggregator access
    const E_ORDER_FULFILLED: u64 = 8; // Error code for already fulfilled order
    const E_ORDER_REFUNDED: u64 = 9; // Error code for already refunded order
    const E_FEE_EXCEEDS_PROTOCOL: u64 = 10; // Error code for fee exceeding protocol fee
    const E_PAUSED: u64 = 11; // Error code for paused contract
    const E_NOT_PAUSED: u64 = 12; // Error code for not paused contract
    const E_INVALID_MESSAGE_HASH: u64 = 13; // Error code for invalid message hash
    const E_ORDER_NOT_FOUND: u64 = 14; // order not found error

    // Resource to manage global settings and orders
    struct GatewaySettings has key {
        owner: address, // Address of the contract owner
        pending_owner: address, // Address of the pending owner for ownership transfer
        aggregator_address: address, // Address of the aggregator allowed to settle/refund orders
        treasury_address: address, // Address where protocol fees are sent
        protocol_fee_percent: u64, // Percentage of the order amount taken as protocol fee (in basis points)
        paused: bool, // Indicates if the contract is paused
        supported_tokens: vector<address>, // List of supported token addresses
        order_store: vector<Order>, // List of all orders created
        order_store_map: SimpleMap<vector<u8>, u64>,
        order_created_events: EventHandle<OrderCreatedEvent>, // Event handle for order creation
        order_settled_events: EventHandle<OrderSettledEvent>, // Event handle for order settlement
        order_refunded_events: EventHandle<OrderRefundedEvent>, // Event handle for order refunds
        sender_fee_transferred_events: EventHandle<SenderFeeTransferredEvent>, // Event handle for sender fee transfers
        protocol_fee_updated_events: EventHandle<ProtocolFeeUpdatedEvent>, // Event handle for protocol fee updates
        protocol_address_updated_events: EventHandle<ProtocolAddressUpdatedEvent>, // Event handle for address updates
    }

    // Order structure to store individual order details
    struct Order has store, drop, copy {
        sender: address, // Address of the order creator
        token: address, // Address of the token being traded
        sender_fee_recipient: address, // Address receiving the sender fee
        sender_fee: u64, // Amount of sender fee in token units
        protocol_fee: u64, // Amount of protocol fee in token units
        is_fulfilled: bool, // Whether the order is fully settled
        is_refunded: bool, // Whether the order has been refunded
        refund_address: address, // Address to receive refunds if order is cancelled
        current_bps: u64, // Remaining basis points of the order (starts at MAX_BPS)
        amount: u64, // Remaining amount of the order after fees
        order_id: vector<u8>, // Unique identifier for the order (bytes32 equivalent)
        nonce: u64, // Nonce to prevent replay attacks
    }

    // Event structures for logging contract activities
    struct OrderCreatedEvent has drop, store {
        sender: address, // Address of the order creator
        token: address, // Address of the token
        amount: u64, // Amount of the order after protocol fee
        protocol_fee: u64, // Protocol fee deducted from the order
        order_id: vector<u8>, // Unique order ID
        rate: u64, // Rate at which the sender intends to sell the token
        message_hash: String, // Hash of the message associated with the order
    }

    struct OrderSettledEvent has drop, store {
        split_order_id: vector<u8>, // ID of the split order (for partial settlements)
        order_id: vector<u8>, // ID of the original order
        liquidity_provider: address, // Address of the liquidity provider settling the order
        settle_percent: u64, // Percentage of the order settled (in basis points)
    }

    struct OrderRefundedEvent has drop, store {
        fee: u64, // Fee deducted from the refund amount
        order_id: vector<u8>, // ID of the refunded order
    }

    struct SenderFeeTransferredEvent has drop, store {
        sender: address, // Address receiving the sender fee
        amount: u64, // Amount of the sender fee transferred
    }

    struct ProtocolFeeUpdatedEvent has drop, store {
        protocol_fee: u64, // New protocol fee percentage
    }

    struct ProtocolAddressUpdatedEvent has drop, store {
        what: String, // Type of address updated ("treasury" or "aggregator")
        treasury_address: address, // New address value
    }

    // Initializes the Gateway contract
    // Arguments:
    // - account: &signer - The signer deploying the contract
    public entry fun initialize(account: &signer) {
        let sender_addr = signer::address_of(account);
        assert_not_already_initialized(sender_addr);
        let settings = GatewaySettings {
            owner: sender_addr,
            pending_owner: @0x0,
            aggregator_address: @0x0,
            treasury_address: @0x0,
            protocol_fee_percent: 0,
            paused: false,
            supported_tokens: vector::empty(),
            order_store: vector::empty(),
            order_store_map: simple_map::new(),
            order_created_events: account::new_event_handle<OrderCreatedEvent>(account),
            order_settled_events: account::new_event_handle<OrderSettledEvent>(account),
            order_refunded_events: account::new_event_handle<OrderRefundedEvent>(account),
            sender_fee_transferred_events: account::new_event_handle<SenderFeeTransferredEvent>(account),
            protocol_fee_updated_events: account::new_event_handle<ProtocolFeeUpdatedEvent>(account),
            protocol_address_updated_events: account::new_event_handle<ProtocolAddressUpdatedEvent>(account),
        };
        move_to(account, settings);
    }

    // Inline helper functions for assertions
    inline fun assert_not_zero_address(addr: address) {
        // Ensures the provided address is not the zero address
        assert!(addr != @0x0, E_ZERO_ADDRESS);
    }

    inline fun assert_token_supported(settings: &GatewaySettings, token: address) {
        // Ensures the token is in the supported tokens list
        assert!(vector::contains(&settings.supported_tokens, &token), E_TOKEN_NOT_SUPPORTED);
    }

    inline fun assert_amount_not_zero(amount: u64) {
        // Ensures the amount is greater than zero
        assert!(amount != 0, E_AMOUNT_ZERO);
    }

    inline fun assert_valid_status(status: u64) {
        // Ensures the status is either 1 (enable) or 2 (disable)
        assert!(status == 1 || status == 2, E_INVALID_STATUS);
    }

    inline fun assert_not_already_initialized(addr: address) {
        // Ensures the contract has not been initialized at the given address
        assert!(!exists<GatewaySettings>(addr), E_ALREADY_INITIALIZED);
    }

    inline fun assert_is_owner(settings: &GatewaySettings, sender: address) {
        // Ensures the sender is the contract owner
        assert!(settings.owner == sender, E_NOT_OWNER);
    }

    inline fun assert_is_aggregator(settings: &GatewaySettings, sender: address) {
        // Ensures the sender is the aggregator
        assert!(settings.aggregator_address == sender, E_NOT_AGGREGATOR);
    }

    inline fun assert_order_not_fulfilled(order: &Order) {
        // Ensures the order has not been fulfilled
        assert!(!order.is_fulfilled, E_ORDER_FULFILLED);
    }

    inline fun assert_order_not_refunded(order: &Order) {
        // Ensures the order has not been refunded
        assert!(!order.is_refunded, E_ORDER_REFUNDED);
    }

    inline fun assert_fee_not_exceeds_protocol(order: &Order, fee: u64) {
        // Ensures the refund fee does not exceed the protocol fee
        assert!(order.protocol_fee >= fee, E_FEE_EXCEEDS_PROTOCOL);
    }

    inline fun assert_not_paused(settings: &GatewaySettings) {
        // Ensures the contract is not paused
        assert!(!settings.paused, E_PAUSED);
    }

    inline fun assert_paused(settings: &GatewaySettings) {
        // Ensures the contract is paused
        assert!(settings.paused, E_NOT_PAUSED);
    }

    inline fun assert_valid_message_hash(message_hash: &String) {
        // Ensures the message hash is not empty
        assert!(string::length(message_hash) > 0, E_INVALID_MESSAGE_HASH);
    }

    // Adds or removes a token from the supported list (owner only)
    // Arguments:
    // - account: &signer - The signer (must be owner)
    // - what: String - The type of setting ("token" for token support)
    // - value: address - The token address to add/remove
    // - status: u64 - 1 to add, 2 to remove
    public entry fun setting_manager_bool(
        account: &signer,
        what: String,
        value: address,
        status: u64
    ) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_owner(settings, signer::address_of(account));
        assert_not_zero_address(value);
        assert_valid_status(status);

        if (what == string::utf8(b"token")) {
            if (status == 1 && !vector::contains(&settings.supported_tokens, &value)) {
                vector::push_back(&mut settings.supported_tokens, value);
            } else if (status == 2) {
                let (found, idx) = vector::index_of(&settings.supported_tokens, &value);
                if (found) {
                    vector::remove(&mut settings.supported_tokens, idx);
                };
            };
            event::emit_event(&mut settings.order_created_events, OrderCreatedEvent {
                sender: signer::address_of(account),
                token: value,
                amount: 0,
                protocol_fee: 0,
                order_id: vector::empty(),
                rate: 0,
                message_hash: string::utf8(b""),
            });
        }
    }

    // Updates the protocol fee percentage (owner only)
    // Arguments:
    // - account: &signer - The signer (must be owner)
    // - protocol_fee_percent: u64 - New protocol fee percentage in basis points
    public entry fun update_protocol_fee(account: &signer, protocol_fee_percent: u64) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_owner(settings, signer::address_of(account));
        settings.protocol_fee_percent = protocol_fee_percent;
        event::emit_event(&mut settings.protocol_fee_updated_events, ProtocolFeeUpdatedEvent {
            protocol_fee: protocol_fee_percent,
        });
    }

    // Updates the treasury or aggregator address (owner only)
    // Arguments:
    // - account: &signer - The signer (must be owner)
    // - what: String - "treasury" or "aggregator" to specify which address to update
    // - value: address - New address to set
    public entry fun update_protocol_address(account: &signer, what: String, value: address) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_owner(settings, signer::address_of(account));
        assert_not_zero_address(value);

        if (what == string::utf8(b"treasury")) {
            settings.treasury_address = value;
        } else if (what == string::utf8(b"aggregator")) {
            settings.aggregator_address = value;
        };
        event::emit_event(&mut settings.protocol_address_updated_events, ProtocolAddressUpdatedEvent {
            what,
            treasury_address: value,
        });
    }

    // Pauses the contract (owner only)
    // Arguments:
    // - account: &signer - The signer (must be owner)
    public entry fun pause(account: &signer) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_owner(settings, signer::address_of(account));
        assert_not_paused(settings);
        settings.paused = true;
    }

    // Unpauses the contract (owner only)
    // Arguments:
    // - account: &signer - The signer (must be owner)
    public entry fun unpause(account: &signer) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_owner(settings, signer::address_of(account));
        assert_paused(settings);
        settings.paused = false;
    }

    // Creates a new order to lock tokens in escrow
    // Arguments:
    // - account: &signer - The signer creating the order
    // - token: address - Address of the token to lock
    // - amount: u64 - Amount of tokens to lock
    // - rate: u64 - Intended selling rate for the tokens
    // - sender_fee_recipient: address - Address to receive the sender fee
    // - sender_fee: u64 - Amount of sender fee in token units
    // - refund_address: address - Address to receive refunds if order is cancelled
    // - message_hash: String - Hash of the message associated with the order
    public entry fun create_order<T>(
        account: &signer,
        token: address,
        amount: u64,
        rate: u64,
        sender_fee_recipient: address,
        sender_fee: u64,
        refund_address: address,
        message_hash: String
    ) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_not_paused(settings);
        assert_token_supported(settings, token);
        assert_amount_not_zero(amount);
        assert_not_zero_address(refund_address);
        if (sender_fee != 0) assert_not_zero_address(sender_fee_recipient);
        assert_valid_message_hash(&message_hash);

        let sender_addr = signer::address_of(account);
        // Convert address to vector<u8> using serialization
        let addr_bytes = bcs::to_bytes(&sender_addr);
        // Include nonce for uniqueness and replay protection
        let timestamp = timestamp::now_microseconds();
        let nonce_bytes = bcs::to_bytes(&timestamp);
        // Combine address and nonce bytes
        vector::append(&mut addr_bytes, nonce_bytes);
        // Generate order_id by hashing the combined bytes
        let order_id = hash::sha3_256(addr_bytes);
        let protocol_fee = (amount * settings.protocol_fee_percent) / (MAX_BPS + settings.protocol_fee_percent);
        let order_amount = amount - protocol_fee;

        let order = Order {
            sender: sender_addr,
            token,
            sender_fee_recipient,
            sender_fee,
            protocol_fee,
            is_fulfilled: false,
            is_refunded: false,
            refund_address,
            current_bps: MAX_BPS,
            amount: order_amount,
            order_id,
            nonce : timestamp,
        };
        vector::push_back(&mut settings.order_store, order);
        let (found, i) = vector::index_of(&settings.order_store, &order);
        assert!(found, E_ORDER_NOT_FOUND);
        simple_map::add(&mut settings.order_store_map, order_id, i);

        let coins = coin::withdraw<T>(account, amount + sender_fee);
        coin::deposit(sender_addr, coins); // Escrow logic placeholder

        event::emit_event(&mut settings.order_created_events, OrderCreatedEvent {
            sender: sender_addr,
            token,
            amount: order_amount,
            protocol_fee,
            order_id,
            rate,
            message_hash,
        });
    }

    // Settles an order partially or fully (aggregator only)
    // Arguments:
    // - account: &signer - The signer (must be aggregator)
    // - split_order_id: vector<u8> - ID of the split order for partial settlement
    // - order_id: vector<u8> - ID of the order to settle
    // - liquidity_provider: address - Address receiving the settled amount
    // - settle_percent: u64 - Percentage of the order to settle (in basis points)
    public entry fun settle<T>(
        account: &signer,
        split_order_id: vector<u8>,
        order_id: vector<u8>,
        liquidity_provider: address,
        settle_percent: u64
    ) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_aggregator(settings, signer::address_of(account));
        let idx = *simple_map::borrow(&settings.order_store_map, &order_id);
        let order = vector::borrow_mut(&mut settings.order_store, idx);
        assert_order_not_fulfilled(order);
        assert_order_not_refunded(order);

        order.current_bps = order.current_bps - settle_percent;
        let liquidity_provider_amount = (order.amount * settle_percent) / MAX_BPS;
        order.amount = order.amount - liquidity_provider_amount;

        if (order.current_bps == 0) {
            order.is_fulfilled = true;
            if (order.sender_fee != 0) {
                coin::transfer<T>(account, order.sender_fee_recipient, order.sender_fee);
                event::emit_event(&mut settings.sender_fee_transferred_events, SenderFeeTransferredEvent {
                    sender: order.sender_fee_recipient,
                    amount: order.sender_fee,
                });
            };
            if (order.protocol_fee != 0) {
                coin::transfer<T>(account, settings.treasury_address, order.protocol_fee);
            };
        };
        coin::transfer<T>(account, liquidity_provider, liquidity_provider_amount);

        event::emit_event(&mut settings.order_settled_events, OrderSettledEvent {
            split_order_id,
            order_id,
            liquidity_provider,
            settle_percent,
        });
    }

    // Refunds an order (aggregator only)
    // Arguments:
    // - account: &signer - The signer (must be aggregator)
    // - fee: u64 - Fee deducted from the refund amount
    // - order_id: vector<u8> - ID of the order to refund
    public entry fun refund<T>(
        account: &signer,
        fee: u64,
        order_id: vector<u8>
    ) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_aggregator(settings, signer::address_of(account));
        let idx = *simple_map::borrow(&settings.order_store_map, &order_id);
        let order = vector::borrow_mut(&mut settings.order_store, idx);
        assert_order_not_fulfilled(order);
        assert_order_not_refunded(order);
        assert_fee_not_exceeds_protocol(order, fee);

        coin::transfer<T>(account, settings.treasury_address, fee);
        order.is_refunded = true;
        order.current_bps = 0;
        let refund_amount = order.amount + order.protocol_fee - fee;
        coin::transfer<T>(account, order.refund_address, refund_amount + order.sender_fee);

        event::emit_event(&mut settings.order_refunded_events, OrderRefundedEvent {
            fee,
            order_id,
        });
    }

    // Checks if a token is supported
    // Arguments:
    // - token: address - Address of the token to check
    // Returns: bool - True if the token is supported, false otherwise
    public fun is_token_supported(token: address): bool acquires GatewaySettings {
        let settings = borrow_global<GatewaySettings>(@gateway);
        vector::contains(&settings.supported_tokens, &token)
    }

    // Retrieves order details
    // Arguments:
    // - order_id: vector<u8> - ID of the order to retrieve
    // Returns: Order - The order details
    public fun get_order_info(order_id: vector<u8>): Order acquires GatewaySettings {
        let settings = borrow_global<GatewaySettings>(@gateway);
        let idx = *simple_map::borrow(&settings.order_store_map, &order_id); // Get index from map
        *vector::borrow(&settings.order_store, idx)
    }

    // Retrieves fee details
    // Returns: (u64, u64) - Tuple of (protocol_fee_percent, MAX_BPS)
    public fun get_fee_details(): (u64, u64) acquires GatewaySettings {
        let settings = borrow_global<GatewaySettings>(@gateway);
        (settings.protocol_fee_percent, MAX_BPS)
    }

    // Test functions (headers only)
    #[test(account = @0x1)]
    public entry fun test_initialize(account: &signer) acquires GatewaySettings {}

    #[test(account = @0x1)]
    public entry fun test_create_order_success(account: &signer) acquires GatewaySettings {}

    #[test(account = @0x1)]
    public entry fun test_create_order_zero_amount(account: &signer) acquires GatewaySettings {}

    #[test(account = @0x1)]
    public entry fun test_settle_full_order(account: &signer) acquires GatewaySettings {}

    #[test(account = @0x1)]
    public entry fun test_settle_partial_order(account: &signer) acquires GatewaySettings {}

    #[test(account = @0x1)]
    public entry fun test_refund_order(account: &signer) acquires GatewaySettings {}

    #[test(account = @0x1)]
    public entry fun test_unauthorized_access(account: &signer) acquires GatewaySettings {}
}