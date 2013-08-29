#!/bin/bash
. `cd -P -- "$(dirname $0)" && pwd -P`/init.sh
bench=$1
postfix=${2-}
load_conf "$bench"
export PREFIX=$PREFIX$postfix

function on_err() {
    figlet "ERROR" >&2
    echo "ERROR $0:$1" >&2
    echo "WTF is this error?  Do you even bench?" >&2
}
trap 'on_err $LINENO' ERR

################################################################################
##### Set up hosts.
################################################################################
{
    echo `provision servers $SERVERS` > server_hosts
    export POC=`head -1 server_hosts`
    init_rdb_cluster "`cat server_hosts`" \
        $SERVER_INSTANCES $bench/server $SERVER_STAGING "$SERVER_OPTS" &
    wait
} &
server_hosts_ready=$!
{
    echo `provision clients $CLIENTS` > client_hosts &
#    parallel -uj0 reset_client :::: client_hosts
} &
client_hosts_ready=$!
wait
cat >&2 <<EOF
  Servers:
`<server_hosts awk '{print "    "$0}'`
  Clients:
`<client_hosts awk '{print "    "$0}'`
EOF
exit 0

################################################################################
##### Set up RethinkDB cluster.
################################################################################
init_rdb_cluster "`cat server_hosts`" \
    $SERVER_INSTANCES $RETHINKDB_DIR $STAGING "$SERVER_OPTS" &
export POC=`head -1 server_hosts`
tunnel_to_poc $POC 1 >cluster_port
export ADMIN_CLUSTER_PORT=`cat cluster_port`
if [[ $TABLES -gt 0 ]]; then
    for i in `seq $TABLES`; do cat /proc/sys/kernel/random/uuid | tr - _; done >tables
    wait
    parallel -uj0 create_table $POC 1 $STAGING {} $TABLE_SHARDS "'$TABLE_CONF'" \
        :::: tables &
fi

################################################################################
##### Set up clients.
################################################################################
tables=`cat tables`
node_pairs=":::: server_hosts ::: `seq $SERVER_INSTANCES`"
nodes=`parallel -uj0 echo '{1}:$((CLIENT_PORT+{2}))' $node_pairs`
parallel -uj0 dist_bench "$bench" {} $STAGING "'$tables'" "'$nodes'" :::: client_hosts

################################################################################
##### Run Benchmark.
################################################################################
wait
run_at=$((`date +%s`+${RUN_AT_SLEEP-10}))
echo "Running $bench at `date --date=@$run_at` ($run_at)..." >&2
rm -f raw raw.map
stats_pid=`bash -c 'set -m; set -e; nohup poll_stats '"$POC"' 1 >/dev/null 2>/dev/null & echo $!'`
bench="run_bench {} $STAGING $run_at | tee -a raw | ${CLIENT_MAP-cat}"
parallel -j0 $bench :::: client_hosts \
    | tee raw.map | eval ${CLIENT_REDUCE-cat} | tee -a runs.t
bash -c "set -m; set -e; nohup kill $stats_pid >/dev/null 2>/dev/null &"
wait
