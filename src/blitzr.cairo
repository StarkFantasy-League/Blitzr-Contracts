use starknet::ContractAddress;


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
pub enum BetStatus {
    #[default]
    Pending,
    Won,
    Lost,
    Withdrawn,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Bet {
    pub bet_id: u256,
    pub user: ContractAddress,
    pub match_id: u256,
    pub amount: u256,
    pub predicted_result: felt252,
    pub timestamp: u64,
    pub status: BetStatus,
}

#[starknet::interface]
pub trait IBlitzr<TContractState> {
    // Main view functions
    fn get_bet(self: @TContractState, bet_id: u256) -> Bet;
    fn get_user_bet_count(self: @TContractState, user: ContractAddress) -> u256;
    fn get_user_bet_by_index(self: @TContractState, user: ContractAddress, index: u256) -> u256;
    fn get_match_pool_info(self: @TContractState, match_id: u256) -> (u256, u256, u256, u256); // (total, team_a_pool, team_b_pool, draw_pool)
    
    // Core betting functions
    fn create_bet(ref self: TContractState, match_id: u256, amount: u256, predicted_result: felt252) -> u256;
    
    // Validation function
    fn update_bet_result(ref self: TContractState, bet_id: u256, match_result: felt252);
    fn withdraw_winnings(ref self: TContractState, bet_id: u256);
    
    // Utility functions
    fn calculate_winnings(self: @TContractState, bet_id: u256) -> u256;
}

#[starknet::contract]
pub mod Blitzr {
    use starknet::storage::{
        StorageMapReadAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
        StorageMapWriteAccess, Map
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::{Bet, BetStatus};

    //////////// STORAGE ////////////
    #[storage]
    struct Storage {
        // Core counters
        bet_counter: u256,
        
        // Bet data
        bets: Map<u256, Bet>,
        
        // User bet tracking
        user_bet_counts: Map<ContractAddress, u256>,
        user_bet_ids: Map<(ContractAddress, u256), u256>, // (user, index) -> bet_id
        
        // Pool tracking by match_id
        match_pools: Map<(u256, felt252), u256>, // (match_id, result) -> total amount
        total_match_pools: Map<u256, u256>, // match_id -> total pool
        completed_matches: Map<u256, felt252>, // match_id -> result (0 = not completed)
        
        // Token settings
        erc20: IERC20Dispatcher,
        token_address: ContractAddress,
        
        // Protocol settings
        protocol_fee_percentage: u256,
    }

    //////////// EVENTS ////////////

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BetCreated: BetCreated,
        BetUpdated: BetUpdated,
        WinningsWithdrawn: WinningsWithdrawn,
    }

    #[derive(Drop, starknet::Event)]
    struct BetCreated {
        bet_id: u256,
        user: ContractAddress,
        match_id: u256,
        amount: u256,
        predicted_result: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct BetUpdated {
        bet_id: u256,
        user: ContractAddress,
        new_status: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct WinningsWithdrawn {
        bet_id: u256,
        user: ContractAddress,
        amount: u256,
    }

    //////////// CONSTRUCTOR ////////////

    #[constructor]
    fn constructor(ref self: ContractState, token_address: ContractAddress) {
        self.erc20.write(IERC20Dispatcher { contract_address: token_address });
        self.token_address.write(token_address);
        
        // Default settings
        self.protocol_fee_percentage.write(3); // 3% protocol fee
    }

    //////////// IMPLEMENTATION ////////////

    #[abi(embed_v0)]
    impl Blitzr of super::IBlitzr<ContractState> {

        //////////// VIEW FUNCTIONS ////////////
        fn get_bet(self: @ContractState, bet_id: u256) -> Bet {
            self.bets.read(bet_id)
        }

        fn get_user_bet_count(self: @ContractState, user: ContractAddress) -> u256 {
            self.user_bet_counts.read(user)
        }

        fn get_user_bet_by_index(self: @ContractState, user: ContractAddress, index: u256) -> u256 {
            self.user_bet_ids.read((user, index))
        }

        fn get_match_pool_info(self: @ContractState, match_id: u256) -> (u256, u256, u256, u256) {
            let total = self.total_match_pools.read(match_id);
            let team_a_pool = self.match_pools.read((match_id, 1));
            let team_b_pool = self.match_pools.read((match_id, 2));
            let draw_pool = self.match_pools.read((match_id, 3));
            (total, team_a_pool, team_b_pool, draw_pool)
        }

        //////////// BETTING FUNCTIONS ////////////

        fn create_bet(
            ref self: ContractState,
            match_id: u256,
            amount: u256,
            predicted_result: felt252
        ) -> u256 {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            // Basic validations
            assert(amount > 0, 'Amount must be greater than 0');
            
            // Check if match is not completed
            let match_result = self.completed_matches.read(match_id);
            assert(match_result == 0, 'Match already completed');
            
            // Validate user has sufficient balance
            self._validate_user_balance(caller, amount);
            
            // Transfer tokens
            let dispatcher = IERC20Dispatcher { contract_address: self.token_address.read() };
            let result = dispatcher.transfer_from(caller, get_contract_address(), amount);
            assert(result, 'Token transfer failed');
            
            // Create bet
            let bet_id = self.bet_counter.read() + 1;
            self.bet_counter.write(bet_id);
            
            let bet = Bet {
                bet_id,
                user: caller,
                match_id,
                amount,
                predicted_result,
                timestamp: current_time,
                status: BetStatus::Pending,
            };
            
            self.bets.write(bet_id, bet);
            
            // Update user bet tracking
            let user_bet_count = self.user_bet_counts.read(caller);
            self.user_bet_ids.write((caller, user_bet_count), bet_id);
            self.user_bet_counts.write(caller, user_bet_count + 1);
            
            // Update pools
            let current_pool = self.match_pools.read((match_id, predicted_result));
            self.match_pools.write((match_id, predicted_result), current_pool + amount);
            
            let total_pool = self.total_match_pools.read(match_id);
            self.total_match_pools.write(match_id, total_pool + amount);
            
            self.emit(BetCreated {
                bet_id,
                user: caller,
                match_id,
                amount,
                predicted_result,
            });
            
            bet_id
        }

        //////////// VALIDATION FUNCTIONS ////////////

        fn update_bet_result(ref self: ContractState, bet_id: u256, match_result: felt252) {
            let bet = self.bets.read(bet_id);
            
            // Only update bets that are pending
            if bet.status != BetStatus::Pending {
                return;
            }
            
            // Mark match as completed if not already
            let existing_result = self.completed_matches.read(bet.match_id);
            if existing_result == 0 {
                self.completed_matches.write(bet.match_id, match_result);
            }
            
            // Update bet status
            let mut updated_bet = bet;
            if bet.predicted_result == match_result {
                updated_bet.status = BetStatus::Won;
            } else {
                updated_bet.status = BetStatus::Lost;
            }
            
            self.bets.write(bet_id, updated_bet);
            
            self.emit(BetUpdated {
                bet_id,
                user: bet.user,
                new_status: self._bet_status_to_felt(updated_bet.status),
            });
        }

        //////////// UTILITY FUNCTIONS ////////////

        fn calculate_winnings(self: @ContractState, bet_id: u256) -> u256 {
            let bet = self.bets.read(bet_id);
            
            if bet.status != BetStatus::Won {
                return 0;
            }
            
            let match_result = self.completed_matches.read(bet.match_id);
            let total_pool = self.total_match_pools.read(bet.match_id);
            let winning_pool = self.match_pools.read((bet.match_id, match_result));
            let protocol_fee_percentage = self.protocol_fee_percentage.read();
            
            if winning_pool == 0 {
                return 0;
            }
            
            // Calculate winnings: (user_bet / winning_pool) * (total_pool - protocol_fee) - protocol fee
            let protocol_fee = (total_pool * protocol_fee_percentage) / 100;
            let distributable_pool = total_pool - protocol_fee;
            
            (bet.amount * distributable_pool) / winning_pool
        }

        //////////// WITHDRAW FUNCTIONS ////////////

        fn withdraw_winnings(ref self: ContractState, bet_id: u256) {
            let caller = get_caller_address();
            let bet = self.bets.read(bet_id);
            
            assert(bet.user == caller, 'Not bet owner');
            assert(bet.status == BetStatus::Won, 'Bet did not win');
            
            let winnings = self.calculate_winnings(bet_id);
            assert(winnings > 0, 'No winnings to withdraw');
            
            // Update bet status
            let mut updated_bet = bet;
            updated_bet.status = BetStatus::Withdrawn;
            self.bets.write(bet_id, updated_bet);
            
            // Transfer winnings to user    
            let dispatcher = IERC20Dispatcher { contract_address: self.token_address.read() };
            let result = dispatcher.transfer(caller, winnings);
            assert(result, 'Winnings transfer failed');
            
            self.emit(WinningsWithdrawn {
                bet_id,
                user: caller,
                amount: winnings,
            });
        }
    }

    //////////// PRIVATE FUNCTIONS ////////////

    #[generate_trait]
    impl Private of PrivateTrait {
        fn _validate_user_balance(
            ref self: ContractState,
            user: ContractAddress,
            amount: u256
        ) {
            let user_balance = self.erc20.read().balance_of(user);
            assert(user_balance >= amount, 'Insufficient balance');
        }
        
        fn _bet_status_to_felt(self: @ContractState, status: BetStatus) -> felt252 {
            match status {
                BetStatus::Pending => 'Pending',
                BetStatus::Won => 'Won',
                BetStatus::Lost => 'Lost',
                BetStatus::Withdrawn => 'Withdrawn',
            }
        }
    }
}