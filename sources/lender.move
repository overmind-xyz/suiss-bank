/* 
    This quest features a portion of a simple lending protocol. This module provides the functionality
    for users to deposit and withdraw collateral, borrow and repay coins, and calculate their borrowing
    health factor. This lending protocol is based on the NAVI lending protocol on the Sui network. 

    Lending protocol: 
        A lending protocol is a smart contract system that allows users to lend and borrow coins. 
        Users can lend out their coins by supplying the liquidity pools, and can borrow coins from the
        liquidity pools. 

        This module is the basis for an overcollateralized lending protocol. This means that borrowers
        need to have lended more coins than they are borrowing. This is to ensure that the lenders are
        protected. 

    Depositing: 
        Lenders can deposit their coins to the liquidity pools at anytime with the deposit function.
    
    Withdrawing: 
        Lenders can withdraw the coins that they have lended out with the withdrawal function.

        In production, the withdrawal function should ensure that withdrawing their collateral does 
        not result in the user's health factor falling below a certain threshold. More on this below.

    Borrowing: 
        Borrowers can borrow coins from any available liquidity pools with the borrow function.

        In production, the borrowing function should ensure that the borrower has enough collateral 
        to cover the borrowed amount. Ensuring that the health factor of this use is above a certain 
        threshold after the borrowing is typically good practice. More on this below.

    Repaying: 
        Borrowers can repay coins they have borrowed with the repay function.

    Admin: 
        Only the admin is able to create new pools. Whoever holds the AdminCap capablity resource can
        use create_pool to create a pool for a new coin type. 

    Health factor: 
        To learn more about the health factor, please refer to Navi's documentation on health factors 
        here: https://naviprotocol.gitbook.io/navi-protocol-docs/getting-started/liquidations#what-is-the-health-factor

        Note that the health factor should be calculated with a decimal precision of 2. This means that
        a health factor of 1.34 should be represented as 134, and a health factor of 0.34 should be
        represented as 34.

        Example: 
            If a user has 1000 SUI as collateral and has borrowed 500 SUI, and the price of SUI is $1,
            the health factor of the user would be 1.6 (returned as 160). This is with a liquidation
            threshold of 80% (see below).

            if a user has 1000 SUI and 34000 USDC as collateral and has borrowed 14000 FUD, and the 
            price of SUI is $7.13, the price of USDC is $1, and the price of FUD is $2.20, the health 
            factor of the user would be 1.06 (returned as 106). This is with a liquidationthreshold 
            of 80% (see below).

    Liquidation threshold: 
        In production, each coin can have it's own liquidation threshold. These thresholds are considered
        when calculating the health factor of a user.

        In this module, the liquidation threshold is hardcoded to 80% for every coin. 

        More information on liquidation thresholds can be found in Navi's documentation here:
        https://naviprotocol.gitbook.io/navi-protocol-docs/getting-started/liquidations#liquidation-threshold

    Liquidation: 
        In production, if a user's health factor falls below the liquidation threshold, the user's 
        collateral is liquidated. This means that the user's collateral is sold off to repay the borrowed
        amount. 

        In this module, the liquidation function is not implemented as it is out of scope. However, 
        being able to calculate the health factor of user is a crucial part of the liquidation process.

    Price feed:
        This module uses a dummy oracle to get the price of each coin. In production, the price feed 
        should be a reliable source of the price of each coin. 

        The price feed is used to calculate the health factor of a user.

        The price and decimal precision of each coin can be fetched from the price feed with the 
        get_price_and_decimals function. The coin's asset number is used to fetch the price and
        decimal precision of the coin.

    Decimal precision: 
        When relating USD values of different coins, it is important to consider the decimal precision
        of each coin. This is because different coins have different decimal precisions. For this quest, 
        we assume that the decimal precision of each coin is between 0 and 9 (inclusive).

        The decimal precision of each coin is fetched from the price feed with the get_price_and_decimals
        function.
*/
module overmind::lending {
    //==============================================================================================
    // Dependencies
    //==============================================================================================
    use sui::math;
    use std::vector;
    use sui::transfer;
    use overmind::dummy_oracle;
    use sui::object::{Self, UID};
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};

    #[test_only]
    use sui::test_scenario;
    #[test_only]
    use sui::test_utils::{assert_eq, destroy};
    #[test_only]
    use sui::sui::SUI;

    //==============================================================================================
    // Constants - Add your constants here (if any)
    //==============================================================================================

    //==============================================================================================
    // Error codes - DO NOT MODIFY
    //==============================================================================================
    
    //==============================================================================================
    // Module Structs - DO NOT MODIFY
    //==============================================================================================

    /*
        This is the capability resource that is used to create new pools. The AdminCap should be created
        and transferred to the publisher of the protocol.
    */
    struct AdminCap has key, store {
        id: UID,
    }

    /*
        This is the state of the protocol. It contains the number of pools and the users of the protocol.
        This should be created and shared globally when the protocol is initialized.
    */
    struct ProtocolState has key {
        id: UID, 
        number_of_pools: u64, // The number of pools in the protocol. Default is 0.
        users: Table<address, UserData> // All user data of the protocol.
    }

    /*
        This is the pool resource. It contains the asset number of the pool, and the reserve of the pool.
        When a pool is created, it should be shared globally.
    */
    struct Pool<phantom CoinType> has key {
        id: UID, 
        /* 
            The asset number of the pool. This aligns with the index of collateral and borrow amounts in 
            the user data. This is also used to fetch the price and decimal precision of the coin from
            the price feed with the dummy_oracle::get_price_and_decimals function.
        */
        asset_number: u64, 
        /*
            The reserve of the pool. This is the total amount of the coin in the pool that are 
            available for borrowing or withdrawing.
        */
        reserve: Balance<CoinType>
    }

    /* 
        This is the user data resource. It contains the collateral and borrowed amounts of the user.
    */
    struct UserData has store {
        /* 
            The amount of collateral the user has in each pool. the index of the collateral amount
            aligns with the asset number of the pool.
        */
        collateral_amount: Table<u64, u64>, 
        /* 
            The amount of coins the user has borrowed in each pool. the index of the borrowed amount
            aligns with the asset number of the pool.
        */
        borrowed_amount: Table<u64, u64>,
    }

    //==============================================================================================
    // Functions
    //==============================================================================================

    /*
        Initializes the protocol by creating the admin capability and the protocol state.
    */
    fun init(ctx: &mut TxContext) {

    }

    /*
        Creates a new pool for a new coin type. This function can only be called by the admin.
    */
    public fun create_pool<CoinType>(
        _: &mut AdminCap,
        state: &mut ProtocolState,
        ctx: &mut TxContext
    ) {

    }

    /*
        Deposits a coin to a pool. This function increases the user's collateral amount in the pool
        and adds the coin to the pool's reserve.
    */
    public fun deposit<CoinType>(
        coin_to_deposit: Coin<CoinType>,
        pool: &mut Pool<CoinType>,
        state: &mut ProtocolState,
        ctx: &mut TxContext
    ) { 
        
    }

    /*
        Withdraws a coin from a pool. This function decreases the user's collateral amount in the pool
        and removes the coin from the pool's reserve.
    */
    public fun withdraw<CoinType>(
        amount_to_withdraw: u64, 
        pool: &mut Pool<CoinType>,
        state: &mut ProtocolState,
        ctx: &mut TxContext
    ): Coin<CoinType> {
        
    }

    /*
        Borrows a coin from a pool. This function increases the user's borrowed amount in the pool
        and removes and returns the coin from the pool's reserve.
    */
    public fun borrow<CoinType>(
        amount_to_borrow: u64, 
        pool: &mut Pool<CoinType>,
        state: &mut ProtocolState,
        ctx: &mut TxContext
    ): Coin<CoinType> {
        
    }

    /*
        Repays a coin to a pool. This function decreases the user's borrowed amount in the pool
        and adds the coin to the pool's reserve.
    */
    public fun repay<CoinType>(
        coin_to_repay: Coin<CoinType>,
        pool: &mut Pool<CoinType>,
        state: &mut ProtocolState,
        ctx: &mut TxContext
    ) {
        
    }

    /*  
        Calculates the health factor of a user. The health factor is the ratio of the user's collateral
        to the user's borrowed amount. The health factor is calculated with a decimal precision of 2. 
        This means that a health factor of 1.34 should be represented as 134, and a health factor of 0.34
        should be represented as 34.

        See above for more information on how to calculate the health factor.
    */
    public fun calculate_health_factor(
        user: address,
        state: &ProtocolState,
        price_feed: &dummy_oracle::PriceFeed
    ): u64 {
        
    }

    //==============================================================================================
    // Tests - DO NOT MODIFY
    //==============================================================================================

    #[test_only]
    struct COIN1 has drop {}
    #[test_only]
    struct COIN2 has drop {}

    #[test]
    fun test_init_success_resources_created() {
        let module_owner = @0xa;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        let tx = test_scenario::next_tx(scenario, module_owner);
        let expected_created_objects = 2;
        let expected_shared_objects = 1;
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        assert_eq(
            vector::length(&test_scenario::shared(&tx)),
            expected_shared_objects
        );

        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            assert_eq(state.number_of_pools, 0);

            assert_eq(table::length(&state.users), 0);

            test_scenario::return_shared(state);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_create_pool_success_one_pool_created() {
        let module_owner = @0xa;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);


        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        let tx = test_scenario::next_tx(scenario, module_owner);
        let expected_created_objects = 1;
        let expected_shared_objects = 2;
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        assert_eq(
            vector::length(&test_scenario::shared(&tx)),
            expected_shared_objects
        );

        let expected_number_of_pools = 1;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            assert_eq(state.number_of_pools, expected_number_of_pools);

            test_scenario::return_shared(state);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_create_pool_success_multiple_pools_created() {
        let module_owner = @0xa;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            create_pool<COIN1>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            create_pool<COIN2>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        let tx = test_scenario::next_tx(scenario, module_owner);
        let expected_created_objects = 3;
        let expected_shared_objects = 4;
        assert_eq(
            vector::length(&test_scenario::created(&tx)),
            expected_created_objects
        );
        assert_eq(
            vector::length(&test_scenario::shared(&tx)),
            expected_shared_objects
        );

        let expected_number_of_pools = 3;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            assert_eq(state.number_of_pools, expected_number_of_pools);

            test_scenario::return_shared(state);
        };
        test_scenario::end(scenario_val);

    }

    #[test]
    fun test_deposit_success_deposit_sui() {
        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let deposit_amount = 100_000_000_000; // 100 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);


            let coin = coin::mint_for_testing<SUI>(deposit_amount, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let expected_users = 1;
        let expected_pools = 1;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let user_met = table::borrow(&state.users, user);
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);

            assert_eq(table::length(&state.users), expected_users);
            assert_eq(balance::value(&pool.reserve), deposit_amount);

            assert_eq(*table::borrow(&user_met.collateral_amount, 0), deposit_amount);

            test_scenario::return_shared(state);
            test_scenario::return_shared(pool);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_deposit_success_multiple_deposits_sui_by_same_person() {
        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let deposit_amount = 100_000_000_000; // 100 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = coin::mint_for_testing<SUI>(deposit_amount, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let coin = coin::mint_for_testing<SUI>(deposit_amount, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let expected_users = 1;
        let expected_pools = 1;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let user_met = table::borrow(&state.users, user);
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);

            assert_eq(table::length(&state.users), expected_users);
            assert_eq(balance::value(&pool.reserve), deposit_amount * 2);

            assert_eq(*table::borrow(&user_met.collateral_amount, 0), deposit_amount * 2);

            test_scenario::return_shared(state);
            test_scenario::return_shared(pool);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_deposit_success_one_user_deposits_different_pools() {
        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            create_pool<COIN1>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let deposit_amount_sui = 100_000_000_000; // 100 SUI
        let deposit_amount_coin1 = 100_000;

        {
            let pool_sui = test_scenario::take_shared<Pool<SUI>>(scenario);
            let pool_coin1 = test_scenario::take_shared<Pool<COIN1>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin_sui = coin::mint_for_testing<SUI>(deposit_amount_sui, test_scenario::ctx(scenario));

            deposit(
                coin_sui, 
                &mut pool_sui, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let coin_coin1 = coin::mint_for_testing<COIN1>(deposit_amount_coin1, test_scenario::ctx(scenario));

            deposit(
                coin_coin1, 
                &mut pool_coin1, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool_sui);
            test_scenario::return_shared(pool_coin1);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let expected_users = 1;
        let expected_pools = 2;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let user_met = table::borrow(&state.users, user);
            let pool_sui = test_scenario::take_shared<Pool<SUI>>(scenario);
            let pool_coin1 = test_scenario::take_shared<Pool<COIN1>>(scenario);

            assert_eq(table::length(&state.users), expected_users);
            assert_eq(balance::value(&pool_sui.reserve), deposit_amount_sui);
            assert_eq(balance::value(&pool_coin1.reserve), deposit_amount_coin1);

            assert_eq(*table::borrow(&user_met.collateral_amount, 0), deposit_amount_sui);
            assert_eq(*table::borrow(&user_met.collateral_amount, 1), deposit_amount_coin1);

            test_scenario::return_shared(state);
            test_scenario::return_shared(pool_sui);
            test_scenario::return_shared(pool_coin1);
        };
        test_scenario::end(scenario_val);

    }

    #[test]
    fun test_deposit_success_multiple_users_deposit_same_pool() {
        let module_owner = @0xa;
        let user1 = @0xb;
        let user2 = @0xc;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user1);

        let deposit_amount = 100_000_000_000; // 100 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = coin::mint_for_testing<SUI>(deposit_amount, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user2);

        let deposit_amount_user2 = 200_000_000_000; // 200 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = coin::mint_for_testing<SUI>(deposit_amount_user2, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user1);

        let expected_users = 2;
        let expected_pools = 1;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let user_met1 = table::borrow(&state.users, user1);
            let user_met2 = table::borrow(&state.users, user2);
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);

            assert_eq(table::length(&state.users), expected_users);
            assert_eq(balance::value(&pool.reserve), deposit_amount + deposit_amount_user2);

            assert_eq(*table::borrow(&user_met1.collateral_amount, 0), deposit_amount);
            assert_eq(*table::borrow(&user_met2.collateral_amount, 0), deposit_amount_user2);

            test_scenario::return_shared(state);
            test_scenario::return_shared(pool);
        };
        test_scenario::end(scenario_val);
    }
    
    #[test]
    fun test_withdraw_success_withdraw_from_pool_total_amount() {
        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let deposit_amount = 100_000_000_000; // 100 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = coin::mint_for_testing<SUI>(deposit_amount, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let withdraw_amount = 100_000_000_000; // 100 SUI
        let coin = {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = withdraw(
                withdraw_amount, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);

            coin
        };
        test_scenario::next_tx(scenario, user);

        let expected_users = 1;
        let expected_pools = 1;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let user_met = table::borrow(&state.users, user);
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);

            assert_eq(table::length(&state.users), expected_users);
            assert_eq(balance::value(&pool.reserve), deposit_amount - withdraw_amount);

            assert_eq(*table::borrow(&user_met.collateral_amount, 0), deposit_amount - withdraw_amount);

            assert_eq(coin::value(&coin), withdraw_amount);

            test_scenario::return_shared(state);
            test_scenario::return_shared(pool);
        };
        test_scenario::end(scenario_val);

        destroy(coin);
    }

    #[test]
    fun test_withdraw_success_withdraw_partial_amount() {
        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let deposit_amount = 100_000_000_000; // 100 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = coin::mint_for_testing<SUI>(deposit_amount, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let withdraw_amount = 50_000_000_000; // 50 SUI
        let coin = {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = withdraw(
                withdraw_amount, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);

            coin
        };
        test_scenario::next_tx(scenario, user);

        let expected_users = 1;
        let expected_pools = 1;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let user_met = table::borrow(&state.users, user);
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);

            assert_eq(table::length(&state.users), expected_users);
            assert_eq(balance::value(&pool.reserve), deposit_amount - withdraw_amount);

            assert_eq(*table::borrow(&user_met.collateral_amount, 0), deposit_amount - withdraw_amount);

            assert_eq(coin::value(&coin), withdraw_amount);

            test_scenario::return_shared(state);
            test_scenario::return_shared(pool);
        };
        test_scenario::end(scenario_val);
        
        destroy(coin);
    }

    #[test]
    fun test_borrow_success_user_borrow_partial_balance_of_pool() {
        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let deposit_amount = 100_000_000_000; // 100 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = coin::mint_for_testing<SUI>(deposit_amount, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let borrow_amount = 50_000_000_000; // 50 SUI
        let coin = {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = borrow(
                borrow_amount, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);

            coin
        };
        test_scenario::next_tx(scenario, user);

        let expected_users = 1;
        let expected_pools = 1;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let user_met = table::borrow(&state.users, user);
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);

            assert_eq(table::length(&state.users), expected_users);
            assert_eq(balance::value(&pool.reserve), deposit_amount - borrow_amount);

            assert_eq(*table::borrow(&user_met.borrowed_amount, 0), borrow_amount);

            assert_eq(coin::value(&coin), borrow_amount);

            test_scenario::return_shared(state);
            test_scenario::return_shared(pool);
        };
        test_scenario::end(scenario_val);

        destroy(coin);
    }

    #[test]
    fun test_borrow_success_borrow_whole_pool_amount() {
        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let deposit_amount = 100_000_000_000; // 100 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = coin::mint_for_testing<SUI>(deposit_amount, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let borrow_amount = 100_000_000_000; // 100 SUI
        let coin = {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = borrow(
                borrow_amount, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);

            coin
        };
        test_scenario::next_tx(scenario, user);

        let expected_users = 1;
        let expected_pools = 1;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let user_met = table::borrow(&state.users, user);
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);

            assert_eq(table::length(&state.users), expected_users);
            assert_eq(balance::value(&pool.reserve), deposit_amount - borrow_amount);

            assert_eq(*table::borrow(&user_met.borrowed_amount, 0), borrow_amount);

            assert_eq(coin::value(&coin), borrow_amount);

            test_scenario::return_shared(state);
            test_scenario::return_shared(pool);
        };
        test_scenario::end(scenario_val);

        destroy(coin);
    }

    #[test]
    fun test_repay_success_repay_users_full_borrowed_amount() {
        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let deposit_amount = 100_000_000_000; // 100 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = coin::mint_for_testing<SUI>(deposit_amount, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let borrow_amount = 100_000_000_000; // 100 SUI
        let coin = {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = borrow(
                borrow_amount, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);

            coin
        };
        test_scenario::next_tx(scenario, user);

        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            repay(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let expected_users = 1;
        let expected_pools = 1;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let user_met = table::borrow(&state.users, user);
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);

            assert_eq(table::length(&state.users), expected_users);
            assert_eq(balance::value(&pool.reserve), deposit_amount);

            assert_eq(*table::borrow(&user_met.borrowed_amount, 0), 0);

            test_scenario::return_shared(state);
            test_scenario::return_shared(pool);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_repay_success_repay_users_partial_borrowed_amount() {
        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let deposit_amount = 100_000_000_000; // 100 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = coin::mint_for_testing<SUI>(deposit_amount, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let borrow_amount = 100_000_000_000; // 100 SUI
        let coin = {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = borrow(
                borrow_amount, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);

            coin
        };
        test_scenario::next_tx(scenario, user);

        let repay_amount = 50_000_000_000; // 50 SUI
        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            repay(
                coin::split(&mut coin, repay_amount, test_scenario::ctx(scenario)), 
                &mut pool, 
                &mut state,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        let expected_users = 1;
        let expected_pools = 1;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let user_met = table::borrow(&state.users, user);
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);

            assert_eq(table::length(&state.users), expected_users);
            assert_eq(balance::value(&pool.reserve), deposit_amount - repay_amount);

            assert_eq(*table::borrow(&user_met.borrowed_amount, 0), borrow_amount - repay_amount);

            test_scenario::return_shared(state);
            test_scenario::return_shared(pool);
        };
        test_scenario::end(scenario_val);

        destroy(coin);
    }

    #[test]
    fun test_calculate_health_factor_success_one_coin() {
        let deposit_amount_sui = 100_000_000_000; // 100 SUI
        let borrow_amount_sui = 50_000_000_000; // 50 SUI

        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        {
            let pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let coin = coin::mint_for_testing<SUI>(deposit_amount_sui, test_scenario::ctx(scenario));

            deposit(
                coin, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let coin = borrow(
                borrow_amount_sui, 
                &mut pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(state);

            destroy(coin);
        };
        test_scenario::next_tx(scenario, user);

        let sui_price = 100; // 1 SUI = 1.00 USD
        {
            dummy_oracle::init_module(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let feed = test_scenario::take_shared<dummy_oracle::PriceFeed>(scenario);

            dummy_oracle::add_new_coin(
                sui_price, 
                9, 
                &mut feed
            );

            test_scenario::return_shared(feed);
        };
        test_scenario::next_tx(scenario, user);

        let expected_health_factor = 160;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let feed = test_scenario::take_shared<dummy_oracle::PriceFeed>(scenario);


            let health_factor = calculate_health_factor(
                user,
                &state, 
                &feed
            );

            assert_eq(health_factor, expected_health_factor);

            test_scenario::return_shared(state);
            test_scenario::return_shared(feed);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_calculate_health_factor_success_two_coins_same_price_same_amount() {
        let deposit_amount_sui = 100_000_000_000; // 100 SUI
        let deposit_amount_coin1 = 100_000; // 100 coin1
        let borrow_amount_sui = 50_000_000_000; // 50 SUI


        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            create_pool<COIN1>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        {
            let sui_pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let coin1_pool = test_scenario::take_shared<Pool<COIN1>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let sui_coin = coin::mint_for_testing<SUI>(deposit_amount_sui, test_scenario::ctx(scenario));

            deposit(
                sui_coin, 
                &mut sui_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let coin1_coin = coin::mint_for_testing<COIN1>(deposit_amount_coin1, test_scenario::ctx(scenario));

            deposit(
                coin1_coin, 
                &mut coin1_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let borrow_coin = borrow(
                borrow_amount_sui, 
                &mut sui_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(sui_pool);
            test_scenario::return_shared(coin1_pool);
            test_scenario::return_shared(state);

            destroy(borrow_coin);
        };
        test_scenario::next_tx(scenario, user);

        let sui_price = 100; // 1 SUI = 1.00 USD
        let coin1_price = 100; // 1 coin1 = 1.00 USD
        {
            dummy_oracle::init_module(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let feed = test_scenario::take_shared<dummy_oracle::PriceFeed>(scenario);

            dummy_oracle::add_new_coin(
                sui_price, 
                9, 
                &mut feed
            );

            dummy_oracle::add_new_coin(
                coin1_price, 
                3, 
                &mut feed
            );

            test_scenario::return_shared(feed);
        };
        test_scenario::next_tx(scenario, user);

        let expected_health_factor = 2 * 160;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let feed = test_scenario::take_shared<dummy_oracle::PriceFeed>(scenario);


            let health_factor = calculate_health_factor(
                user,
                &state, 
                &feed
            );

            assert_eq(health_factor, expected_health_factor);

            test_scenario::return_shared(state);
            test_scenario::return_shared(feed);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_calculate_health_factor_success_two_coins_same_price_different_amount() {
        let deposit_amount_sui = 100_000_000_000; // 100 SUI
        let deposit_amount_coin1 = 50_000; // 100 coin1
        let borrow_amount_sui = 50_000_000_000; // 50 SUI


        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            create_pool<COIN1>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        {
            let sui_pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let coin1_pool = test_scenario::take_shared<Pool<COIN1>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let sui_coin = coin::mint_for_testing<SUI>(deposit_amount_sui, test_scenario::ctx(scenario));

            deposit(
                sui_coin, 
                &mut sui_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let coin1_coin = coin::mint_for_testing<COIN1>(deposit_amount_coin1, test_scenario::ctx(scenario));

            deposit(
                coin1_coin, 
                &mut coin1_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let borrow_coin = borrow(
                borrow_amount_sui, 
                &mut sui_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(sui_pool);
            test_scenario::return_shared(coin1_pool);
            test_scenario::return_shared(state);

            destroy(borrow_coin);
        };
        test_scenario::next_tx(scenario, user);

        let sui_price = 100; // 1 SUI = 1.00 USD
        let coin1_price = 100; // 1 coin1 = 1.00 USD
        {
            dummy_oracle::init_module(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let feed = test_scenario::take_shared<dummy_oracle::PriceFeed>(scenario);

            dummy_oracle::add_new_coin(
                sui_price, 
                9, 
                &mut feed
            );

            dummy_oracle::add_new_coin(
                coin1_price, 
                3, 
                &mut feed
            );

            test_scenario::return_shared(feed);
        };
        test_scenario::next_tx(scenario, user);

        let expected_health_factor = 240;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let feed = test_scenario::take_shared<dummy_oracle::PriceFeed>(scenario);


            let health_factor = calculate_health_factor(
                user,
                &state, 
                &feed
            );

            assert_eq(health_factor, expected_health_factor);

            test_scenario::return_shared(state);
            test_scenario::return_shared(feed);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_calculate_health_factor_success_two_coins_different_price_same_amount() {
        let deposit_amount_sui = 100_000_000_000; // 100 SUI
        let deposit_amount_coin1 = 100_000; // 100 coin1
        let borrow_amount_sui = 50_000_000_000; // 50 SUI


        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            create_pool<COIN1>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        {
            let sui_pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let coin1_pool = test_scenario::take_shared<Pool<COIN1>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let sui_coin = coin::mint_for_testing<SUI>(deposit_amount_sui, test_scenario::ctx(scenario));

            deposit(
                sui_coin, 
                &mut sui_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let coin1_coin = coin::mint_for_testing<COIN1>(deposit_amount_coin1, test_scenario::ctx(scenario));

            deposit(
                coin1_coin, 
                &mut coin1_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let borrow_coin = borrow(
                borrow_amount_sui, 
                &mut sui_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(sui_pool);
            test_scenario::return_shared(coin1_pool);
            test_scenario::return_shared(state);

            destroy(borrow_coin);
        };
        test_scenario::next_tx(scenario, user);

        let sui_price = 150; // 1 SUI = 1.00 USD
        let coin1_price = 4530; // 1 coin1 = 1.00 USD
        {
            dummy_oracle::init_module(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let feed = test_scenario::take_shared<dummy_oracle::PriceFeed>(scenario);

            dummy_oracle::add_new_coin(
                sui_price, 
                9, 
                &mut feed
            );

            dummy_oracle::add_new_coin(
                coin1_price, 
                3, 
                &mut feed
            );

            test_scenario::return_shared(feed);
        };
        test_scenario::next_tx(scenario, user);

        let expected_health_factor = 4992;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let feed = test_scenario::take_shared<dummy_oracle::PriceFeed>(scenario);


            let health_factor = calculate_health_factor(
                user,
                &state, 
                &feed
            );

            assert_eq(health_factor, expected_health_factor);

            test_scenario::return_shared(state);
            test_scenario::return_shared(feed);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_calculate_health_factor_success_two_coins_bad_health() {
        let deposit_amount_sui = 100_000_000_000; // 100 SUI
        let deposit_amount_coin1 = 100_000; // 100 coin1
        let borrow_amount_sui = 50_000_000_000; // 50 SUI
        let borrow_amount_coin1 = 90_000; // 50 coin1


        let module_owner = @0xa;
        let user = @0xb;

        let scenario_val = test_scenario::begin(module_owner);
        let scenario = &mut scenario_val;

        {
            init(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let admin_cap = test_scenario:: take_from_sender<AdminCap>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            create_pool<SUI>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            create_pool<COIN1>(
                &mut admin_cap, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_shared(state);
        };
        test_scenario::next_tx(scenario, user);

        {
            let sui_pool = test_scenario::take_shared<Pool<SUI>>(scenario);
            let coin1_pool = test_scenario::take_shared<Pool<COIN1>>(scenario);
            let state = test_scenario::take_shared<ProtocolState>(scenario);

            let sui_coin = coin::mint_for_testing<SUI>(deposit_amount_sui, test_scenario::ctx(scenario));

            deposit(
                sui_coin, 
                &mut sui_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let coin1_coin = coin::mint_for_testing<COIN1>(deposit_amount_coin1, test_scenario::ctx(scenario));

            deposit(
                coin1_coin, 
                &mut coin1_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let borrow_coin_sui = borrow(
                borrow_amount_sui, 
                &mut sui_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            let borrow_coin_coin1 = borrow(
                borrow_amount_coin1, 
                &mut coin1_pool, 
                &mut state, 
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(sui_pool);
            test_scenario::return_shared(coin1_pool);
            test_scenario::return_shared(state);

            destroy(borrow_coin_sui);
            destroy(borrow_coin_coin1);
        };
        test_scenario::next_tx(scenario, user);

        let sui_price = 150; // 1 SUI = 1.00 USD
        let coin1_price = 4530; // 1 coin1 = 45.30 USD
        {
            dummy_oracle::init_module(test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, module_owner);

        {
            let feed = test_scenario::take_shared<dummy_oracle::PriceFeed>(scenario);

            dummy_oracle::add_new_coin(
                sui_price, 
                9, 
                &mut feed
            );

            dummy_oracle::add_new_coin(
                coin1_price, 
                3, 
                &mut feed
            );

            test_scenario::return_shared(feed);
        };
        test_scenario::next_tx(scenario, user);

        let expected_health_factor = 90;
        {
            let state = test_scenario::take_shared<ProtocolState>(scenario);
            let feed = test_scenario::take_shared<dummy_oracle::PriceFeed>(scenario);


            let health_factor = calculate_health_factor(
                user,
                &state, 
                &feed
            );

            assert_eq(health_factor, expected_health_factor);

            test_scenario::return_shared(state);
            test_scenario::return_shared(feed);
        };
        test_scenario::end(scenario_val);
    }
}

module overmind::dummy_oracle {

    //==============================================================================================
    // Dependencies
    //==============================================================================================
    use std::vector;
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;

    struct PriceFeed has key {
        id: UID, 
        prices: vector<u64>,
        decimals: vector<u8>
    }

    public fun init_module(ctx: &mut TxContext) {
        transfer::share_object(
            PriceFeed {
                id: object::new(ctx),
                prices: vector::empty(),
                decimals: vector::empty()
            }
        );
    }

    public fun add_new_coin(
        price: u64,
        decimals: u8,
        feed: &mut PriceFeed
    ) {
        vector::push_back(&mut feed.prices, price);
        vector::push_back(&mut feed.decimals, decimals);
    }

    public fun update_price(
        new_price: u64,
        coin_number: u64,
        feed: &mut PriceFeed
    ) {
        let existing_price = vector::borrow_mut(&mut feed.prices, coin_number);
        *existing_price = new_price;
    }

    public fun get_price_and_decimals(
        coin_number: u64,
        feed: &PriceFeed
    ): (u64, u8) {
        (*vector::borrow(&feed.prices, coin_number), *vector::borrow(&feed.decimals, coin_number))
    }


}