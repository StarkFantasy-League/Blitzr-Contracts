use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address, stop_cheat_caller_address};
use blitzr::{IBlitzrDispatcher, IBlitzrDispatcherTrait, BetStatus, IMockERC20Dispatcher, IMockERC20DispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

fn OWNER() -> ContractAddress { starknet::contract_address_const::<'OWNER'>() }
fn USER_ALICE() -> ContractAddress { starknet::contract_address_const::<'ALICE'>() }
fn USER_BOB() -> ContractAddress { starknet::contract_address_const::<'BOB'>() }
fn USER_CHARLIE() -> ContractAddress { starknet::contract_address_const::<'CHARLIE'>() }

fn deploy_mock_erc20() -> IMockERC20Dispatcher {
    let contract = declare("MockERC20").unwrap();
    let constructor_calldata = array![];
    
    let (contract_address, _) = contract.contract_class().deploy(@constructor_calldata).unwrap();
    IMockERC20Dispatcher { contract_address }
}

fn deploy_blitzr_contract(token_address: ContractAddress) -> IBlitzrDispatcher {
    let contract = declare("Blitzr").unwrap();
    let mut constructor_calldata = array![];
    constructor_calldata.append(token_address.into());
    
    let (contract_address, _) = contract.contract_class().deploy(@constructor_calldata).unwrap();
    IBlitzrDispatcher { contract_address }
}

fn setup_test_environment() -> (IBlitzrDispatcher, IMockERC20Dispatcher) {
    // Deploy ERC20 mock first
    let mock_erc20 = deploy_mock_erc20();
    
    // Create standard ERC20 dispatcher using the same contract address
    let erc20 = IERC20Dispatcher { contract_address: mock_erc20.contract_address };
    
    // Deploy Blitzr contract with real token address
    let blitzr = deploy_blitzr_contract(mock_erc20.contract_address);
    
    // Mint tokens for test users
    let initial_balance = 1000_000_000_000_000_000; // 1000 MSTRK (18 decimals)
    mock_erc20.mint(USER_ALICE(), initial_balance);
    mock_erc20.mint(USER_BOB(), initial_balance);
    mock_erc20.mint(USER_CHARLIE(), initial_balance);
    
    // Approve Blitzr contract to spend tokens for all users
    start_cheat_caller_address(erc20.contract_address, USER_ALICE());
    erc20.approve(blitzr.contract_address, initial_balance);
    stop_cheat_caller_address(erc20.contract_address);
    
    start_cheat_caller_address(erc20.contract_address, USER_BOB());
    erc20.approve(blitzr.contract_address, initial_balance);
    stop_cheat_caller_address(erc20.contract_address);
    
    start_cheat_caller_address(erc20.contract_address, USER_CHARLIE());
    erc20.approve(blitzr.contract_address, initial_balance);
    stop_cheat_caller_address(erc20.contract_address);
    
    (blitzr, mock_erc20)
}

#[test]
fn test_create_simple_bet() {
    let (blitzr, _erc20) = setup_test_environment();
    
    start_cheat_caller_address(blitzr.contract_address, USER_ALICE());
    
    let bet_id = blitzr.create_bet(
        match_id: 1, // Real Madrid vs Barcelona  
        amount: 100_000_000_000_000_000, // 100 STRK (18 decimals)
        predicted_result: 1 // Team Madrid gana
    );
    
    stop_cheat_caller_address(blitzr.contract_address);
    
    let bet = blitzr.get_bet(bet_id);
    assert(bet.user == USER_ALICE(), 'Wrong user');
    assert(bet.match_id == 1, 'Wrong match_id');
    assert(bet.amount == 100_000_000_000_000_000, 'Wrong amount');
    assert(bet.predicted_result == 1, 'Wrong prediction');
    assert(bet.status == BetStatus::Pending, 'Wrong status');
    
    let (total, team_a_pool, team_b_pool, draw_pool) = blitzr.get_match_pool_info(1);
    assert(total == 100_000_000_000_000_000, 'Wrong total pool');
    assert(team_a_pool == 100_000_000_000_000_000, 'Wrong team A pool');
    assert(team_b_pool == 0, 'Team B pool should be 0');
    assert(draw_pool == 0, 'Draw pool should be 0');
}

#[test]
fn test_multiple_users_same_match() {
    let (blitzr, _erc20) = setup_test_environment();
    
    start_cheat_caller_address(blitzr.contract_address, USER_ALICE());
    let alice_bet_id = blitzr.create_bet(1, 200_000_000_000_000_000, 1);
    stop_cheat_caller_address(blitzr.contract_address);
    
    start_cheat_caller_address(blitzr.contract_address, USER_BOB());
    let bob_bet_id = blitzr.create_bet(1, 150_000_000_000_000_000, 2);
    stop_cheat_caller_address(blitzr.contract_address);
    
    // Charlie apuesta 50 STRK al empate
    start_cheat_caller_address(blitzr.contract_address, USER_CHARLIE());
    let charlie_bet_id = blitzr.create_bet(1, 50_000_000_000_000_000, 3);
    stop_cheat_caller_address(blitzr.contract_address);
    
    let (total, team_a_pool, team_b_pool, draw_pool) = blitzr.get_match_pool_info(1);
    assert(total == 400_000_000_000_000_000, 'Wrong total: 400 STRK');
    assert(team_a_pool == 200_000_000_000_000_000, 'Wrong Madrid pool: 200 STRK');
    assert(team_b_pool == 150_000_000_000_000_000, 'Wrong Barca pool: 150 STRK');
    assert(draw_pool == 50_000_000_000_000_000, 'Wrong draw pool: 50 STRK');
    
    assert(blitzr.get_user_bet_count(USER_ALICE()) == 1, 'Alice should have 1 bet');
    assert(blitzr.get_user_bet_count(USER_BOB()) == 1, 'Bob should have 1 bet');
    assert(blitzr.get_user_bet_count(USER_CHARLIE()) == 1, 'Charlie should have 1 bet');
    
    assert(blitzr.get_user_bet_by_index(USER_ALICE(), 0) == alice_bet_id, 'Wrong Alice bet ID');
    assert(blitzr.get_user_bet_by_index(USER_BOB(), 0) == bob_bet_id, 'Wrong Bob bet ID');
    assert(blitzr.get_user_bet_by_index(USER_CHARLIE(), 0) == charlie_bet_id, 'Wrong Charlie bet ID');
}

#[test]
fn test_user_multiple_bets_different_matches() {
    let (blitzr, _erc20) = setup_test_environment();
    
    start_cheat_caller_address(blitzr.contract_address, USER_ALICE());
    
    let bet1 = blitzr.create_bet(1, 100_000_000_000_000_000, 1); // Clasico - Madrid gana
    let bet2 = blitzr.create_bet(2, 75_000_000_000_000_000, 2);  // Liverpool vs City - City gana  
    let bet3 = blitzr.create_bet(3, 50_000_000_000_000_000, 3);  // Chelsea vs Arsenal - Empate
    
    stop_cheat_caller_address(blitzr.contract_address);
    
    assert(blitzr.get_user_bet_count(USER_ALICE()) == 3, 'Alice should have 3 bets');
    
    assert(blitzr.get_user_bet_by_index(USER_ALICE(), 0) == bet1, 'Wrong bet 1 ID');
    assert(blitzr.get_user_bet_by_index(USER_ALICE(), 1) == bet2, 'Wrong bet 2 ID');
    assert(blitzr.get_user_bet_by_index(USER_ALICE(), 2) == bet3, 'Wrong bet 3 ID');
    
    let (total1, _, _, _) = blitzr.get_match_pool_info(1);
    let (total2, _, _, _) = blitzr.get_match_pool_info(2);
    let (total3, _, _, _) = blitzr.get_match_pool_info(3);
    
    assert(total1 == 100_000_000_000_000_000, 'Wrong match 1 total');
    assert(total2 == 75_000_000_000_000_000, 'Wrong match 2 total');
    assert(total3 == 50_000_000_000_000_000, 'Wrong match 3 total');
}

#[test]
#[should_panic(expected: 'Amount must be greater than 0')]
fn test_create_bet_zero_amount() {
    let (blitzr, _erc20) = setup_test_environment();
    
    start_cheat_caller_address(blitzr.contract_address, USER_ALICE());
    blitzr.create_bet(1, 0, 1); // Should fail
}

#[test]
#[should_panic(expected: 'Match already completed')]
fn test_create_bet_completed_match() {
    let (blitzr, _erc20) = setup_test_environment();
    
    start_cheat_caller_address(blitzr.contract_address, USER_ALICE());
    let bet_id = blitzr.create_bet(1, 100_000_000_000_000_000, 1);
    stop_cheat_caller_address(blitzr.contract_address);
    
    blitzr.update_bet_result(bet_id, 1); // Madrid gana
    
    start_cheat_caller_address(blitzr.contract_address, USER_BOB());
    blitzr.create_bet(1, 50_000_000_000_000_000, 2); // Should fail
}