#!/usr/bin/dumb-init /bin/sh
# Use the same dumb-init process that the base hashcorp docker-entrypoint.sh uses.
# This init system helps ensure zombie processes are reaped and subprocess cleanup from vault happens correctly.
# See their comment: https://github.com/hashicorp/docker-vault/blob/0.11.0-beta1/0.X/docker-entrypoint.sh#L1-L7

set -e

# Overview:
# 1) Starts up the vault server using the base script from hashicorp.
# 2) Waits for the vault server then connects and initializes the vault
#     a) inits the vault and sets up the unseal key and root token
#     b) looks at the mounted /vault/init/*.sh (if any) and runs those to setup data
#           (secrets engines, kv secrets, transit keys, policies, tokens, etc)

# Run vault using the hashicorp docker-entrypoint.sh
# This gives us chown and IPC_LOCK validation
vault_server() {
  /usr/local/bin/docker-entrypoint.sh server
}

# ensure all directories are created, for any that haven't been mounted
init_directories() {
  echo "** Ensuring directories exit"
  # directory for init scripts
  mkdir -p /vault/init/
  # directory for the unseal key and root tokens
  mkdir -p /vault/root/
  # directory for output tokens from the scripts
  mkdir -p /vault/tokens/
}

vault_status() {
  vault status 2>&1
}

wait_for_vault() {
  NUM_TRIES=0
  while [ $NUM_TRIES -lt 5 ]; do
    if vault_status | grep -v 'connection refused'; then
      NUM_TRIES=5
      echo "vault ready";
    else
      NUM_TRIES=$((NUM_TRIES + 1))
      sleep 2
    fi
  done

  if vault_status | grep 'connection refused'; then
    exit 27
  fi
}

# Initialize the new vault
init_vault() {
  echo "** Initializing Vault"
  # Configure one key to unseal. This is a dev/test vault, so the unseal doesn't need to be m-of-n.
  vault operator init \
    -key-shares=1 \
    -key-threshold=1 \
    > /vault/root/init.txt 2>&1

  grep 'Unseal' /vault/root/init.txt | sed 's/^.*: //g' | head -n 1 > /vault/root/unseal_key.txt
  grep 'Root' /vault/root/init.txt | sed 's/^.*: //g' > /vault/root/root_token.txt
}

unseal_vault() {
  echo "** Unsealing Vault"
  local unseal_key=$(cat /vault/root/unseal_key.txt)
  vault operator unseal "$unseal_key"
}

login_as_root() {
  echo "** Logging Into Vault"
  # Login to the new vault using the root key for the remaining operations
  local root_token=$(cat /vault/root/root_token.txt)

  # redirect output so we don't log the root key.
  # its a dev server, but still good practice.
  # Mount the /vault/root/ to get the unseal key and root token
  vault login "$root_token" > /dev/null
}

# Load the custom init data script(s)
run_init_scripts() {
  echo "** Running Init Scripts"
  if [ -e "/vault/init" ]; then
    # change dir so that references to policy.hcl files can be relative to the init path
    (cd /vault/init
     for file in *.sh; do
       echo "Running /vault/init/$file"
       source "$file"
     done)
  else
    echo "  No init scripts found"
  fi
}

setup_vault() {
  init_directories
  wait_for_vault
  init_vault
  unseal_vault
  login_as_root
  run_init_scripts
}

##################################################
# These are helper functions for the init scripts

# Parse the standard output of "vault token create" to get just the token
# Usage: "vault token create [OPTIONS] | parse_vault_token > token_file.txt"
parse_vault_token() {
   grep '^token\s' | sed -e 's/^token[[:space:]]*//'
}

# Contains the best practices for vault token creation (no "default" policy and one policy)
# Usage "create_vault_token foo-service-policy > foo_service_token.txt
create_vault_token() {
  vault token create -no-default-policy -policy=$1 | parse_vault_token
}
##################################################

# Actually run the server & setup.
# The order here is a bit weird to look at, but it is essential.
# "setup_vault &" to run it in the background, but "vault_server" is run as the foreground task.
# The wait_for_vault handles waiting for vault to startup.
# If we ran vault_server in the background, the script ends and the container dies.
# We want the container to run as long as the vault server is up.
setup_vault & vault_server
