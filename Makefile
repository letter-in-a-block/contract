export PATH := $(PATH):$(HOME)/.foundry/bin
ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

.PHONY: build test anvil deploy-local deploy-sepolia verify-sepolia abi

build:
	forge build

test:
	forge test -vvv

anvil:
	anvil

deploy-local:
	mkdir -p deployments
	DEPLOYER_PRIVATE_KEY=$(ANVIL_KEY) forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

deploy-sepolia:
	mkdir -p deployments
	set -a; . ./.env; set +a; \
	forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast

verify-sepolia:
	set -a; . ./.env; set +a; \
	F=$$(jq -r .forwarder deployments/84532.json); S=$$(jq -r .bottleSea deployments/84532.json); \
	forge verify-contract $$F lib/openzeppelin-contracts/contracts/metatx/ERC2771Forwarder.sol:ERC2771Forwarder \
	  --chain 84532 --etherscan-api-key $$ETHERSCAN_API_KEY --watch \
	  --constructor-args $$(cast abi-encode "constructor(string)" "BottleForwarder"); \
	forge verify-contract $$S src/BottleSea.sol:BottleSea \
	  --chain 84532 --etherscan-api-key $$ETHERSCAN_API_KEY --watch \
	  --constructor-args $$(cast abi-encode "constructor(address)" $$F)

abi:
	mkdir -p abi
	forge inspect BottleSea abi --json | jq . > abi/BottleSea.json
	forge inspect ERC2771Forwarder abi --json | jq . > abi/ERC2771Forwarder.json
