module gateway::gateway {
    use std::signer;
    use std::vector;
    use std::string::{Self, String};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;

    // Constants
    const MAX_BPS: u64 = 100_000;
    const E_ZERO_ADDRESS: u64 = 1;
    const E_TOKEN_NOT_SUPPORTED: u64 = 2;
    const E_AMOUNT_ZERO: u64 = 3;
    const E_INVALID_STATUS: u64 = 4;
    const E_ALREADY_INITIALIZED: u64 = 5;
    const E_NOT_OWNER: u64 = 6;
    const E_NOT_AGGREGATOR: u64 = 7;
    const E_ORDER_FULFILLED: u64 = 8;
    const E_ORDER_REFUNDED: u64 = 9;
    const E_FEE_EXCEEDS_PROTOCOL: u64 = 10;
    const E_PAUSED: u64 = 11;
    const E_NOT_PAUSED: u64 = 12;
    const E_INVALID_MESSAGE_HASH: u64 = 13;

    // Resource to manage global settings and orders
    struct GatewaySettings has key {
        owner: address,
        pending_owner: address,
        aggregator_address: address,
        treasury_address: address,
        protocol_fee_percent: u64,
        paused: bool,
        supported_tokens: vector<address>,
        order_store: vector<Order>,
        order_created_events: EventHandle<OrderCreatedEvent>,
        order_settled_events: EventHandle<OrderSettledEvent>,
        order_refunded_events: EventHandle<OrderRefundedEvent>,
        sender_fee_transferred_events: EventHandle<SenderFeeTransferredEvent>,
        protocol_fee_updated_events: EventHandle<ProtocolFeeUpdatedEvent>,
        protocol_address_updated_events: EventHandle<ProtocolAddressUpdatedEvent>,
    }

    // Order structure
    struct Order has store, drop {
        sender: address,
        token: address,
        sender_fee_recipient: address,
        sender_fee: u64,
        protocol_fee: u64,
        is_fulfilled: bool,
        is_refunded: bool,
        refund_address: address,
        current_bps: u64,
        amount: u64,
        order_id: vector<u8>, // bytes32 equivalent
        nonce: u64,
    }

    // Event structures
    struct OrderCreatedEvent has drop, store {
        sender: address,
        token: address,
        amount: u64,
        protocol_fee: u64,
        order_id: vector<u8>,
        rate: u64,
        message_hash: String,
    }

    struct OrderSettledEvent has drop, store {
        split_order_id: vector<u8>,
        order_id: vector<u8>,
        liquidity_provider: address,
        settle_percent: u64,
    }

    struct OrderRefundedEvent has drop, store {
        fee: u64,
        order_id: vector<u8>,
    }

    struct SenderFeeTransferredEvent has drop, store {
        sender: address,
        amount: u64,
    }

    struct ProtocolFeeUpdatedEvent has drop, store {
        protocol_fee: u64,
    }

    struct ProtocolAddressUpdatedEvent has drop, store {
        what: String,
        treasury_address: address,
    }

    // Initialize the contract
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
            order_created_events: account::new_event_handle<OrderCreatedEvent>(account),
            order_settled_events: account::new_event_handle<OrderSettledEvent>(account),
            order_refunded_events: account::new_event_handle<OrderRefundedEvent>(account),
            sender_fee_transferred_events: account::new_event_handle<SenderFeeTransferredEvent>(account),
            protocol_fee_updated_events: account::new_event_handle<ProtocolFeeUpdatedEvent>(account),
            protocol_address_updated_events: account::new_event_handle<ProtocolAddressUpdatedEvent>(account),
        };
        move_to(account, settings);
    }

    // Inline helper functions
    inline fun assert_not_zero_address(addr: address) {
        assert!(addr != @0x0, E_ZERO_ADDRESS);
    }

    inline fun assert_token_supported(settings: &GatewaySettings, token: address) {
        assert!(vector::contains(&settings.supported_tokens, &token), E_TOKEN_NOT_SUPPORTED);
    }

    inline fun assert_amount_not_zero(amount: u64) {
        assert!(amount != 0, E_AMOUNT_ZERO);
    }

    inline fun assert_valid_status(status: u64) {
        assert!(status == 1 || status == 2, E_INVALID_STATUS);
    }

    inline fun assert_not_already_initialized(addr: address) {
        assert!(!exists<GatewaySettings>(addr), E_ALREADY_INITIALIZED);
    }

    inline fun assert_is_owner(settings: &GatewaySettings, sender: address) {
        assert!(settings.owner == sender, E_NOT_OWNER);
    }

    inline fun assert_is_aggregator(settings: &GatewaySettings, sender: address) {
        assert!(settings.aggregator_address == sender, E_NOT_AGGREGATOR);
    }

    inline fun assert_order_not_fulfilled(order: &Order) {
        assert!(!order.is_fulfilled, E_ORDER_FULFILLED);
    }

    inline fun assert_order_not_refunded(order: &Order) {
        assert!(!order.is_refunded, E_ORDER_REFUNDED);
    }

    inline fun assert_fee_not_exceeds_protocol(order: &Order, fee: u64) {
        assert!(order.protocol_fee >= fee, E_FEE_EXCEEDS_PROTOCOL);
    }

    inline fun assert_not_paused(settings: &GatewaySettings) {
        assert!(!settings.paused, E_PAUSED);
    }

    inline fun assert_paused(settings: &GatewaySettings) {
        assert!(settings.paused, E_NOT_PAUSED);
    }

    inline fun assert_valid_message_hash(message_hash: &String) {
        assert!(string::length(message_hash) > 0, E_INVALID_MESSAGE_HASH);
    }

    // Owner functions
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
                if (found) vector::remove(&mut settings.supported_tokens, idx);
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

    public entry fun update_protocol_fee(account: &signer, protocol_fee_percent: u64) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_owner(settings, signer::address_of(account));
        settings.protocol_fee_percent = protocol_fee_percent;
        event::emit_event(&mut settings.protocol_fee_updated_events, ProtocolFeeUpdatedEvent {
            protocol_fee: protocol_fee_percent,
        });
    }

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

    public entry fun pause(account: &signer) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_owner(settings, signer::address_of(account));
        assert_not_paused(settings);
        settings.paused = true;
    }

    public entry fun unpause(account: &signer) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_owner(settings, signer::address_of(account));
        assert_paused(settings);
        settings.paused = false;
    }

    // User calls
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
        let nonce = account::create_signer_with_capability(&account::create_test_signer_cap(sender_addr)).nonce();
        let order_id = hash::sha3_256(copy vector::append(sender_addr, nonce));
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
            nonce,
        };
        vector::push_back(&mut settings.order_store, order);

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

    // Aggregator functions
    public entry fun settle<T>(
        account: &signer,
        split_order_id: vector<u8>,
        order_id: vector<u8>,
        liquidity_provider: address,
        settle_percent: u64
    ) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_aggregator(settings, signer::address_of(account));
        let (found, idx) = vector::index_of(&settings.order_store, &Order { order_id, .. });
        assert!(found, E_ORDER_NOT_FOUND);
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

    public entry fun refund<T>(
        account: &signer,
        fee: u64,
        order_id: vector<u8>
    ) acquires GatewaySettings {
        let settings = borrow_global_mut<GatewaySettings>(signer::address_of(account));
        assert_is_aggregator(settings, signer::address_of(account));
        let (found, idx) = vector::index_of(&settings.order_store, &Order { order_id, .. });
        assert!(found, E_ORDER_NOT_FOUND);
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

    // View functions
    public fun is_token_supported(token: address): bool acquires GatewaySettings {
        let settings = borrow_global<GatewaySettings>(@gateway);
        vector::contains(&settings.supported_tokens, &token)
    }

    public fun get_order_info(order_id: vector<u8>): Order acquires GatewaySettings {
        let settings = borrow_global<GatewaySettings>(@gateway);
        let (found, idx) = vector::index_of(&settings.order_store, &Order { order_id, .. });
        assert!(found, E_ORDER_NOT_FOUND);
        *vector::borrow(&settings.order_store, idx)
    }

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
