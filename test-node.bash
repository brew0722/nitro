#!/usr/bin/env bash

set -e

mydir=`dirname $0`
cd "$mydir"

if ! which docker-compose > /dev/null; then
    echo == Error! docker-compose not installed
    echo please install docker-compose and have it in PATH
    echo see https://docs.docker.com/compose/install/
    exit 1
fi

if [[ $# -gt 0 ]] && [[ $1 == "script" ]]; then
    shift
    docker-compose run testnode-scripts "$@"
    exit $?
fi

num_volumes=`docker volume ls --filter label=com.docker.compose.project=nitro -q | wc -l`

if [[ $num_volumes -eq 0 ]]; then
    force_init=true
else
    force_init=false
fi

run=true
force_build=false
validate=false
detach=false
blockscout=true
tokenbridge=true
redundantsequencers=0
batchposters=1
devprivkey=e887f7d17d07cc7b8004053fb8826f6657084e88904bb61590e498ca04704cf2
while [[ $# -gt 0 ]]; do
    case $1 in
        --init)
            if ! $force_init; then
                echo == Warning! this will remove all previous data
                read -p "are you sure? [y/n]" -n 1 response
                if [[ $response == "y" ]] || [[ $response == "Y" ]]; then
                    force_init=true
                    echo
                else
                    exit 0
                fi
            fi
            shift
            ;;
        --build)
            force_build=true
            shift
            ;;
        --validate)
            validate=true
            shift
            ;;
        --no-blockscout)
            blockscout=false
            shift
            ;;
        --no-tokenbridge)
            tokenbridge=false
            shift
            ;;
        --no-run)
            run=false
            shift
            ;;
        --detach)
            detach=true
            shift
            ;;
        --batchposters)
            batchposters=$2
            if ! [[ $batchposters =~ [0-3] ]] ; then
                echo "batchposters must be between 0 and 3 value:$batchposters."
                exit 1
            fi
            shift
            shift
            ;;
        --redundantsequencers)
            redundantsequencers=$2
            if ! [[ $redundantsequencers =~ [0-3] ]] ; then
                echo "redundantsequencers must be between 0 and 3 value:$redundantsequencers."
                exit 1
            fi
            shift
            shift
            ;;
        *)
            echo Usage: $0 \[OPTIONS..]
            echo        $0 script [SCRIPT-ARGS]
            echo
            echo OPTIONS:
            echo --build:           rebuild docker image
            echo --init:            remove all data, rebuild, deploy new rollup
            echo --validate:        heavy computation, validating all blocks in WASM
            echo --batchposters:    batch posters [0-3]
            echo --redundantsequencers redundant sequencers [0-3]
            echo --detach:          detach from nodes after running them
            echo --no-run:          does not launch nodes \(usefull with build or init\)
            echo
            echo script rus inside a separate docker. For SCRIPT-ARGS, run $0 script --help
            exit 0
    esac
done

if $force_init; then
    force_build=true
fi

NODES="sequencer"

if [ $redundantsequencers -gt 0 ]; then
    NODES="$NODES sequencer_b"
fi
if [ $redundantsequencers -gt 1 ]; then
    NODES="$NODES sequencer_c"
fi
if [ $redundantsequencers -gt 2 ]; then
    NODES="$NODES sequencer_d"
fi

if [ $batchposters -gt 0 ]; then
    NODES="$NODES poster"
fi
if [ $batchposters -gt 1 ]; then
    NODES="$NODES poster_b"
fi
if [ $batchposters -gt 2 ]; then
    NODES="$NODES poster_c"
fi


if $validate; then
    NODES="$NODES validator"
else
    NODES="$NODES staker-unsafe"
fi
if $blockscout; then
    NODES="$NODES postgres blockscout"
fi

if $force_build; then
    echo == Building..
    docker-compose build --no-rm $NODES testnode-scripts
fi

if $force_init; then
    echo == Removing old data..
    docker-compose down
    leftoverContainers=`docker container ls -a --filter label=com.docker.compose.project=nitro -q | xargs echo`
    if [ `echo $leftoverContainers | wc -w` -gt 0 ]; then
        docker rm $leftoverContainers
    fi
    docker volume prune -f --filter label=com.docker.compose.project=nitro

  
    echo == Generating l1 keys
    docker-compose run --entrypoint sh geth -c "echo passphrase > /root/.ethereum/passphrase"
    docker-compose run --entrypoint sh geth -c "echo $devprivkey > /root/.ethereum/tmp-funnelkey"
    docker-compose run --entrypoint kscn geth account import --password /root/.ethereum/passphrase --keystore /root/.ethereum/keystore /root/.ethereum/tmp-funnelkey
    docker-compose run --entrypoint sh geth -c "rm /root/.ethereum/tmp-funnelkey"
    docker-compose run --entrypoint kscn geth account new --password /root/.ethereum/passphrase --keystore /root/.ethereum/keystore
    docker-compose run --entrypoint kscn geth account new --password /root/.ethereum/passphrase --keystore /root/.ethereum/keystore
    docker-compose run --entrypoint sh geth -c "chown -R 1000:1000 /root/.ethereum/keystore"
    docker-compose run --entrypoint sh geth -c "chown -R 1000:1000 /config"
    docker-compose run --entrypoint sh geth -c "cd root;
        homi setup local --cn-num 1 --test-num 1 --servicechain --chainID 1337 --p2p-port 30303 -o homi-output;
        sed -i -e 's/\"chainId\": 1000/\"chainId\": 1337/g' ./homi-output/scripts/genesis.json;
        sed -i -e 's/\"alloc\": {/\"alloc\": {\n\"0x683642c22feDE752415D4793832Ab75EFdF6223c\": { \"balance\": \"0x6400000000000000000000\" },/g' ./homi-output/scripts/genesis.json;
        sed -i -e 's/\"unitPrice\": 0/\"unitPrice\": 0/g' ./homi-output/scripts/genesis.json;        
        kscn --datadir .ethereum init ./homi-output/scripts/genesis.json;
        cp ./homi-output/scripts/static-nodes.json ./.ethereum;
        cp ./homi-output/keys/nodekey1 ./.ethereum/klay/nodekey;
        sed -i -e 's/RPC_PORT=8551/RPC_PORT=8545/g' /klaytn-docker-pkg/conf/kscnd.conf;
        sed -i -e 's/WS_PORT=8552/WS_PORT=8546/g' /klaytn-docker-pkg/conf/kscnd.conf;
        sed -i -e 's/PORT=22323/PORT=30303/g' /klaytn-docker-pkg/conf/kscnd.conf;

        sed -i -e 's/SCSIGNER_PASSWD_FILE=/SCSIGNER_PASSWD_FILE=\\/root\\/.ethereum\\/passphrase/g' /klaytn-docker-pkg/conf/kscnd.conf;
        sed -i -e 's/DATA_DIR=/DATA_DIR=\\/root\\/.ethereum/g' /klaytn-docker-pkg/conf/kscnd.conf;       
        sed -i -e 's/RPC_API=\"klay,eth,net,web3,subbridge\"/RPC_API=\"klay,eth,net,web3,subbridge,personal\"/g' /klaytn-docker-pkg/conf/kscnd.conf;
        sed -i -e 's/WS_API=\"klay,eth,net,web3\"/WS_API=\"klay,eth,net,web3,personal,debug,txpool\"/g' /klaytn-docker-pkg/conf/kscnd.conf;
        sed -i -e 's/ADDITIONAL=\"\"/ADDITIONAL=\"--ipcpath \\/root\\/.ethereum\\/klay.ipc\"/g' /klaytn-docker-pkg/conf/kscnd.conf;
        mkdir /root/.ethereum/conf;
        mkdir /root/.ethereum/bin;
        cp /klaytn-docker-pkg/conf/kscnd.conf /root/.ethereum/conf/kscnd.conf;
        cp /klaytn-docker-pkg/bin/kscnd /root/.ethereum/bin/kscnd;
        cp /klaytn-docker-pkg/bin/kscn /root/.ethereum/bin/kscn;
        "
    docker-compose up -d geth

    echo == Funding validator and sequencer
    docker-compose run testnode-scripts send-l1 --ethamount 10 --to validator
    docker-compose run testnode-scripts send-l1 --ethamount 10 --to sequencer

    echo == Deploying L2
    sequenceraddress=`docker-compose run testnode-scripts print-address --account sequencer | tail -n 1 | tr -d '\r\n'`
    docker-compose run --entrypoint /usr/local/bin/deploy poster --l1conn ws://geth:8546 --l1keystore /home/user/l1keystore --sequencerAddress $sequenceraddress --ownerAddress $sequenceraddress --l1DeployAccount $sequenceraddress --l1deployment /config/deployment.json --authorizevalidators 10 --wasmrootpath /home/user/target/machines

    echo == Writing configs
    docker-compose run testnode-scripts write-config

    echo == Initializing redis
    docker-compose run testnode-scripts redis-init --redundancy $redundantsequencers

    docker-compose run testnode-scripts bridge-funds --ethamount 100

    if $tokenbridge; then
        echo == Deploying token bridge
        docker-compose run -e ARB_KEY=$devprivkey -e ETH_KEY=$devprivkey testnode-tokenbridge gen:network
        docker-compose run --entrypoint sh testnode-tokenbridge -c "cat localNetwork.json"
        echo 
    fi
fi

if $run; then
    UP_FLAG=""
    if $detach; then
        UP_FLAG="-d"
    fi

    echo == Launching Sequencer
    echo if things go wrong - use --init to create a new chain
    echo

    docker-compose up $UP_FLAG $NODES
fi
