# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The relay server as a small container image: an AOT-compiled binary on an empty base image.
# Build from the repository root, because the server uses the protocol package beside it:
#   docker build -f server/Dockerfile -t vroo-relay .
#   docker run -d --restart unless-stopped -p 47100:47100/udp --name vroo-relay vroo-relay
FROM dart:3.13.7 AS build
WORKDIR /src
COPY packages/vroo_protocol packages/vroo_protocol
COPY server server
WORKDIR /src/server
RUN dart pub get && dart compile exe bin/vroo_relay.dart -o /out/vroo_relay

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out/vroo_relay /vroo_relay
EXPOSE 47100/udp
ENTRYPOINT ["/vroo_relay"]
