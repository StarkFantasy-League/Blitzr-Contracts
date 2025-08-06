use starknet::ContractAddress;

#[starknet::interface]
pub trait IMockERC20<TContractState> {
    // Mock-specific function for testing
    fn mint(ref self: TContractState, recipient: ContractAddress, amount: u256);
}

#[starknet::contract]
pub mod MockERC20 {
    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use starknet::ContractAddress;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    // ERC20 Mixin (includes all standard ERC20 functions)
    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;
    impl ERC20HooksImpl = ERC20HooksEmptyImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        let name = "Mock Starknet Token";
        let symbol = "MSTRK";

        self.erc20.initializer(name, symbol);
    }

    #[abi(embed_v0)]
    impl MockERC20Impl of super::IMockERC20<ContractState> {
        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            self.erc20.mint(recipient, amount);
        }
    }
}
