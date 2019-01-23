FROM vault:1.0.2

# Our entrypoint uses a backround server, which doesn't use the vault server "-dev" flag
# Therefore we need a basic config for the server to start up.
COPY ./vault/config/ /vault/config

# NOTE: this copies to cci-docker-entrypoint.sh
# Copy the new entrypoint sh along side the one from the base docker image.
# This is because ours calls into the base entrypoint.sh from hashicorp to get things like IPC_LOCK checking.
COPY ./vault/docker-entrypoint.sh /usr/local/bin/cci-docker-entrypoint.sh

ENV VAULT_ADDR=http://127.0.0.1:8200

ENTRYPOINT ["/usr/local/bin/cci-docker-entrypoint.sh"]
