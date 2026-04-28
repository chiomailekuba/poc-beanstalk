#!/bin/bash
set -e

WALLET_ADDRESS="0xc93bf33438c9c636fc49cafe1086c2c424507a15"
PROJECT_DIR="/mnt/c/Users/ndohj/2026/drosera-beanstalk-trap"
HOLESKY_RPC="${RPC_URL:-https://holesky.drpc.org}"

export PATH="$HOME/.foundry/bin:$HOME/.drosera/bin:$PATH"

echo ""
echo "================================================="
echo "  Beanstalk Governance Trap — Holesky Deployment"
echo "================================================="
echo ""

# ── Pre-flight checks ────────────────────────────────────────────────────────
if [ -z "$PRIVATE_KEY" ]; then
    echo "ERROR: PRIVATE_KEY environment variable not set."
    echo "  export PRIVATE_KEY=0x..."
    exit 1
fi
echo "PRIVATE_KEY is set."
echo "RPC: $HOLESKY_RPC"
echo ""

cd "$PROJECT_DIR"

# ── Build ────────────────────────────────────────────────────────────────────
echo ">>> Building contracts..."
forge build 2>&1
echo ""

# ── Step 1: Deploy BeanstalkMock ─────────────────────────────────────────────
echo ">>> Step 1: Deploying BeanstalkMock..."
MOCK_OUTPUT=$(forge create src/BeanstalkMock.sol:BeanstalkMock \
    --rpc-url "$HOLESKY_RPC" \
    --private-key "$PRIVATE_KEY" \
    --broadcast 2>&1) || { echo "FAILED!"; echo "$MOCK_OUTPUT"; exit 1; }
echo "$MOCK_OUTPUT"
MOCK_ADDRESS=$(echo "$MOCK_OUTPUT" | grep -oP "Deployed to: \K0x[a-fA-F0-9]{40}")
if [ -z "$MOCK_ADDRESS" ]; then echo "ERROR: Could not parse BeanstalkMock address"; exit 1; fi
echo "BeanstalkMock: $MOCK_ADDRESS"
echo ""

# ── Step 2: Deploy BeanstalkAttacker ────────────────────────────────────────
echo ">>> Step 2: Deploying BeanstalkAttacker..."
ATTACKER_OUTPUT=$(forge create src/BeanstalkAttacker.sol:BeanstalkAttacker \
    --rpc-url "$HOLESKY_RPC" \
    --private-key "$PRIVATE_KEY" \
    --constructor-args "$MOCK_ADDRESS" \
    --broadcast 2>&1) || { echo "FAILED!"; echo "$ATTACKER_OUTPUT"; exit 1; }
echo "$ATTACKER_OUTPUT"
ATTACKER_ADDRESS=$(echo "$ATTACKER_OUTPUT" | grep -oP "Deployed to: \K0x[a-fA-F0-9]{40}")
if [ -z "$ATTACKER_ADDRESS" ]; then echo "ERROR: Could not parse BeanstalkAttacker address"; exit 1; fi
echo "BeanstalkAttacker: $ATTACKER_ADDRESS"
echo ""

# ── Step 3: Deploy BeanstalkVault ────────────────────────────────────────────
echo ">>> Step 3: Deploying BeanstalkVault..."
VAULT_OUTPUT=$(forge create src/BeanstalkVault.sol:BeanstalkVault \
    --rpc-url "$HOLESKY_RPC" \
    --private-key "$PRIVATE_KEY" \
    --constructor-args "$MOCK_ADDRESS" \
    --broadcast 2>&1) || { echo "FAILED!"; echo "$VAULT_OUTPUT"; exit 1; }
echo "$VAULT_OUTPUT"
VAULT_ADDRESS=$(echo "$VAULT_OUTPUT" | grep -oP "Deployed to: \K0x[a-fA-F0-9]{40}")
if [ -z "$VAULT_ADDRESS" ]; then echo "ERROR: Could not parse BeanstalkVault address"; exit 1; fi
echo "BeanstalkVault: $VAULT_ADDRESS"
echo ""

# ── Step 4: Deploy BeanstalkTrap ─────────────────────────────────────────────
echo ">>> Step 4: Deploying BeanstalkTrap..."
TRAP_OUTPUT=$(forge create src/BeanstalkTrap.sol:BeanstalkTrap \
    --rpc-url "$HOLESKY_RPC" \
    --private-key "$PRIVATE_KEY" \
    --constructor-args "$MOCK_ADDRESS" "$ATTACKER_ADDRESS" \
    --broadcast 2>&1) || { echo "FAILED!"; echo "$TRAP_OUTPUT"; exit 1; }
echo "$TRAP_OUTPUT"
TRAP_ADDRESS=$(echo "$TRAP_OUTPUT" | grep -oP "Deployed to: \K0x[a-fA-F0-9]{40}")
if [ -z "$TRAP_ADDRESS" ]; then echo "ERROR: Could not parse BeanstalkTrap address"; exit 1; fi
echo "BeanstalkTrap: $TRAP_ADDRESS"
echo ""

# ── Step 5: Write drosera.toml ───────────────────────────────────────────────
echo ">>> Step 5: Writing drosera.toml..."
cat > drosera.toml <<EOF
[trap]
address = "${TRAP_ADDRESS}"
response_contract = "${VAULT_ADDRESS}"
response_function = "executeResponse(bytes)"
cooldown_period_blocks = 33
block_sample_size = 1
private_trap = true
whitelist = ["${WALLET_ADDRESS}"]
EOF
echo "drosera.toml written."
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "================================================="
echo "  ALL CONTRACTS DEPLOYED ON HOLESKY"
echo "================================================="
echo "  BeanstalkMock:     $MOCK_ADDRESS"
echo "  BeanstalkAttacker: $ATTACKER_ADDRESS"
echo "  BeanstalkVault:    $VAULT_ADDRESS"
echo "  BeanstalkTrap:     $TRAP_ADDRESS"
echo "================================================="
echo ""
echo "NEXT — register the Trap with Drosera:"
echo "  drosera apply"
echo ""
