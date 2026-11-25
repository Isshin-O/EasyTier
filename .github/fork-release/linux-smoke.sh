#!/usr/bin/env bash
# Fork only: multi-node smoke test of one EasyTier Docker image, run by
# Fork Release Check before Fork Promote may ship it.
#
#   sudo .github/fork-release/linux-smoke.sh <image> [expected-version-substring]
#
# Topology (all containers run the image under test, except where noted):
#
#   wan 10.200.0.0/24, 2001:db8:200::/64 (the "internet")
#     a     .10  public node, initial peer of everyone, dual-stack listeners
#     stun  .11  second STUN responder (EasyTier UDP listeners answer STUN)
#     rb    .21  NAT router for lanb      rc  .31  NAT router for lanc
#     e     .40  joins a over IPv6 only
#     web   .50  easytier-web-embed       w   .51  managed by web
#     p     .60  public IPv6 provider     u   .70  plain IPv6 host (not EasyTier)
#     d     .80  has its only initial peer disabled
#   lanb 10.201.0.0/24: b .10 behind rb    lanc 10.202.0.0/24: c .10, k .11 behind rc
#
# Environment:
#   SMOKE_IPV6=0          skip the IPv6 cases (for kernels without IPv6)
#   SMOKE_SOAK_SECONDS    length of the final stability phase (default 180)
#   SMOKE_LOG_DIR         where container logs go (default smoke-logs)
#   SMOKE_SUMMARY         markdown summary file (default $GITHUB_STEP_SUMMARY)

# Word splitting of the docker flag helpers below is intended.
# shellcheck disable=SC2046,SC2086
set -uo pipefail

IMG=${1:?usage: linux-smoke.sh <image> [expected-version-substring]}
EXPECT_VERSION=${2:-}
IPV6=${SMOKE_IPV6:-1}
SOAK=${SMOKE_SOAK_SECONDS:-180}
LOGDIR=${SMOKE_LOG_DIR:-smoke-logs}
SUMMARY=${SMOKE_SUMMARY:-${GITHUB_STEP_SUMMARY:-/dev/null}}
P=etsmoke
NET=smoke
SECRET=smoke-$RANDOM$RANDOM
A4=10.200.0.10
A6=2001:db8:200::10
STUN="--stun-servers $A4:11010,10.200.0.11:3478"
# Nodes must not reach the real internet's STUN servers or public peers.
COMMON="--network-name $NET --network-secret $SECRET $STUN --console-log-level info"
WEB_API=http://10.200.0.50:11211/api/v1
W_MACHINE=5eeded00-0000-4000-8000-000000000051
W_INST=5eeded00-0000-4000-8000-0000000000a1

declare -a RESULTS=()
FAILED=0


log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
ok() { log "  ok: $*"; }
bad() { log "  FAIL: $*"; CURRENT_FAILED=1; }

# run_case <title> <function>: a failing case is recorded and the rest still run.
run_case() {
  local title=$1 fn=$2 start=$SECONDS
  log "== $title"
  CURRENT_FAILED=0
  "$fn"
  local secs=$((SECONDS - start))
  if [ "$CURRENT_FAILED" = 0 ]; then
    RESULTS+=("| $title | ✅ | ${secs}s |")
  else
    RESULTS+=("| $title | ❌ | ${secs}s |")
    FAILED=1
  fi
}

skip_case() { RESULTS+=("| $1 | ⏭️ $2 | - |"); log "== $1: skipped ($2)"; }

# wait_for <seconds> <description> <command...>
wait_for() {
  local timeout=$1 what=$2 deadline=$((SECONDS + $1))
  shift 2
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then bad "$what (not within ${timeout}s)"; return 1; fi
    sleep 2
  done
  ok "$what"
}

x() { docker exec "$P-$1" "${@:2}"; }
cli() { docker exec "$P-$1" easytier-cli -o json "${@:2}"; }
ping_ok() { x "$1" ping -c 1 -W 2 "$2"; }
ping6_ok() { x "$1" ping -6 -c 1 -W 2 "$2"; }
peer_cost() { cli "$1" peer | jq -r --arg ip "$2" '.[] | select(.ipv4 == $ip) | .cost'; }
is_p2p() { [ "$(peer_cost "$1" "$2")" = p2p ]; }
connector_count() { cli "$1" connector | jq length; }

# loss_of <node> <ping args...>: prints the packet loss percentage.
loss_of() {
  x "$1" ping -q "${@:2}" 2>&1 | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p'
}

cleanup() {
  mkdir -p "$LOGDIR"
  for c in $(docker ps -a --filter "name=^$P-" --format '{{.Names}}'); do
    docker logs "$c" > "$LOGDIR/$c.log" 2>&1 || true
    docker inspect "$c" > "$LOGDIR/$c.inspect.json" 2>&1 || true
  done
  docker ps -a --filter "name=^$P-" -q | xargs -r docker rm -f >/dev/null
  for n in wan lanb lanc; do docker network rm "$P-$n" >/dev/null 2>&1 || true; done
}

write_summary() {
  {
    echo "### Linux smoke test ($(uname -m))"
    echo
    echo "Image: \`$IMG\`"
    echo
    echo "| Case | Result | Time |"
    echo "|---|---|---|"
    printf '%s\n' "${RESULTS[@]}"
    echo
  } >> "$SUMMARY"
  printf '%s\n' "${RESULTS[@]}"
}

finish() {
  cleanup
  rm -f "$WEB_COOKIES"
  write_summary
  if [ "$FAILED" = 0 ]; then log "All cases passed."; else log "Some cases failed; logs are in $LOGDIR."; fi
}
trap finish EXIT

# ---------------------------------------------------------------- setup

setup() {
  # Bridged frames must not go through the host firewall, or Docker's
  # isolation rules drop the traffic our router containers forward.
  sysctl -qw net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
  sysctl -qw net.bridge.bridge-nf-call-ip6tables=0 2>/dev/null || true
  modprobe tun 2>/dev/null || true

  cleanup >/dev/null 2>&1
  rm -rf "$LOGDIR"
  if [ "$IPV6" = 1 ]; then
    docker network create --ipv6 --subnet 10.200.0.0/24 --subnet 2001:db8:200::/64 "$P-wan" >/dev/null
  else
    docker network create --subnet 10.200.0.0/24 "$P-wan" >/dev/null
  fi
  docker network create --subnet 10.201.0.0/24 "$P-lanb" >/dev/null
  docker network create --subnet 10.202.0.0/24 "$P-lanc" >/dev/null
}

# wan_addr <last-octet>: docker run flags for a fixed wan address.
wan_addr() {
  local f="--network $P-wan --ip 10.200.0.$1"
  [ "$IPV6" = 1 ] && f="$f --ip6 2001:db8:200::$1"
  echo "$f"
}

v6_sysctl() { [ "$IPV6" = 1 ] && echo "--sysctl net.ipv6.conf.all.disable_ipv6=0"; }

TUN="--cap-add NET_ADMIN --device /dev/net/tun"

# router <name> <lan> <lan-ip> <wan-octet>: a home router with masquerade
# and a firewall that drops unsolicited inbound traffic.
router() {
  docker run -d --name "$P-$1" $(wan_addr "$4") --cap-add NET_ADMIN \
    --sysctl net.ipv4.ip_forward=1 --entrypoint sleep "$IMG" infinity >/dev/null
  docker network connect --ip "$3" "$P-$2" "$P-$1"
  local pid wan_if
  pid=$(docker inspect -f '{{.State.Pid}}' "$P-$1")
  wan_if=$(x "$1" ip -o -4 addr show | awk -v ip="10.200.0.$4" 'index($4, ip "/") == 1 {print $2}')
  nsenter -t "$pid" -n iptables -t nat -A POSTROUTING -o "$wan_if" -j MASQUERADE
  # Dropping in INPUT also keeps early punch packets from claiming the
  # conntrack tuple that the outgoing mapping needs.
  nsenter -t "$pid" -n iptables -A INPUT -i "$wan_if" -m conntrack --ctstate NEW -j DROP
  nsenter -t "$pid" -n iptables -A FORWARD -i "$wan_if" -m conntrack --ctstate NEW -j DROP
}

# lan_node <name> <lan> <ip> <gateway> <easytier args...>
lan_node() {
  local name=$1 lan=$2 ip=$3 gw=$4
  shift 4
  docker run -d --name "$P-$name" --network "$P-$lan" --ip "$ip" $TUN $(v6_sysctl) \
    --entrypoint sh "$IMG" -c "ip route replace default via $gw && exec easytier-core $*" >/dev/null
}

start_core_nodes() {
  docker run -d --name "$P-stun" $(wan_addr 11) "$IMG" \
    --network-name stun-only --network-secret x --no-tun -l udp://0.0.0.0:3478 --stun-servers '' >/dev/null

  local a_listeners="-l tcp://0.0.0.0:11010 -l udp://0.0.0.0:11010"
  [ "$IPV6" = 1 ] && a_listeners="$a_listeners -l tcp://[::]:11010 -l udp://[::]:11010"
  local a_v6=""
  [ "$IPV6" = 1 ] && a_v6="--ipv6 fd00:144::1/64"
  docker run -d --name "$P-a" $(wan_addr 10) $TUN $(v6_sysctl) "$IMG" \
    $COMMON --hostname smoke-a -i 10.144.0.1 $a_v6 $a_listeners >/dev/null

  router rb lanb 10.201.0.2 21
  router rc lanc 10.202.0.2 31

  local b_v6="" c_v6=""
  [ "$IPV6" = 1 ] && b_v6="--ipv6 fd00:144::2/64" && c_v6="--ipv6 fd00:144::3/64"
  lan_node b lanb 10.201.0.10 10.201.0.2 $COMMON --hostname smoke-b -i 10.144.0.2 $b_v6 -p tcp://$A4:11010
  lan_node c lanc 10.202.0.10 10.202.0.2 $COMMON --hostname smoke-c -i 10.144.0.3 $c_v6 -p tcp://$A4:11010
}

# ---------------------------------------------------------------- cases

case_version() {
  local v
  v=$(docker run --rm "$IMG" --version 2>&1)
  log "  $v"
  case "$v" in
    easytier-core*) ok "easytier-core starts" ;;
    *) bad "unexpected --version output: $v" ;;
  esac
  if [ -n "$EXPECT_VERSION" ]; then
    case "$v" in *"$EXPECT_VERSION"*) ok "version contains $EXPECT_VERSION" ;;
      *) bad "version does not contain $EXPECT_VERSION" ;; esac
  fi
  for bin in easytier-cli easytier-web-embed; do
    if docker run --rm --entrypoint "$bin" "$IMG" --version >/dev/null 2>&1; then ok "$bin starts"
    else bad "$bin does not start"; fi
  done
}

case_relay() {
  wait_for 60 "b joined a" ping_ok b 10.144.0.1
  wait_for 60 "c joined a" ping_ok c 10.144.0.1
  wait_for 60 "b reaches c" ping_ok b 10.144.0.3
}

case_p2p() {
  # Both sides are behind port-restricted NATs, so this needs UDP hole punching.
  wait_for 180 "b and c connect directly (hole punched)" is_p2p b 10.144.0.3
  log "  b sees: $(cli b peer | jq -c '[.[] | {ipv4, cost, tunnel_proto, nat_type}]')"
}

case_relay_down() {
  docker pause "$P-a" >/dev/null
  local loss
  loss=$(loss_of b -c 30 -i 0.5 -W 2 10.144.0.3)
  if [ -n "$loss" ] && awk "BEGIN {exit !($loss <= 10)}"; then ok "b reaches c with a paused (loss $loss%)"
  else bad "b cannot reach c with a paused (loss ${loss:-?}%)"; fi
  docker unpause "$P-a" >/dev/null
  wait_for 90 "b reaches a again after it comes back" ping_ok b 10.144.0.1
}

case_ipv6_overlay() {
  wait_for 60 "b reaches c over overlay IPv6" ping6_ok b fd00:144::3
  wait_for 60 "b reaches a over overlay IPv6" ping6_ok b fd00:144::1
}

case_ipv6_underlay() {
  docker run -d --name "$P-e" $(wan_addr 40) $TUN $(v6_sysctl) "$IMG" \
    $COMMON --hostname smoke-e -i 10.144.0.40 --no-listener -p "tcp://[$A6]:11010" >/dev/null
  wait_for 60 "e joins a over an IPv6 underlay" ping_ok e 10.144.0.1
  local url
  url=$(cli e connector | jq -r '.[0].url.url')
  case "$url" in *"[$A6]"*) ok "connector uses $url" ;; *) bad "unexpected connector $url" ;; esac
}

k_lease() {
  x k ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | grep '^2001:db8:200:' | head -n 1 | cut -d/ -f1
}

has_k_lease() { [ -n "$(k_lease)" ]; }

case_ipv6_provider() {
  # p shares the wan /64 (on-link, like a single /64 from an ISP) and must
  # answer neighbour solicitations for k's lease on the wan (NDP proxy).
  # eth0 starts with accept_ra=1: the provider has to move it to 2 before
  # it enables forwarding, or the kernel would drop RA-learned routes.
  docker run -d --name "$P-p" $(wan_addr 60) --privileged --entrypoint sh "$IMG" -c \
    "echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6 && echo 1 > /proc/sys/net/ipv6/conf/eth0/accept_ra && \
     exec easytier-core $COMMON --hostname smoke-p -i 10.144.0.60 -p tcp://$A4:11010 \
       --ipv6-public-addr-provider --ipv6-public-addr-prefix 2001:db8:200::/64" >/dev/null
  lan_node k lanc 10.202.0.11 10.202.0.2 $COMMON --hostname smoke-k -i 10.144.0.61 \
    -p tcp://$A4:11010 --ipv6-public-addr-auto
  docker run -d --name "$P-u" $(wan_addr 70) $(v6_sysctl) --entrypoint sleep "$IMG" infinity >/dev/null

  wait_for 120 "k gets a public IPv6 lease from p" has_k_lease || return
  K6=$(k_lease)
  log "  k lease: $K6"

  local v
  v=$(x p cat /proc/sys/net/ipv6/conf/all/forwarding); [ "$v" = 1 ] && ok "p: all/forwarding=1" || bad "p: all/forwarding=$v"
  v=$(x p cat /proc/sys/net/ipv6/conf/all/proxy_ndp); [ "$v" = 1 ] && ok "p: all/proxy_ndp=1" || bad "p: all/proxy_ndp=$v"
  v=$(x p cat /proc/sys/net/ipv6/conf/eth0/accept_ra); [ "$v" = 2 ] && ok "p: eth0 accept_ra 1 -> 2" || bad "p: eth0 accept_ra=$v (expected 2)"
  if x p ip -6 route show default | grep -q .; then ok "p keeps its IPv6 default route"
  else bad "p lost its IPv6 default route"; fi

  wait_for 60 "plain wan host u reaches k's lease via NDP proxy" ping6_ok u "$K6"
}

write_d_config() {
  mkdir -p "$1"
  cat > "$1/config.toml" <<EOF
hostname = "smoke-d"
ipv4 = "10.144.0.80"
listeners = []

[network_identity]
network_name = "$NET"
network_secret = "$SECRET"

[[peer]]
uri = "tcp://$A4:11010"
enabled = $2
EOF
  chmod -R a+rX "$1"
}

case_disabled_peer() {
  local dir
  dir=$(mktemp -d)
  write_d_config "$dir" false
  docker run -d --name "$P-d" $(wan_addr 80) $TUN -v "$dir:/cfg:ro" "$IMG" -c /cfg/config.toml $STUN >/dev/null
  wait_for 30 "d is running" x d easytier-cli node || return
  sleep 20
  local n
  n=$(connector_count d)
  [ "$n" = 0 ] && ok "d does not dial its disabled peer" || bad "d has $n connector(s) for a disabled peer"
  if ping_ok d 10.144.0.1 >/dev/null 2>&1; then bad "d reached a through a disabled peer"; else ok "d stays offline"; fi
  docker rm -f "$P-d" >/dev/null

  # The same config with the peer enabled must connect, so the case above
  # passed because of the flag and not because the config was broken.
  write_d_config "$dir" true
  docker run -d --name "$P-d" $(wan_addr 80) $TUN -v "$dir:/cfg:ro" "$IMG" -c /cfg/config.toml $STUN >/dev/null
  wait_for 60 "d joins a once the peer is enabled" ping_ok d 10.144.0.1
}

WEB_COOKIES=$(mktemp)
web() { # web <method> <path> [json]; the host reaches the wan bridge directly.
  curl -sS -f -b "$WEB_COOKIES" -c "$WEB_COOKIES" -H 'content-type: application/json' \
    -X "$1" "$WEB_API$2" ${3:+-d "$3"}
}

w_network_json() { # w_network_json <peer-enabled>
  local urls='[]'
  [ "$1" = true ] && urls="[\"tcp://$A4:11010\"]"
  echo "{\"instance_id\":\"$W_INST\",\"network_name\":\"$NET\",\"network_secret\":\"$SECRET\",\"virtual_ipv4\":\"10.144.0.51\",\"network_length\":24,\"networking_method\":1,\"peer_urls\":$urls,\"peers\":[{\"uri\":\"tcp://$A4:11010\",\"enabled\":$1}],\"listener_urls\":[]}"
}

# The API returns instance IDs as four u32 parts and leaves out zero parts.
W_PARTS=$(h=${W_INST//-/}; printf '[%d,%d,%d,%d]' "0x${h:0:8}" "0x${h:8:8}" "0x${h:16:8}" "0x${h:24:8}")
w_state() { # prints running / disabled / missing
  web GET "/machines/$W_MACHINE/networks" | jq -r --argjson want "$W_PARTS" '
    def parts: [.part1, .part2, .part3, .part4] | map(. // 0);
    if any(.running_inst_ids[]?; parts == $want) then "running"
    elif any(.disabled_inst_ids[]?; parts == $want) then "disabled" else "missing" end'
}
w_is() { [ "$(w_state)" = "$1" ]; }
w_online() { web GET /machines | jq -e '.machines[] | select(.info.hostname == "smoke-w" and .online)'; }

case_web() {
  docker run -d --name "$P-web" $(wan_addr 50) --entrypoint easytier-web-embed "$IMG" -d /tmp/et.db >/dev/null
  docker run -d --name "$P-w" $(wan_addr 51) $TUN "$IMG" \
    -w udp://10.200.0.50:22020/admin --machine-id "$W_MACHINE" --hostname smoke-w $STUN >/dev/null

  local md5
  md5=$(printf admin | md5sum | cut -d' ' -f1)
  wait_for 60 "web console accepts the default admin login" \
    web POST /auth/login "{\"username\":\"admin\",\"password\":\"$md5\"}" || return
  wait_for 60 "w shows up online in the console" \
    w_online || return

  web POST "/machines/$W_MACHINE/networks" "{\"save\":true,\"config\":$(w_network_json true)}" >/dev/null \
    && ok "console creates a network on w" || bad "console could not create a network on w"
  wait_for 60 "w joins the network" ping_ok w 10.144.0.1

  # Pausing from the console stops the network but keeps it on the device.
  web PUT "/machines/$W_MACHINE/networks/$W_INST" '{"disabled":true}' >/dev/null
  wait_for 30 "pause from the console keeps the network as disabled" w_is disabled
  wait_for 30 "the paused network is down on w" sh -c "! docker exec $P-w ping -c 1 -W 1 10.144.0.1"
  web PUT "/machines/$W_MACHINE/networks/$W_INST" '{"disabled":false}' >/dev/null
  wait_for 30 "resume from the console runs it again" w_is running
  wait_for 60 "w is back in the network" ping_ok w 10.144.0.1

  # Disabling the only initial peer in the console must keep w from dialling it.
  web PUT "/machines/$W_MACHINE/networks/config/$W_INST" "{\"config\":$(w_network_json false)}" >/dev/null \
    && ok "console saves a config with the peer disabled" || bad "console could not save the config"
  web PUT "/machines/$W_MACHINE/networks/$W_INST" '{"disabled":false}' >/dev/null
  wait_for 30 "w runs the saved config" w_is running || return
  sleep 15
  local n
  n=$(connector_count w)
  [ "$n" = 0 ] && ok "w does not dial the disabled peer" || bad "w has $n connector(s) for a disabled peer"
  local cfg
  cfg=$(web GET "/machines/$W_MACHINE/networks/config/$W_INST")
  if echo "$cfg" | jq -e '.peers[0].enabled == false' >/dev/null; then ok "console reads back the disabled peer"
  else bad "console lost the disabled flag: $(echo "$cfg" | jq -c .peers)"; fi

  # Turn the peer back on so w takes part in the stability phase.
  web PUT "/machines/$W_MACHINE/networks/config/$W_INST" "{\"config\":$(w_network_json true)}" >/dev/null
  web PUT "/machines/$W_MACHINE/networks/$W_INST" '{"disabled":false}' >/dev/null
  wait_for 60 "w rejoins once the peer is enabled again" ping_ok w 10.144.0.1
}

case_soak() {
  local pids=() names=() f
  local count=$((SOAK * 2))
  local tmp
  tmp=$(mktemp -d)
  soak_ping() { # soak_ping <label> <node> <ping args...>
    local label=$1
    shift
    ( loss_of "$@" > "$tmp/$label" ) &
    pids+=($!)
    names+=("$label")
  }
  soak_ping "b-c-p2p" b -c "$count" -i 0.5 -W 2 10.144.0.3
  soak_ping "b-a" b -c "$count" -i 0.5 -W 2 10.144.0.1
  soak_ping "w-a-web" w -c "$count" -i 0.5 -W 2 10.144.0.1
  if [ "$IPV6" = 1 ]; then
    soak_ping "c-b-ipv6" c -6 -c "$count" -i 0.5 -W 2 fd00:144::2
    soak_ping "e-a-v6-underlay" e -c "$count" -i 0.5 -W 2 10.144.0.1
    [ -n "${K6:-}" ] && soak_ping "u-k-ndp-proxy" u -6 -c "$count" -i 0.5 -W 2 "$K6"
  fi
  log "  pinging for ${SOAK}s: ${names[*]}"
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}"
    f=$(cat "$tmp/${names[$i]}")
    if [ -n "$f" ] && awk "BEGIN {exit !($f <= 2)}"; then ok "${names[$i]}: loss $f%"
    else bad "${names[$i]}: loss ${f:-?}% (limit 2%)"; fi
  done

  if is_p2p b 10.144.0.3; then ok "b and c are still direct"; else bad "b and c fell back to relay"; fi

  # Every EasyTier container is still up, was not restarted and did not panic.
  for c in $(docker ps -a --filter "name=^$P-" --format '{{.Names}}'); do
    local state
    state=$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$c")
    [ "$state" = "running 0" ] || bad "$c: $state"
    if docker logs "$c" 2>&1 | grep -q 'panicked at'; then bad "$c panicked"; fi
  done
  # The image's HEALTHCHECK has run a few times by now.
  local h
  for n in a b c; do
    h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$P-$n")
    [ "$h" = healthy ] && ok "$n: docker health $h" || bad "$n: docker health ${h:-none}"
  done
}

# ---------------------------------------------------------------- main

log "Image: $IMG"
docker pull -q "$IMG" >/dev/null 2>&1 || true
docker image inspect "$IMG" >/dev/null || { echo "Image $IMG is not available." >&2; exit 1; }
setup
run_case "Binaries start, version matches" case_version
start_core_nodes
run_case "Relay through the public node" case_relay
run_case "P2P between two NATed nodes" case_p2p
run_case "P2P keeps working with the relay down" case_relay_down
if [ "$IPV6" = 1 ]; then
  run_case "IPv6 inside the overlay" case_ipv6_overlay
  run_case "IPv6 underlay connection" case_ipv6_underlay
  run_case "Public IPv6 provider: lease, NDP proxy, accept_ra" case_ipv6_provider
else
  for t in "IPv6 inside the overlay" "IPv6 underlay connection" "Public IPv6 provider: lease, NDP proxy, accept_ra"; do
    skip_case "$t" "SMOKE_IPV6=0"
  done
fi
run_case "Disabled initial peer is not dialled" case_disabled_peer
run_case "Web console: create, pause, resume, disable peer" case_web
run_case "Stability for ${SOAK}s" case_soak
exit "$FAILED"
