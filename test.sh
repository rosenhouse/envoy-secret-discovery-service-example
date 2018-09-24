#!/bin/bash

set -euo pipefail

docker pull envoyproxy/envoy
docker pull citizenstig/httpbin
docker pull byrnedo/alpine-curl
docker pull istio/pilot:1.0.2

container_subnet="10.255.217.0/24"
app_container_ip="10.255.217.83"
pilot_ip="10.255.217.2"
network_name="envoy-test-net"

# set up custom network, so that diego cert and config works
docker network rm $network_name || true
docker network create -d bridge --subnet=$container_subnet $network_name

echo launching pilot
docker run -d --rm -it --name pilot \
  --network $network_name --ip $pilot_ip \
  istio/pilot:1.0.2 \
    discovery --configDir /dev/null --meshConfig /dev/null --registries Mock

echo launching app, listening on port 8080
docker run -d --rm -it --name app_container \
  --network $network_name --ip $app_container_ip \
  citizenstig/httpbin \
  gunicorn --bind=$app_container_ip:8080 httpbin:app

echo launching envoy proxy in same net namespace as app
docker run -d --rm -it --name sidecar_proxy \
  --network=container:app_container \
  -it -v $PWD/envoy_config:/etc/cf-assets/envoy_config \
  envoyproxy/envoy \
    envoy -c /etc/cf-assets/envoy_config/envoy.yaml \
     --v2-config-only \
     --service-cluster proxy-cluster --service-node "sidecar~$app_container_ip~x~x" \
     --drain-time-s 10 --log-level info

echo waiting for proxy and app to boot
sleep 5

echo client does an HTTPS request via the proxy
docker run --rm --name client \
  --network=$network_name \
  -v $PWD/certs:/certs \
  byrnedo/alpine-curl \
    --cacert certs/ca.crt \
    --key certs/gorouter_client.key \
    --cert certs/gorouter_client.crt \
    -sv \
    https://$app_container_ip:61001 > /dev/null

echo success

docker logs sidecar_proxy
read -p "Press enter to continue"

docker rm -f sidecar_proxy
docker rm -f app_container
docker rm -f pilot
