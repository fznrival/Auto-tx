#!/bin/bash

# Warna untuk output
BLUE='\033[0;34m'
WHITE='\033[0;97m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
MAGENTA='\033[0;95m'
RESET='\033[0m'

# Direktori skrip saat ini
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit

# Fungsi untuk menampilkan header
display_header() {
    clear
    echo -e "${MAGENTA}====================================${RESET}"
    echo -e "${MAGENTA}=        Auto Transaction Bot      =${RESET}"
    echo -e "${MAGENTA}=        Created by fznrival       =${RESET}"
    echo -e "${MAGENTA}=       https://t.me/fznrival      =${RESET}"
    echo -e "${MAGENTA}====================================${RESET}"
    echo ""
    echo ""
    echo ""
}

# Fungsi untuk menampilkan timestamp
log_timestamp() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${RESET} $1"
}

# Pastikan jq dan Node.js terinstal
if ! command -v jq &> /dev/null; then
    log_timestamp "${YELLOW}Menginstal jq...${RESET}"
    sudo apt-get install -y jq
fi

if ! command -v node &> /dev/null; then
    log_timestamp "${YELLOW}Node.js belum terinstal. Menginstal Node.js...${RESET}"
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# Buat direktori sementara untuk proyek
TEMP_DIR="$SCRIPT_DIR/temp_project"
if [ ! -d "$TEMP_DIR" ]; then
    mkdir "$TEMP_DIR"
    cd "$TEMP_DIR" || exit
    log_timestamp "${YELLOW}Menginisialisasi proyek sementara dan menginstal ethers v5...${RESET}"
    npm init -y > /dev/null 2>&1
    npm install ethers@5 > /dev/null 2>&1
else
    cd "$TEMP_DIR" || exit
fi

# Fungsi untuk memeriksa konektivitas jaringan
check_network_connectivity() {
    local rpc_url=$1
    local domain=$(echo "$rpc_url" | sed -E 's#https?://([^/]+).*#\1#')
    
    log_timestamp "${YELLOW}Memeriksa konektivitas jaringan ke $domain...${RESET}"
    
    if ping -c 1 -W 5 "$domain" &> /dev/null; then
        log_timestamp "${GREEN}Konektivitas jaringan OK${RESET}"
        return 0
    fi
    
    if curl --connect-timeout 10 -sI "$rpc_url" &> /dev/null; then
        log_timestamp "${GREEN}RPC endpoint dapat dijangkau${RESET}"
        return 0
    fi
    
    log_timestamp "${RED}Tidak dapat terhubung ke RPC endpoint $rpc_url.${RESET}"
    return 1
}

# Fungsi untuk mengirim transaksi
send_transaction() {
    local rpc_url=$1
    local chain_id=$2
    local private_key=$3
    local recipient_address=$4
    local amount=$5
    local explorer_url=$6

    log_timestamp "${YELLOW}Menyiapkan pengiriman transaksi di jaringan dengan RPC: $rpc_url${RESET}"

    # Membuat script Node.js sementara untuk mengirim TX
    cat <<EOL > "$TEMP_DIR/send_tx.js"
const ethers = require("ethers");

async function sendTx() {
    try {
        console.log("Versi ethers yang digunakan:", ethers.version);
        const provider = new ethers.providers.JsonRpcProvider("$rpc_url");
        const wallet = new ethers.Wallet("$private_key", provider);
        const tx = {
            to: "$recipient_address",
            value: ethers.utils.parseEther("$amount"),
            chainId: $chain_id
        };

        const txResponse = await wallet.sendTransaction(tx);
        console.log("Transaksi dikirim. Hash: " + txResponse.hash);
        await txResponse.wait();
        console.log("Transaksi dikonfirmasi di: $explorer_url/tx/" + txResponse.hash);
    } catch (error) {
        console.error("Error saat mengirim transaksi:", error.message);
        process.exit(1);
    }
}

sendTx();
EOL

    # Jalankan script Node.js dari direktori sementara
    log_timestamp "${YELLOW}Mengirim transaksi...${RESET}"
    if OUTPUT=$(node "$TEMP_DIR/send_tx.js" 2>&1); then
        log_timestamp "${GREEN}Transaksi berhasil:${RESET}"
        echo "$OUTPUT" | while IFS= read -r line; do
            if [[ "$line" =~ "Versi ethers yang digunakan:" ]]; then
                VERSION=$(echo "$line" | grep -oP 'Versi ethers yang digunakan: \K(.+)$')
                log_timestamp "${WHITE}Versi ethers: ${BLUE}$VERSION${RESET}"
            elif [[ "$line" =~ "Transaksi dikirim. Hash:" ]]; then
                TX_HASH=$(echo "$line" | grep -oP 'Hash: \K(0x[a-fA-F0-9]+)')
                log_timestamp "${WHITE}Hash TX: ${BLUE}$TX_HASH${RESET}"
            elif [[ "$line" =~ "Transaksi dikonfirmasi di:" ]]; then
                TX_URL=$(echo "$line" | grep -oP 'Transaksi dikonfirmasi di: \K(.+)$')
                log_timestamp "${WHITE}Lihat di explorer: ${BLUE}$TX_URL${RESET}"
            fi
        done
    else
        log_timestamp "${RED}Gagal mengirim transaksi:${RESET}"
        echo "$OUTPUT"
        return 1
    fi

    # Hapus script sementara
    rm -f "$TEMP_DIR/send_tx.js"
    return 0
}

# Fungsi utama
main() {
    display_header
    if [ ! -f "$SCRIPT_DIR/rpc_mainnet.json" ]; then
        log_timestamp "${RED}File rpc_mainnet.json tidak ditemukan di $SCRIPT_DIR!${RESET}"
        exit 1
    fi

    NETWORK_COUNT=$(jq -r '. | length' "$SCRIPT_DIR/rpc_mainnet.json")
    log_timestamp "${YELLOW}Menemukan $NETWORK_COUNT jaringan di rpc_mainnet.json${RESET}"

    read -p "Masukkan Private Key pengirim: " PRIVATE_KEY
    if [ -z "$PRIVATE_KEY" ]; then
        log_timestamp "${RED}Private Key wajib diisi!${RESET}"
        exit 1
    fi

    read -p "Masukkan alamat penerima: " RECIPIENT_ADDRESS
    if ! [[ "$RECIPIENT_ADDRESS" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        log_timestamp "${RED}Alamat penerima tidak valid! Harus berupa alamat Ethereum yang valid.${RESET}"
        exit 1
    fi

    read -p "Masukkan jumlah ETH yang ingin dikirim (contoh: 0.1): " AMOUNT
    if ! [[ "$AMOUNT" =~ ^[0-9]*\.?[0-9]+$ ]] || (( $(echo "$AMOUNT <= 0" | bc -l) )); then
        log_timestamp "${RED}Jumlah harus berupa angka positif!${RESET}"
        exit 1
    fi

    read -p "Berapa kali pengiriman TX per jaringan? " TX_COUNT
    if ! [[ "$TX_COUNT" =~ ^[0-9]+$ ]] || [ "$TX_COUNT" -lt 1 ]; then
        log_timestamp "${RED}Jumlah pengiriman harus berupa angka positif!${RESET}"
        exit 1
    fi

    for ((network_index=0; network_index<NETWORK_COUNT; network_index++)); do
        RPC_URL=$(jq -r ".[$network_index].rpcUrl" "$SCRIPT_DIR/rpc_mainnet.json")
        CHAIN_ID=$(jq -r ".[$network_index].chainId" "$SCRIPT_DIR/rpc_mainnet.json")
        EXPLORER_URL=$(jq -r ".[$network_index].explorer" "$SCRIPT_DIR/rpc_mainnet.json")
        NETWORK_NAME=$(jq -r ".[$network_index].name" "$SCRIPT_DIR/rpc_mainnet.json")

        if [ "$RPC_URL" == "null" ] || [ "$CHAIN_ID" == "null" ] || [ "$EXPLORER_URL" == "null" ]; then
            log_timestamp "${RED}Data tidak lengkap untuk jaringan #$((network_index + 1)) di rpc_mainnet.json. Melewati...${RESET}"
            continue
        fi

        log_timestamp "${YELLOW}Memproses jaringan: $NETWORK_NAME${RESET}"

        if check_network_connectivity "$RPC_URL"; then
            tx_iteration=0
            while [ $tx_iteration -lt $TX_COUNT ]; do
                ((tx_iteration++))
                log_timestamp "${YELLOW}Pengiriman TX ke-$tx_iteration dari $TX_COUNT untuk $NETWORK_NAME${RESET}"
                send_transaction "$RPC_URL" "$CHAIN_ID" "$PRIVATE_KEY" "$RECIPIENT_ADDRESS" "$AMOUNT" "$EXPLORER_URL" || {
                    log_timestamp "${RED}Pengiriman TX gagal untuk $NETWORK_NAME. Melanjutkan ke jaringan berikutnya...${RESET}"
                    break
                }
                if [ $tx_iteration -lt $TX_COUNT ]; then
                    log_timestamp "${YELLOW}Menunggu 10 detik sebelum pengiriman berikutnya...${RESET}"
                    sleep 10
                fi
            done
            log_timestamp "${GREEN}Selesai pengiriman TX untuk $NETWORK_NAME (${TX_COUNT} kali)${RESET}"
        else
            log_timestamp "${RED}Koneksi gagal untuk $NETWORK_NAME. Melewati jaringan ini.${RESET}"
        fi

        if [ $network_index -lt $((NETWORK_COUNT - 1)) ]; then
            log_timestamp "${YELLOW}Menunggu 10 detik sebelum memproses jaringan berikutnya...${RESET}"
            sleep 10
        fi
    done

    log_timestamp "${GREEN}Semua jaringan selesai diproses!${RESET}"
}

# Menangani sinyal interrupt (Ctrl+C)
trap 'echo -e "\n${RED}Script dihentikan oleh user${RESET}"; rm -rf "$TEMP_DIR"; exit 0' INT

# Eksekusi program
main

# Bersihkan direktori sementara setelah selesai
rm -rf "$TEMP_DIR"
