#!/bin/bash

# Configuration
DATA_DIR="$HOME/.minimal_inventory"
mkdir -p "$DATA_DIR"

# File paths
INVENTORY_FILE="$DATA_DIR/inventory.csv"
USERS_FILE="$DATA_DIR/users.csv"
HISTORY_FILE="$DATA_DIR/history.log"
LOCKED_USERS_FILE="$DATA_DIR/locked_users.txt"

# Function to add new user
add_user() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    local user_info=$(zenity --forms \
        --title="Yeni Kullanıcı Ekle" \
        --text="Kullanıcı bilgilerini girin" \
        --separator="|" \
        --add-entry="Kullanıcı Adı" \
        --add-entry="Ad Soyad" \
        --add-password="Şifre" \
        --add-combo="Rol" \
        --combo-values="user|admin" \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        IFS="|" read -r username fullname password role <<< "$user_info"
        
        # Validate username
        if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            zenity --error \
                --text="Kullanıcı adı sadece harf, rakam, alt çizgi ve tire içerebilir."
            log_action "add_user" "error" "Invalid username format: $username"
            return 1
        fi
        
        # Check if username exists
        if grep -q "^[^,]*,$username," "$USERS_FILE"; then
            zenity --error \
                --text="Bu kullanıcı adı zaten kullanılıyor."
            log_action "add_user" "error" "Username already exists: $username"
            return 1
        fi
        
        # Hash password
        local hashed_pass=$(echo -n "$password" | md5sum | cut -d' ' -f1)
        
        # Add user with unique ID
        local id=$(generate_id)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$id,$username,$fullname,$role,$hashed_pass,$timestamp,0" >> "$USERS_FILE"
        
        zenity --info \
            --text="Kullanıcı başarıyla eklendi."
        log_action "add_user" "success" "Added user: $username with role $role"
    fi
}

# Function to update user
update_user() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    # Get list of users except current user
    local users=$(grep -v "^[^,]*,$CURRENT_USER," "$USERS_FILE" | cut -d',' -f2)
    if [ -z "$users" ]; then
        zenity --info \
            --text="Güncellenebilecek kullanıcı bulunmamaktadır."
        return
    fi
    
    local username=$(zenity --list \
        --title="Kullanıcı Güncelle" \
        --text="Güncellenecek kullanıcıyı seçin:" \
        --column="Kullanıcı Adı" \
        $users \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local user_data=$(grep "^[^,]*,$username," "$USERS_FILE")
        IFS=, read -r id _ fullname role _ _ _ <<< "$user_data"
        
        local update_info=$(zenity --forms \
            --title="Kullanıcı Güncelle" \
            --text="$username kullanıcısının bilgilerini güncelleyin" \
            --separator="|" \
            --add-entry="Ad Soyad (mevcut: $fullname)" \
            --add-password="Yeni Şifre (boş bırakılırsa değişmez)" \
            --add-combo="Rol (mevcut: $role)" \
            --combo-values="user|admin" \
            2>/dev/null)
        
        if [ $? -eq 0 ]; then
            IFS="|" read -r new_fullname new_password new_role <<< "$update_info"
            
            # Use current values if new ones are empty
            new_fullname=${new_fullname:-$fullname}
            new_role=${new_role:-$role}
            
            local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            
            if [ -n "$new_password" ]; then
                local new_hash=$(echo -n "$new_password" | md5sum | cut -d' ' -f1)
                sed -i "" "s/^$id,$username,$fullname,$role,[^,]*,[^,]*,[^,]*/$id,$username,$new_fullname,$new_role,$new_hash,$timestamp,0/" "$USERS_FILE"
            else
                sed -i "" "s/^$id,$username,$fullname,$role,\([^,]*\),[^,]*,[^,]*/$id,$username,$new_fullname,$new_role,\1,$timestamp,0/" "$USERS_FILE"
            fi
            
            zenity --info \
                --text="Kullanıcı başarıyla güncellendi."
            log_action "update_user" "success" "Updated user: $username"
            
            # If current user was updated, update session info
            if [ "$username" = "$CURRENT_USER" ]; then
                CURRENT_ROLE="$new_role"
            fi
        fi
    fi
}

# Function to list users
list_users() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    if [ ! -s "$USERS_FILE" ]; then
        zenity --info \
            --text="Kayıtlı kullanıcı bulunmamaktadır."
            return
    fi
    
    # Create temporary file for user data
    local tmp_file=$(mktemp)
    
    # Prepare data in table format
    (tail -n +2 "$USERS_FILE" | while IFS=, read -r id username fullname role _ last_login failed_attempts; do
        local status="Aktif"
        if grep -q "^$username$" "$LOCKED_USERS_FILE"; then
            status="Kilitli"
        fi
        echo "$username|$fullname|$role|$last_login|$failed_attempts|$status"
    done) > "$tmp_file"
    
    # Show table
    zenity --list \
        --title="Kullanıcı Listesi" \
        --width=800 \
        --height=400 \
        --text="<span size='large'>Kullanıcı Listesi</span>" \
        --column="Kullanıcı Adı" \
        --column="Ad Soyad" \
        --column="Rol" \
        --column="Son Giriş" \
        --column="Başarısız Giriş" \
        --column="Durum" \
        --print-column="ALL" \
        --separator="|" \
        $(cat "$tmp_file") \
        2>/dev/null
    
    rm -f "$tmp_file"
}

# Function to delete user
delete_user() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    # Get list of users except current user and admin
    local users=$(grep -v "^[^,]*,\(admin\|$CURRENT_USER\)," "$USERS_FILE" | cut -d',' -f2)
    if [ -z "$users" ]; then
        zenity --info \
            --text="Silinebilecek kullanıcı bulunmamaktadır."
        return
    fi
    
    local username=$(zenity --list \
        --title="Kullanıcı Sil" \
        --text="Silinecek kullanıcıyı seçin:" \
        --column="Kullanıcı Adı" \
        $users \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        if zenity --question \
            --text="'$username' kullanıcısını silmek istediğinizden emin misiniz?"; then
            
            # Create backup before deletion
            cp "$USERS_FILE" "$USERS_FILE.bak"
            
            # Delete user
            grep -v "^[^,]*,$username," "$USERS_FILE" > "$USERS_FILE.tmp"
            mv "$USERS_FILE.tmp" "$USERS_FILE"
            
            # Remove from locked users if exists
            sed -i "" "/^$username$/d" "$LOCKED_USERS_FILE"
            
                zenity --info \
                --text="Kullanıcı başarıyla silindi."
            log_action "delete_user" "success" "Deleted user: $username"
        fi
    fi
}

# Initialize files with headers if they don't exist
init_files() {
    # Initialize inventory.csv
    if [ ! -f "$INVENTORY_FILE" ]; then
        echo "$INVENTORY_HEADER" > "$INVENTORY_FILE"
        log_action "system" "info" "Created inventory.csv with header"
    fi

    # Initialize users.csv with default admin
    if [ ! -f "$USERS_FILE" ]; then
        echo "$USERS_HEADER" > "$USERS_FILE"
        # Create default admin user
        local admin_id=$(generate_id)
        local admin_pass=$(echo -n "admin123" | md5sum | cut -d' ' -f1)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$admin_id,admin,Administrator,admin,$admin_pass,$timestamp,0" >> "$USERS_FILE"
        log_action "system" "info" "Created users.csv with default admin user"
    fi

    # Initialize history.log
    if [ ! -f "$HISTORY_FILE" ]; then
        echo "# Envanter Yönetim Sistemi - İşlem Kayıtları" > "$HISTORY_FILE"
        echo "# Format: [Tarih Saat] [Kullanıcı] [İşlem] [Durum] [Hata Kodu] Mesaj" >> "$HISTORY_FILE"
        echo "# Başlangıç: $(date '+%Y-%m-%d %H:%M:%S')" >> "$HISTORY_FILE"
        echo "--------------------------------------------------------------------------------" >> "$HISTORY_FILE"
    fi

    # Initialize locked_users.txt
    touch "$LOCKED_USERS_FILE"
}

# Start the program with login
authenticate_user || exit 1 