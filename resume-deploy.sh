#!/bin/bash
set -e

export PATH="$HOME/.foundry/bin:$HOME/.drosera/bin:$PATH"

WALLET_ADDRESS="0xc93bf33438c9c636fc49cafe1086c2c424507a15"
DROSERA_CALLER="${DROSERA_CALLER:-$WALLET_ADDRESS}"
HOODI_RPC="${RPC_URL:-https://ethereum-hoodi-rpc.publicnode.com}"
MOCK_ADDRESS="${MOCK_ADDRESS:-}"

if [ -z "$PRIVATE_KEY" ]; then
    echo "ERROR: PRIVATE_KEY not set"; exit 1
fi
if [ -z "$MOCK_ADDRESS" ]; then
    echo "ERROR: MOCK_ADDRESS not set"; exit 1
fi

cd /mnt/c/Users/ndohj/2026/drosera-beanstalk-trap

echo "Using existing BeanstalkMock: $MOCK_ADDRESS"
echo ""

# Step 2: Deploy BeanstalkAttacker
echo ">>> Step 2: Deploying BeanstalkAttacker..."
ATTACKER_OUTPUT=$(forge create src/BeanstalkAttacker.sol:BeanstalkAttacker \
    --rpc-url "$HOODI_RPC" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --constructor-args "$MOCK_ADDRESS" 2>&1)
RC=$?
echo "$ATTACKER_OUTPUT"
if [ $RC -ne 0 ]; then echo "STEP 2 FAILED"; exit 1; fi
ATTACKER_ADDRESS=$(echo "$ATTACKER_OUTPUT" | grep -oP "Deployed to: \K0x[a-fA-F0-9]{40}")
if [ -z "$ATTACKER_ADDRESS" ]; then echo "ERROR: Could not parse BeanstalkAttacker address"; exit 1; fi
echo "BeanstalkAttacker: $ATTACKER_ADDRESS"
echo ""

# Step 3: Deploy BeanstalkVault
echo ">>> Step 3: Deploying BeanstalkVault..."
VAULT_OUTPUT=$(forge create src/BeanstalkVault.sol:BeanstalkVault \
    --rpc-url "$HOODI_RPC" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --constructor-args "$MOCK_ADDRESS" "$DROSERA_CALLER" 2>&1)
RC=$?
echo "$VAULT_OUTPUT"
if [ $RC -ne 0 ]; then echo "STEP 3 FAILED"; exit 1; fi
VAULT_ADDRESS=$(echo "$VAULT_OUTPUT" | grep -oP "Deployed to: \K0x[a-fA-F0-9]{40}")
if [ -z "$VAULT_ADDRESS" ]; then echo "ERROR: Could not parse BeanstalkVault address"; exit 1; fi
echo "BeanstalkVault: $VAULT_ADDRESS"
echo ""

# Step 3b: Set pause guardian
echo ">>> Step 3b: Setting pause guardian to BeanstalkVault..."
cast send "$MOCK_ADDRESS" "setPauseGuardian(address)" "$VAULT_ADDRESS" \
    --rpc-url "$HOODI_RPC" \
    --private-key "$PRIVATE_KEY"
echo "Pause guardian set to vault."
echo ""

# Step 4: Deploy BeanstalkTrap
echo ">>> Step 4: Deploying BeanstalkTrap..."
TRAP_OUTPUT=$(forge create src/BeanstalkTrap.sol:BeanstalkTrap \
    --rpc-url "$HOODI_RPC" \
    --private-key "$PRIVATE_KEY" \
    --broadcast 2>&1)
RC=$?
echo "$TRAP_OUTPUT"
if [ $RC -ne 0 ]; then echo "STEP 4 FAILED"; exit 1; fi
TRAP_ADDRESS=$(echo "$TRAP_OUTPUT" | grep -oP "Deployed to: \K0x[a-fA-F0-9]{40}")
if [ -z "$TRAP_ADDRESS" ]; then echo "ERROR: Could not parse BeanstalkTrap address"; exit 1; fi
echo "BeanstalkTrap: $TRAP_ADDRESS"
echo ""

# Step 4b: Configure trap
echo ">>> Step 4b: Configuring trap target..."
cast send "$TRAP_ADDRESS" "configure(address)" "$MOCK_ADDRESS" \
    --rpc-url "$HOODI_RPC" \
    --private-key "$PRIVATE_KEY"
echo "Trap target configured."
echo ""

# Step 5: Write drosera.toml
echo ">>> Step 5: Writing drosera.toml..."
cat > drosera.toml << TOMLEOF
[trap]
address = "${TRAP_ADDRESS}"
response_contract = "${VAULT_ADDRESS}"
response_function = "executeResponse(bytes)"
cooldown_period_blocks = 33
block_sample_size = 2
private_trap = true
whitelist = ["${WALLET_ADDRESS}"]
TOMLEOF
echo "drosera.toml written:"
cat drosera.toml
echo ""

# Summary
echo "================================================="
echo "  DEPLOYED ADDRESSES"
echo "================================================="
echo "  BeanstalkMock:     $MOCK_ADDRESS"
echo "  BeanstalkAttacker: $ATTACKER_ADDRESS"
echo "  BeanstalkVault:    $VAULT_ADDRESS"
echo "  BeanstalkTrap:     $TRAP_ADDRESS"
echo "================================================="
echo ""

# Step 6: Register trap with Drosera
echo ">>> Step 6: Registering trap with Drosera (drosera apply)..."
drosera apply
echo "Done."
