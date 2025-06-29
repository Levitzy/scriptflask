#!/bin/bash

# Flask Auto-Deploy Script with SSL and Management Menu
# Author: Flask Deployment Automation
# Version: 1.0

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/flask_deploy_config.conf"

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}========================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}========================================${NC}"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should not be run as root for security reasons"
        print_error "Please run as a regular user with sudo privileges"
        exit 1
    fi
}

# Function to check sudo privileges
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        print_error "This script requires sudo privileges"
        print_error "Please run: sudo -v"
        exit 1
    fi
}

# Function to load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        return 0
    else
        return 1
    fi
}

# Function to save configuration
save_config() {
    cat > "$CONFIG_FILE" << EOF
# Flask Deployment Configuration
PROJECT_NAME="$PROJECT_NAME"
PROJECT_USER="$PROJECT_USER"
PROJECT_DIR="$PROJECT_DIR"
DOMAIN_NAME="$DOMAIN_NAME"
GIT_REPO="$GIT_REPO"
FLASK_APP_FILE="$FLASK_APP_FILE"
FLASK_APP_VAR="$FLASK_APP_VAR"
USE_SSL="$USE_SSL"
SETUP_SECURITY="$SETUP_SECURITY"
DEPLOYMENT_TYPE="$DEPLOYMENT_TYPE"
NGINX_PORT="$NGINX_PORT"
EOF
    print_status "Configuration saved to $CONFIG_FILE"
}

# Function to get user input with default
get_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    
    if [[ -n "$default" ]]; then
        read -p "$prompt [$default]: " input
        eval "$var_name=\"\${input:-$default}\""
    else
        read -p "$prompt: " input
        eval "$var_name=\"$input\""
    fi
}

# Function to get yes/no input
get_yes_no() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    
    while true; do
        if [[ "$default" == "y" ]]; then
            read -p "$prompt [Y/n]: " input
            input=${input:-y}
        else
            read -p "$prompt [y/N]: " input
            input=${input:-n}
        fi
        
        case $input in
            [Yy]* ) eval "$var_name=true"; break;;
            [Nn]* ) eval "$var_name=false"; break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Function to collect deployment information
collect_deployment_info() {
    print_header "Flask Project Deployment Configuration"
    
    get_input "Project name (used for service names)" "my-flask-app" PROJECT_NAME
    get_input "Project user (will be created)" "${PROJECT_NAME}user" PROJECT_USER
    get_input "Domain name or IP address" "$(curl -s ifconfig.me)" DOMAIN_NAME
    get_input "Git repository URL" "" GIT_REPO
    get_input "Flask app file (e.g., app.py, main.py, server.py)" "app.py" FLASK_APP_FILE
    get_input "Flask app variable name" "app" FLASK_APP_VAR
    
    echo ""
    echo "Deployment type options:"
    echo "1) Main domain (https://domain.com/)"
    echo "2) Subdirectory (https://domain.com/projectname/)"
    echo "3) Custom port (https://domain.com:8080/)"
    
    while true; do
        read -p "Choose deployment type [1-3]: " deploy_choice
        case $deploy_choice in
            1) DEPLOYMENT_TYPE="main"; break;;
            2) DEPLOYMENT_TYPE="subdirectory"; break;;
            3) DEPLOYMENT_TYPE="port"; 
               get_input "Custom port number" "8080" NGINX_PORT; break;;
            *) echo "Please choose 1, 2, or 3";;
        esac
    done
    
    get_yes_no "Setup SSL certificate with Let's Encrypt?" "y" USE_SSL
    get_yes_no "Setup security (Fail2Ban, firewall, SSH hardening)?" "y" SETUP_SECURITY
    
    PROJECT_DIR="/home/$PROJECT_USER/$PROJECT_NAME"
}

# Function to install system dependencies
install_dependencies() {
    print_header "Installing System Dependencies"
    
    sudo apt update
    sudo apt install -y python3 python3-pip python3-venv git nginx supervisor ufw curl wget
    
    if [[ "$USE_SSL" == "true" ]]; then
        sudo apt install -y certbot python3-certbot-nginx
    fi
    
    if [[ "$SETUP_SECURITY" == "true" ]]; then
        sudo apt install -y fail2ban
    fi
    
    print_status "System dependencies installed successfully"
}

# Function to create project user
create_project_user() {
    print_header "Creating Project User"
    
    if id "$PROJECT_USER" &>/dev/null; then
        print_warning "User $PROJECT_USER already exists"
    else
        sudo adduser --disabled-password --gecos "" "$PROJECT_USER"
        print_status "User $PROJECT_USER created successfully"
    fi
    
    # Add to sudo group if needed
    sudo usermod -aG sudo "$PROJECT_USER"
}

# Function to clone and setup project
setup_project() {
    print_header "Setting Up Flask Project"
    
    # Switch to project user and setup project
    sudo -u "$PROJECT_USER" bash << EOF
cd /home/$PROJECT_USER
if [[ -d "$PROJECT_NAME" ]]; then
    echo "Project directory already exists, backing up..."
    mv "$PROJECT_NAME" "${PROJECT_NAME}_backup_\$(date +%Y%m%d_%H%M%S)"
fi

git clone "$GIT_REPO" "$PROJECT_NAME"
cd "$PROJECT_NAME"

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip

if [[ -f "requirements.txt" ]]; then
    pip install -r requirements.txt
else
    echo "No requirements.txt found, installing basic Flask packages"
    pip install flask gunicorn
fi

pip install gunicorn  # Ensure gunicorn is installed
EOF
    
    print_status "Project setup completed"
}

# Function to create Gunicorn startup script
create_gunicorn_script() {
    print_header "Creating Gunicorn Configuration"
    
    local app_module="${FLASK_APP_FILE%.*}:$FLASK_APP_VAR"
    
    sudo -u "$PROJECT_USER" tee "$PROJECT_DIR/gunicorn_start.sh" > /dev/null << EOF
#!/bin/bash
NAME="$PROJECT_NAME"
PROJECTDIR="$PROJECT_DIR"
SOCKFILE="$PROJECT_DIR/run/gunicorn.sock"
USER="$PROJECT_USER"
GROUP="$PROJECT_USER"
NUM_WORKERS=3

echo "Starting \$NAME as \$(whoami)"

cd \$PROJECTDIR
source venv/bin/activate

export PYTHONPATH=\$PROJECTDIR:\$PYTHONPATH

RUNDIR=\$(dirname \$SOCKFILE)
test -d \$RUNDIR || mkdir -p \$RUNDIR
test -f \$SOCKFILE && rm \$SOCKFILE

exec venv/bin/gunicorn $app_module \\
  --name \$NAME \\
  --workers \$NUM_WORKERS \\
  --user=\$USER \\
  --group=\$GROUP \\
  --bind=unix:\$SOCKFILE \\
  --log-level=info \\
  --log-file=-
EOF
    
    sudo -u "$PROJECT_USER" chmod +x "$PROJECT_DIR/gunicorn_start.sh"
    sudo -u "$PROJECT_USER" mkdir -p "$PROJECT_DIR/run"
    
    print_status "Gunicorn script created"
}

# Function to setup Supervisor
setup_supervisor() {
    print_header "Setting Up Supervisor"
    
    sudo tee "/etc/supervisor/conf.d/$PROJECT_NAME.conf" > /dev/null << EOF
[program:$PROJECT_NAME]
command = $PROJECT_DIR/gunicorn_start.sh
user = $PROJECT_USER
stdout_logfile = /var/log/$PROJECT_NAME.log
redirect_stderr = true
environment=LANG=en_US.UTF-8,LC_ALL=en_US.UTF-8
autostart=true
autorestart=true
EOF
    
    sudo supervisorctl reread
    sudo supervisorctl update
    sudo supervisorctl start "$PROJECT_NAME"
    
    print_status "Supervisor configured and service started"
}

# Function to setup Nginx
setup_nginx() {
    print_header "Setting Up Nginx"
    
    local nginx_config="/etc/nginx/sites-available/$PROJECT_NAME"
    
    case "$DEPLOYMENT_TYPE" in
        "main")
            create_main_nginx_config "$nginx_config"
            # Enable the site
            sudo ln -sf "$nginx_config" "/etc/nginx/sites-enabled/$PROJECT_NAME"
            ;;
        "subdirectory")
            create_subdirectory_nginx_config "$nginx_config"
            # For subdirectory, we either modify default or create new config
            # Only create symlink if we created a new config file
            if [[ -f "$nginx_config" ]]; then
                sudo ln -sf "$nginx_config" "/etc/nginx/sites-enabled/$PROJECT_NAME"
            fi
            ;;
        "port")
            create_port_nginx_config "$nginx_config"
            # Enable the site
            sudo ln -sf "$nginx_config" "/etc/nginx/sites-enabled/$PROJECT_NAME"
            ;;
    esac
    
    # Test Nginx configuration
    if sudo nginx -t; then
        sudo systemctl reload nginx
        print_status "Nginx configured successfully"
    else
        print_error "Nginx configuration test failed"
        print_error "Please check the configuration manually"
        exit 1
    fi
}

# Function to create main domain Nginx config
create_main_nginx_config() {
    local config_file="$1"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;
    
    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    server_tokens off;
    
    access_log /var/log/nginx/${PROJECT_NAME}_access.log;
    error_log /var/log/nginx/${PROJECT_NAME}_error.log;
    
    client_max_body_size 4M;

    location ~* /(wp-admin|wp-login|phpmyadmin|admin|login|xmlrpc) {
        deny all;
        return 404;
    }
    
    location ~* \\.(env|git|sql|log|ini|conf)\$ {
        deny all;
        return 404;
    }

    location /static/ {
        alias $PROJECT_DIR/static/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_redirect off;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;

        proxy_pass http://unix:$PROJECT_DIR/run/gunicorn.sock;
    }
}
EOF
}

# Function to create subdirectory Nginx config
create_subdirectory_nginx_config() {
    local config_file="$1"
    
    # For subdirectory deployment, we need to modify the default site or create a new one
    if [[ -f "/etc/nginx/sites-available/default" ]] && [[ -f "/etc/nginx/sites-enabled/default" ]]; then
        # Modify existing default config
        print_warning "Adding subdirectory configuration to existing default site"
        
        # Backup existing config
        sudo cp /etc/nginx/sites-available/default "/etc/nginx/sites-available/default.backup.$(date +%Y%m%d_%H%M%S)"
        
        # Check if our location block already exists
        if ! grep -q "location /$PROJECT_NAME/" /etc/nginx/sites-available/default; then
            # Find the location / block and add our config before it
            sudo sed -i "/^[[:space:]]*location[[:space:]]*\/[[:space:]]*{/i\\
    # $PROJECT_NAME Flask application\\
    location /$PROJECT_NAME/ {\\
        rewrite ^/$PROJECT_NAME/(.*) /\$1 break;\\
        proxy_pass http://unix:$PROJECT_DIR/run/gunicorn.sock;\\
        proxy_set_header Host \$http_host;\\
        proxy_set_header X-Real-IP \$remote_addr;\\
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\\
        proxy_set_header X-Forwarded-Proto \$scheme;\\
        proxy_redirect off;\\
        proxy_buffering off;\\
        proxy_read_timeout 300s;\\
        proxy_connect_timeout 75s;\\
    }\\
\\
    # $PROJECT_NAME static files\\
    location /$PROJECT_NAME/static/ {\\
        alias $PROJECT_DIR/static/;\\
        expires 1y;\\
        add_header Cache-Control \"public, immutable\";\\
    }\\
" /etc/nginx/sites-available/default
            
            print_status "Added subdirectory configuration to default site"
        else
            print_warning "Subdirectory configuration already exists in default site"
        fi
        
        # Don't create a separate enabled symlink for subdirectory mode
        return 0
        
    else
        # Create new config with subdirectory as main site
        print_status "Creating new site configuration for subdirectory deployment"
        
        sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;
    
    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    server_tokens off;
    
    access_log /var/log/nginx/${PROJECT_NAME}_access.log;
    error_log /var/log/nginx/${PROJECT_NAME}_error.log;
    
    client_max_body_size 4M;

    # Block common attack patterns
    location ~* /(wp-admin|wp-login|phpmyadmin|admin|login|xmlrpc) {
        deny all;
        return 404;
    }

    # $PROJECT_NAME Flask application
    location /$PROJECT_NAME/ {
        rewrite ^/$PROJECT_NAME/(.*) /\$1 break;
        proxy_pass http://unix:$PROJECT_DIR/run/gunicorn.sock;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }
    
    # $PROJECT_NAME static files
    location /$PROJECT_NAME/static/ {
        alias $PROJECT_DIR/static/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    # Root location for server info
    location = / {
        return 200 "Server is running. Flask applications:\\n\\n- $PROJECT_NAME: http://$DOMAIN_NAME/$PROJECT_NAME/\\n";
        add_header Content-Type text/plain;
    }
    
    # Default location for other paths
    location / {
        return 404 "Page not found. Available applications:\\n\\n- $PROJECT_NAME: http://$DOMAIN_NAME/$PROJECT_NAME/\\n";
        add_header Content-Type text/plain;
    }
}
EOF
        return 1  # Signal that we created a new config file
    fi
}

# Function to create port-based Nginx config
create_port_nginx_config() {
    local config_file="$1"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen $NGINX_PORT;
    server_name $DOMAIN_NAME;
    
    server_tokens off;
    
    access_log /var/log/nginx/${PROJECT_NAME}_access.log;
    error_log /var/log/nginx/${PROJECT_NAME}_error.log;
    
    client_max_body_size 4M;

    location /static/ {
        alias $PROJECT_DIR/static/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_redirect off;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;

        proxy_pass http://unix:$PROJECT_DIR/run/gunicorn.sock;
    }
}
EOF
}

# Function to setup SSL
setup_ssl() {
    if [[ "$USE_SSL" != "true" ]]; then
        return 0
    fi
    
    print_header "Setting Up SSL Certificate"
    
    # Check if domain is accessible
    if ! curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN_NAME" | grep -q "200\|301\|302"; then
        print_warning "Domain might not be accessible yet. SSL setup might fail."
        print_warning "Make sure your domain points to this server's IP address."
        
        get_yes_no "Continue with SSL setup anyway?" "n" continue_ssl
        if [[ "$continue_ssl" != "true" ]]; then
            print_warning "SSL setup skipped. You can run it later from the management menu."
            return 0
        fi
    fi
    
    # Get SSL certificate
    if sudo certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "admin@$DOMAIN_NAME"; then
        print_status "SSL certificate installed successfully"
        
        # Setup auto-renewal
        sudo systemctl enable certbot.timer
        sudo systemctl start certbot.timer
    else
        print_error "SSL certificate installation failed"
        print_warning "You can try again later from the management menu"
    fi
}

# Function to setup security
setup_security() {
    if [[ "$SETUP_SECURITY" != "true" ]]; then
        return 0
    fi
    
    print_header "Setting Up Security"
    
    # Setup UFW firewall
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh
    sudo ufw allow 'Nginx Full'
    
    if [[ "$DEPLOYMENT_TYPE" == "port" ]]; then
        sudo ufw allow "$NGINX_PORT/tcp"
    fi
    
    sudo ufw --force enable
    
    # Setup Fail2Ban
    sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    
    # Add custom jail for this project
    sudo tee -a /etc/fail2ban/jail.local > /dev/null << EOF

[nginx-$PROJECT_NAME]
enabled = true
port = http,https
filter = nginx-$PROJECT_NAME
logpath = /var/log/nginx/${PROJECT_NAME}_access.log
maxretry = 10
bantime = 3600
EOF
    
    # Create custom filter
    sudo tee "/etc/fail2ban/filter.d/nginx-$PROJECT_NAME.conf" > /dev/null << EOF
[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD).*HTTP.*" (4|5)\\d\\d
            ^<HOST> -.*".*sqlmap.*"
            ^<HOST> -.*".*union.*select.*"
ignoreregex =
EOF
    
    sudo systemctl restart fail2ban
    
    print_status "Security setup completed"
}

# Function to create management scripts
create_management_scripts() {
    print_header "Creating Management Scripts"
    
    # Create update script
    sudo -u "$PROJECT_USER" tee "$PROJECT_DIR/update.sh" > /dev/null << 'EOF'
#!/bin/bash
set -e

PROJECT_NAME="$PROJECT_NAME"
PROJECT_DIR="$PROJECT_DIR"

echo "Updating $PROJECT_NAME..."

cd "$PROJECT_DIR"

# Backup current state
BACKUP_DIR="$PROJECT_DIR/backups"
mkdir -p "$BACKUP_DIR"
git bundle create "$BACKUP_DIR/backup-$(date +%Y%m%d-%H%M%S).bundle" --all 2>/dev/null || true

# Update code
git fetch origin
git pull origin main

# Update dependencies if requirements.txt changed
if git diff HEAD~1 --name-only | grep -q "requirements.txt" 2>/dev/null; then
    echo "Updating dependencies..."
    source venv/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt
fi

echo "Update completed. Restart the service to apply changes."
echo "Run: sudo supervisorctl restart $PROJECT_NAME"
EOF
    
    sudo -u "$PROJECT_USER" chmod +x "$PROJECT_DIR/update.sh"
    
    # Create the main management script
    tee "$SCRIPT_DIR/manage_$PROJECT_NAME.sh" > /dev/null << EOF
#!/bin/bash

# Flask Project Management Script
# Auto-generated by Flask Auto-Deploy

PROJECT_NAME="$PROJECT_NAME"
PROJECT_USER="$PROJECT_USER"
PROJECT_DIR="$PROJECT_DIR"
DOMAIN_NAME="$DOMAIN_NAME"
DEPLOYMENT_TYPE="$DEPLOYMENT_TYPE"
NGINX_PORT="$NGINX_PORT"
USE_SSL="$USE_SSL"
SETUP_SECURITY="$SETUP_SECURITY"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status() {
    echo -e "\${GREEN}[INFO]\${NC} \$1"
}

print_error() {
    echo -e "\${RED}[ERROR]\${NC} \$1"
}

print_header() {
    clear
    echo -e "\${PURPLE}========================================\${NC}"
    echo -e "\${PURPLE}  Flask Project Management - \$PROJECT_NAME\${NC}"
    echo -e "\${PURPLE}========================================\${NC}"
    echo ""
}

# Check if running with correct permissions
check_permissions() {
    if [[ \$EUID -eq 0 ]]; then
        echo "Please run this script as a regular user with sudo privileges, not as root."
        exit 1
    fi
    
    if ! sudo -n true 2>/dev/null; then
        echo "This script requires sudo privileges. Please run: sudo -v"
        exit 1
    fi
}

open_browser_url() {
    print_header
    echo "Open Project URLs in Browser"
    echo "============================="
    
    # Determine URLs based on deployment type
    local http_url=""
    local https_url=""
    
    case "\$DEPLOYMENT_TYPE" in
        "main")
            http_url="http://\$DOMAIN_NAME/"
            https_url="https://\$DOMAIN_NAME/"
            ;;
        "subdirectory")
            http_url="http://\$DOMAIN_NAME/\$PROJECT_NAME/"
            https_url="https://\$DOMAIN_NAME/\$PROJECT_NAME/"
            ;;
        "port")
            http_url="http://\$DOMAIN_NAME:\$NGINX_PORT/"
            https_url="https://\$DOMAIN_NAME:\$NGINX_PORT/"
            ;;
    esac
    
    echo -e "\${BLUE}Available URLs for \$PROJECT_NAME:\${NC}"
    echo "----------------------------------------"
    echo -e "1) \${GREEN}HTTP:\${NC}  \$http_url"
    if [[ "\$USE_SSL" == "true" ]]; then
        echo -e "2) \${GREEN}HTTPS:\${NC} \$https_url"
    fi
    echo ""
    echo -e "\${CYAN}📋 Copy these URLs and paste them in your browser:\${NC}"
    echo "\$http_url"
    if [[ "\$USE_SSL" == "true" ]]; then
        echo "\$https_url"
    fi
    
    echo ""
    echo -e "\${CYAN}🧪 Test commands:\${NC}"
    echo "curl -v \$http_url"
    if [[ "\$USE_SSL" == "true" ]]; then
        echo "curl -v \$https_url"
    fi
    
    # Test if URLs are accessible
    echo ""
    echo -e "\${BLUE}Quick URL Test:\${NC}"
    echo "----------------------------------------"
    
    echo -n "Testing HTTP: "
    local http_code=\$(curl -s -o /dev/null -w "%{http_code}" "\$http_url" 2>/dev/null || echo "000")
    case \$http_code in
        200) echo -e "\${GREEN}✓ OK (\$http_code)\${NC}" ;;
        301|302) echo -e "\${YELLOW}↗ Redirect (\$http_code)\${NC}" ;;
        404) echo -e "\${RED}✗ Not Found (\$http_code)\${NC}" ;;
        500|502|503) echo -e "\${RED}✗ Server Error (\$http_code)\${NC}" ;;
        000) echo -e "\${RED}✗ Connection Failed\${NC}" ;;
        *) echo -e "\${YELLOW}? Unexpected (\$http_code)\${NC}" ;;
    esac
    
    if [[ "\$USE_SSL" == "true" ]]; then
        echo -n "Testing HTTPS: "
        local https_code=\$(curl -s -o /dev/null -w "%{http_code}" "\$https_url" 2>/dev/null || echo "000")
        case \$https_code in
            200) echo -e "\${GREEN}✓ OK (\$https_code)\${NC}" ;;
            301|302) echo -e "\${YELLOW}↗ Redirect (\$https_code)\${NC}" ;;
            404) echo -e "\${RED}✗ Not Found (\$https_code)\${NC}" ;;
            500|502|503) echo -e "\${RED}✗ Server Error (\$https_code)\${NC}" ;;
            000) echo -e "\${RED}✗ Connection Failed\${NC}" ;;
            *) echo -e "\${YELLOW}? Unexpected (\$https_code)\${NC}" ;;
        esac
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

show_status() {
    print_header
    echo -e "\${BLUE}Project Status:\${NC}"
    echo "----------------------------------------"
    
    # Service status
    if sudo supervisorctl status "\$PROJECT_NAME" | grep -q "RUNNING"; then
        echo -e "Service Status: \${GREEN}RUNNING\${NC}"
        local pid=\$(sudo supervisorctl status "\$PROJECT_NAME" | grep -o 'pid [0-9]*' | cut -d' ' -f2)
        local uptime=\$(sudo supervisorctl status "\$PROJECT_NAME" | grep -o 'uptime [^,]*' | cut -d' ' -f2-)
        echo "Process ID: \$pid"
        echo "Uptime: \$uptime"
    else
        echo -e "Service Status: \${RED}STOPPED\${NC}"
    fi
    
    # Nginx status
    if sudo systemctl is-active nginx >/dev/null 2>&1; then
        echo -e "Nginx Status: \${GREEN}RUNNING\${NC}"
    else
        echo -e "Nginx Status: \${RED}STOPPED\${NC}"
    fi
    
    # System resources
    echo ""
    echo -e "\${BLUE}System Resources:\${NC}"
    echo "----------------------------------------"
    local cpu_usage=\$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - \$1"%"}' 2>/dev/null || echo "N/A")
    local memory_usage=\$(free | grep Mem | awk '{printf("%.1f%%", \$3/\$2 * 100.0)}' 2>/dev/null || echo "N/A")
    local disk_usage=\$(df -h / | awk 'NR==2{print \$5}' 2>/dev/null || echo "N/A")
    
    echo "CPU Usage: \$cpu_usage"
    echo "Memory Usage: \$memory_usage"
    echo "Disk Usage: \$disk_usage"
    
    # URL information
    echo ""
    echo -e "\${BLUE}Access URLs:\${NC}"
    echo "----------------------------------------"
    case "\$DEPLOYMENT_TYPE" in
        "main")
            echo -e "🌐 \${GREEN}HTTP:\${NC}  http://\$DOMAIN_NAME/"
            echo -e "🔒 \${GREEN}HTTPS:\${NC} https://\$DOMAIN_NAME/ \${YELLOW}(if SSL enabled)\${NC}"
            echo ""
            echo -e "\${CYAN}Test Commands:\${NC}"
            echo "curl -I http://\$DOMAIN_NAME/"
            echo "curl -I https://\$DOMAIN_NAME/"
            ;;
        "subdirectory")
            echo -e "🌐 \${GREEN}HTTP:\${NC}  http://\$DOMAIN_NAME/\$PROJECT_NAME/"
            echo -e "🔒 \${GREEN}HTTPS:\${NC} https://\$DOMAIN_NAME/\$PROJECT_NAME/ \${YELLOW}(if SSL enabled)\${NC}"
            echo ""
            echo -e "\${CYAN}Test Commands:\${NC}"
            echo "curl -I http://\$DOMAIN_NAME/\$PROJECT_NAME/"
            echo "curl -I https://\$DOMAIN_NAME/\$PROJECT_NAME/"
            ;;
        "port")
            echo -e "🌐 \${GREEN}HTTP:\${NC}  http://\$DOMAIN_NAME:\$NGINX_PORT/"
            echo -e "🔒 \${GREEN}HTTPS:\${NC} https://\$DOMAIN_NAME:\$NGINX_PORT/ \${YELLOW}(if SSL enabled)\${NC}"
            echo ""
            echo -e "\${CYAN}Test Commands:\${NC}"
            echo "curl -I http://\$DOMAIN_NAME:\$NGINX_PORT/"
            echo "curl -I https://\$DOMAIN_NAME:\$NGINX_PORT/"
            ;;
    esac
    
    # Project information
    echo ""
    echo -e "\${BLUE}Project Information:\${NC}"
    echo "----------------------------------------"
    echo "Project Name: \$PROJECT_NAME"
    echo "Project User: \$PROJECT_USER"
    echo "Project Directory: \$PROJECT_DIR"
    
    if cd "\$PROJECT_DIR" 2>/dev/null; then
        echo "Git Repository: \$(git remote get-url origin 2>/dev/null || echo 'Not available')"
        echo "Current Branch: \$(git branch --show-current 2>/dev/null || echo 'Not available')"
        echo "Last Commit: \$(git log -1 --oneline 2>/dev/null || echo 'Not available')"
    fi
    
    # Check application response
    echo ""
    echo -e "\${BLUE}Application Health Check:\${NC}"
    echo "----------------------------------------"
    
    case "\$DEPLOYMENT_TYPE" in
        "main") test_url="http://\$DOMAIN_NAME/" ;;
        "subdirectory") test_url="http://\$DOMAIN_NAME/\$PROJECT_NAME/" ;;
        "port") test_url="http://\$DOMAIN_NAME:\$NGINX_PORT/" ;;
    esac
    
    local http_code=\$(curl -s -o /dev/null -w "%{http_code}" "\$test_url" 2>/dev/null || echo "000")
    local response_time=\$(curl -s -o /dev/null -w "%{time_total}" "\$test_url" 2>/dev/null || echo "N/A")
    
    case \$http_code in
        200) echo -e "HTTP Status: \${GREEN}\$http_code (OK)\${NC}" ;;
        301|302) echo -e "HTTP Status: \${YELLOW}\$http_code (Redirect)\${NC}" ;;
        404) echo -e "HTTP Status: \${RED}\$http_code (Not Found)\${NC}" ;;
        500|502|503) echo -e "HTTP Status: \${RED}\$http_code (Server Error)\${NC}" ;;
        000) echo -e "HTTP Status: \${RED}Connection Failed\${NC}" ;;
        *) echo -e "HTTP Status: \${YELLOW}\$http_code\${NC}" ;;
    esac
    
    if [[ "\$response_time" != "N/A" ]]; then
        echo "Response Time: \${response_time}s"
    fi
    
    echo ""
    echo -e "\${BLUE}Recent Logs (last 5 lines):\${NC}"
    echo "----------------------------------------"
    sudo tail -5 "/var/log/\$PROJECT_NAME.log" 2>/dev/null || echo "No logs available"
    
    echo ""
    read -p "Press Enter to continue..."
}

restart_service() {
    print_header
    echo "Restarting \$PROJECT_NAME service..."
    
    sudo supervisorctl restart "\$PROJECT_NAME"
    sleep 2
    
    if sudo supervisorctl status "\$PROJECT_NAME" | grep -q "RUNNING"; then
        print_status "Service restarted successfully"
    else
        print_error "Service restart failed. Check logs for details."
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

view_logs() {
    print_header
    echo "Choose log type to view:"
    echo "1) Application logs"
    echo "2) Nginx access logs"
    echo "3) Nginx error logs"
    echo "4) Real-time application logs"
    echo "5) Back to main menu"
    echo ""
    
    read -p "Enter choice [1-5]: " log_choice
    
    case \$log_choice in
        1)
            sudo tail -50 "/var/log/\$PROJECT_NAME.log"
            ;;
        2)
            sudo tail -50 "/var/log/nginx/\${PROJECT_NAME}_access.log" 2>/dev/null || echo "Access log not found"
            ;;
        3)
            sudo tail -50 "/var/log/nginx/error.log"
            ;;
        4)
            echo "Press Ctrl+C to stop real-time monitoring"
            sudo tail -f "/var/log/\$PROJECT_NAME.log"
            ;;
        5)
            return
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
}

update_project() {
    print_header
    echo "Updating project from Git repository..."
    
    # Run update script as project user
    if sudo -u "\$PROJECT_USER" "\$PROJECT_DIR/update.sh"; then
        echo ""
        echo "Code updated successfully!"
        echo ""
        read -p "Restart service to apply changes? [Y/n]: " restart_choice
        restart_choice=\${restart_choice:-y}
        
        if [[ "\$restart_choice" =~ ^[Yy] ]]; then
            sudo supervisorctl restart "\$PROJECT_NAME"
            print_status "Service restarted"
        fi
    else
        print_error "Update failed. Check the output above for details."
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

manage_ssl() {
    print_header
    echo "SSL Certificate Management"
    echo "1) Install/Renew SSL certificate"
    echo "2) Check certificate status"
    echo "3) Test certificate renewal"
    echo "4) Back to main menu"
    echo ""
    
    read -p "Enter choice [1-4]: " ssl_choice
    
    case \$ssl_choice in
        1)
            echo "Installing/Renewing SSL certificate..."
            if sudo certbot --nginx -d "\$DOMAIN_NAME"; then
                print_status "SSL certificate updated successfully"
            else
                print_error "SSL certificate installation failed"
            fi
            ;;
        2)
            sudo certbot certificates
            ;;
        3)
            sudo certbot renew --dry-run
            ;;
        4)
            return
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
}

manage_firewall() {
    print_header
    echo "Firewall Management"
    echo "1) Check firewall status"
    echo "2) Check Fail2Ban status"
    echo "3) Unban IP address"
    echo "4) Back to main menu"
    echo ""
    
    read -p "Enter choice [1-4]: " fw_choice
    
    case \$fw_choice in
        1)
            sudo ufw status verbose
            ;;
        2)
            sudo fail2ban-client status
            echo ""
            sudo fail2ban-client status "nginx-\$PROJECT_NAME" 2>/dev/null || echo "No bans for this project"
            ;;
        3)
            read -p "Enter IP address to unban: " ip_address
            if [[ -n "\$ip_address" ]]; then
                sudo fail2ban-client set "nginx-\$PROJECT_NAME" unbanip "\$ip_address" 2>/dev/null || echo "IP not found or already unbanned"
            fi
            ;;
        4)
            return
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
}

backup_project() {
    print_header
    echo "Creating project backup..."
    
    BACKUP_FILE="/tmp/\${PROJECT_NAME}_backup_\$(date +%Y%m%d_%H%M%S).tar.gz"
    
    sudo tar -czf "\$BACKUP_FILE" -C "/home/\$PROJECT_USER" "\$PROJECT_NAME" 2>/dev/null
    
    if [[ -f "\$BACKUP_FILE" ]]; then
        print_status "Backup created: \$BACKUP_FILE"
        echo "Backup size: \$(du -h "\$BACKUP_FILE" | cut -f1)"
    else
        print_error "Backup creation failed"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

quick_health_check() {
    print_header
    echo "Quick Health Check:"
    echo "==================="
    
    # Service check
    if sudo supervisorctl status "\$PROJECT_NAME" | grep -q "RUNNING"; then
        echo -e "✓ Service is \${GREEN}running\${NC}"
    else
        echo -e "✗ Service is \${RED}not running\${NC}"
    fi
    
    # HTTP check
    case "\$DEPLOYMENT_TYPE" in
        "main") url="http://\$DOMAIN_NAME/" ;;
        "subdirectory") url="http://\$DOMAIN_NAME/\$PROJECT_NAME/" ;;
        "port") url="http://\$DOMAIN_NAME:\$NGINX_PORT/" ;;
    esac
    
    if curl -s -o /dev/null -w "%{http_code}" "\$url" | grep -q "200\|301\|302"; then
        echo -e "✓ Application is \${GREEN}responding\${NC}"
    else
        echo -e "✗ Application is \${RED}not responding\${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

main_menu() {
    while true; do
        print_header
        echo "Choose an option:"
        echo ""
        echo "1)  📊 Show detailed project status"
        echo "2)  🌐 Open project URLs (Copy & Test)"
        echo "3)  🔄 Restart service"
        echo "4)  📝 View logs"
        echo "5)  🔄 Update project from Git"
        echo "6)  🔒 SSL certificate management"
        echo "7)  🛡️  Firewall management"
        echo "8)  💾 Create backup"
        echo "9)  ⚡ Quick health check"
        echo "10) 🚪 Exit"
        echo ""
        
        read -p "Enter your choice [1-10]: " choice
        
        case \$choice in
            1) show_status ;;
            2) open_browser_url ;;
            3) restart_service ;;
            4) view_logs ;;
            5) update_project ;;
            6) manage_ssl ;;
            7) manage_firewall ;;
            8) backup_project ;;
            9) quick_health_check ;;
            10) 
                echo "Goodbye!"
                exit 0
                ;;
            *) 
                echo "Invalid choice. Please try again."
                sleep 2
                ;;
        esac
    done
}

# Main execution
check_permissions
main_menu
EOF

show_status() {
    print_header
    echo -e "${BLUE}Project Status:${NC}"
    echo "----------------------------------------"
    
    # Service status
    if sudo supervisorctl status "$PROJECT_NAME" | grep -q "RUNNING"; then
        echo -e "Service Status: ${GREEN}RUNNING${NC}"
        local pid=$(sudo supervisorctl status "$PROJECT_NAME" | grep -o 'pid [0-9]*' | cut -d' ' -f2)
        local uptime=$(sudo supervisorctl status "$PROJECT_NAME" | grep -o 'uptime [^,]*' | cut -d' ' -f2-)
        echo "Process ID: $pid"
        echo "Uptime: $uptime"
    else
        echo -e "Service Status: ${RED}STOPPED${NC}"
    fi
    
    # Nginx status
    if sudo systemctl is-active nginx >/dev/null 2>&1; then
        echo -e "Nginx Status: ${GREEN}RUNNING${NC}"
    else
        echo -e "Nginx Status: ${RED}STOPPED${NC}"
    fi
    
    # System resources
    echo ""
    echo -e "${BLUE}System Resources:${NC}"
    echo "----------------------------------------"
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}')
    local memory_usage=$(free | grep Mem | awk '{printf("%.1f%%", $3/$2 * 100.0)}')
    local disk_usage=$(df -h / | awk 'NR==2{print $5}')
    
    echo "CPU Usage: $cpu_usage"
    echo "Memory Usage: $memory_usage"
    echo "Disk Usage: $disk_usage"
    
    # URL information
    echo ""
    echo -e "${BLUE}Access URLs:${NC}"
    echo "----------------------------------------"
    case "$DEPLOYMENT_TYPE" in
        "main")
            echo -e "🌐 ${GREEN}HTTP:${NC}  http://$DOMAIN_NAME/"
            echo -e "🔒 ${GREEN}HTTPS:${NC} https://$DOMAIN_NAME/ ${YELLOW}(if SSL enabled)${NC}"
            echo ""
            echo -e "${CYAN}Test Commands:${NC}"
            echo "curl -I http://$DOMAIN_NAME/"
            echo "curl -I https://$DOMAIN_NAME/"
            ;;
        "subdirectory")
            echo -e "🌐 ${GREEN}HTTP:${NC}  http://$DOMAIN_NAME/$PROJECT_NAME/"
            echo -e "🔒 ${GREEN}HTTPS:${NC} https://$DOMAIN_NAME/$PROJECT_NAME/ ${YELLOW}(if SSL enabled)${NC}"
            echo ""
            echo -e "${CYAN}Test Commands:${NC}"
            echo "curl -I http://$DOMAIN_NAME/$PROJECT_NAME/"
            echo "curl -I https://$DOMAIN_NAME/$PROJECT_NAME/"
            ;;
        "port")
            echo -e "🌐 ${GREEN}HTTP:${NC}  http://$DOMAIN_NAME:$NGINX_PORT/"
            echo -e "🔒 ${GREEN}HTTPS:${NC} https://$DOMAIN_NAME:$NGINX_PORT/ ${YELLOW}(if SSL enabled)${NC}"
            echo ""
            echo -e "${CYAN}Test Commands:${NC}"
            echo "curl -I http://$DOMAIN_NAME:$NGINX_PORT/"
            echo "curl -I https://$DOMAIN_NAME:$NGINX_PORT/"
            ;;
    esac
    
    # Project information
    echo ""
    echo -e "${BLUE}Project Information:${NC}"
    echo "----------------------------------------"
    echo "Project Name: $PROJECT_NAME"
    echo "Project User: $PROJECT_USER"
    echo "Project Directory: $PROJECT_DIR"
    echo "Git Repository: $(cd "$PROJECT_DIR" 2>/dev/null && git remote get-url origin 2>/dev/null || echo 'Not available')"
    echo "Current Branch: $(cd "$PROJECT_DIR" 2>/dev/null && git branch --show-current 2>/dev/null || echo 'Not available')"
    echo "Last Commit: $(cd "$PROJECT_DIR" 2>/dev/null && git log -1 --oneline 2>/dev/null || echo 'Not available')"
    
    # Check application response
    echo ""
    echo -e "${BLUE}Application Health Check:${NC}"
    echo "----------------------------------------"
    
    case "$DEPLOYMENT_TYPE" in
        "main") test_url="http://$DOMAIN_NAME/" ;;
        "subdirectory") test_url="http://$DOMAIN_NAME/$PROJECT_NAME/" ;;
        "port") test_url="http://$DOMAIN_NAME:$NGINX_PORT/" ;;
    esac
    
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "$test_url" 2>/dev/null || echo "000")
    local response_time=$(curl -s -o /dev/null -w "%{time_total}" "$test_url" 2>/dev/null || echo "N/A")
    
    case $http_code in
        200) echo -e "HTTP Status: ${GREEN}$http_code (OK)${NC}" ;;
        301|302) echo -e "HTTP Status: ${YELLOW}$http_code (Redirect)${NC}" ;;
        404) echo -e "HTTP Status: ${RED}$http_code (Not Found)${NC}" ;;
        500|502|503) echo -e "HTTP Status: ${RED}$http_code (Server Error)${NC}" ;;
        000) echo -e "HTTP Status: ${RED}Connection Failed${NC}" ;;
        *) echo -e "HTTP Status: ${YELLOW}$http_code${NC}" ;;
    esac
    
    if [[ "$response_time" != "N/A" ]]; then
        echo "Response Time: ${response_time}s"
    fi
    
    # SSL Certificate info (if SSL is enabled)
    if [[ "$USE_SSL" == "true" ]] && command -v openssl >/dev/null; then
        echo ""
        echo -e "${BLUE}SSL Certificate Info:${NC}"
        echo "----------------------------------------"
        
        local cert_file="/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
        if [[ -f "$cert_file" ]]; then
            local cert_expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
            local days_left=$(echo "($(($(date -d "$cert_expiry" +%s) - $(date +%s))) / 86400)" | bc 2>/dev/null || echo "N/A")
            
            echo "Certificate Expires: $cert_expiry"
            if [[ "$days_left" != "N/A" ]]; then
                if [[ $days_left -gt 30 ]]; then
                    echo -e "Days Remaining: ${GREEN}$days_left days${NC}"
                elif [[ $days_left -gt 7 ]]; then
                    echo -e "Days Remaining: ${YELLOW}$days_left days${NC}"
                else
                    echo -e "Days Remaining: ${RED}$days_left days (Renewal needed!)${NC}"
                fi
            fi
        else
            echo -e "${RED}SSL certificate not found${NC}"
        fi
    fi
    
    echo ""
    echo -e "${BLUE}Recent Logs (last 5 lines):${NC}"
    echo "----------------------------------------"
    sudo tail -5 "/var/log/$PROJECT_NAME.log" 2>/dev/null || echo "No logs available"
    
    echo ""
    read -p "Press Enter to continue..."
}

restart_service() {
    print_header
    echo "Restarting $PROJECT_NAME service..."
    
    sudo supervisorctl restart "$PROJECT_NAME"
    sleep 2
    
    if sudo supervisorctl status "$PROJECT_NAME" | grep -q "RUNNING"; then
        print_status "Service restarted successfully"
    else
        print_error "Service restart failed. Check logs for details."
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

view_logs() {
    print_header
    echo "Choose log type to view:"
    echo "1) Application logs"
    echo "2) Nginx access logs"
    echo "3) Nginx error logs"
    echo "4) Real-time application logs"
    echo "5) Back to main menu"
    echo ""
    
    read -p "Enter choice [1-5]: " log_choice
    
    case $log_choice in
        1)
            sudo tail -50 "/var/log/$PROJECT_NAME.log"
            ;;
        2)
            sudo tail -50 "/var/log/nginx/${PROJECT_NAME}_access.log" 2>/dev/null || echo "Access log not found"
            ;;
        3)
            sudo tail -50 "/var/log/nginx/error.log"
            ;;
        4)
            echo "Press Ctrl+C to stop real-time monitoring"
            sudo tail -f "/var/log/$PROJECT_NAME.log"
            ;;
        5)
            return
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
}

update_project() {
    print_header
    echo "Updating project from Git repository..."
    
    # Run update script as project user
    if sudo -u "$PROJECT_USER" "$PROJECT_DIR/update.sh"; then
        echo ""
        echo "Code updated successfully!"
        echo ""
        read -p "Restart service to apply changes? [Y/n]: " restart_choice
        restart_choice=${restart_choice:-y}
        
        if [[ "$restart_choice" =~ ^[Yy] ]]; then
            sudo supervisorctl restart "$PROJECT_NAME"
            print_status "Service restarted"
        fi
    else
        print_error "Update failed. Check the output above for details."
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

manage_ssl() {
    print_header
    echo "SSL Certificate Management"
    echo "1) Install/Renew SSL certificate"
    echo "2) Check certificate status"
    echo "3) Test certificate renewal"
    echo "4) Back to main menu"
    echo ""
    
    read -p "Enter choice [1-4]: " ssl_choice
    
    case $ssl_choice in
        1)
            echo "Installing/Renewing SSL certificate..."
            if sudo certbot --nginx -d "$DOMAIN_NAME"; then
                print_status "SSL certificate updated successfully"
            else
                print_error "SSL certificate installation failed"
            fi
            ;;
        2)
            sudo certbot certificates
            ;;
        3)
            sudo certbot renew --dry-run
            ;;
        4)
            return
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
}

manage_firewall() {
    print_header
    echo "Firewall Management"
    echo "1) Check firewall status"
    echo "2) Check Fail2Ban status"
    echo "3) Unban IP address"
    echo "4) Back to main menu"
    echo ""
    
    read -p "Enter choice [1-4]: " fw_choice
    
    case $fw_choice in
        1)
            sudo ufw status verbose
            ;;
        2)
            sudo fail2ban-client status
            echo ""
            sudo fail2ban-client status "nginx-$PROJECT_NAME" 2>/dev/null || echo "No bans for this project"
            ;;
        3)
            read -p "Enter IP address to unban: " ip_address
            if [[ -n "$ip_address" ]]; then
                sudo fail2ban-client set "nginx-$PROJECT_NAME" unbanip "$ip_address" 2>/dev/null || echo "IP not found or already unbanned"
            fi
            ;;
        4)
            return
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
}

backup_project() {
    print_header
    echo "Creating project backup..."
    
    BACKUP_FILE="/tmp/${PROJECT_NAME}_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    sudo tar -czf "$BACKUP_FILE" -C "/home/$PROJECT_USER" "$PROJECT_NAME" 2>/dev/null
    
    if [[ -f "$BACKUP_FILE" ]]; then
        print_status "Backup created: $BACKUP_FILE"
        echo "Backup size: $(du -h "$BACKUP_FILE" | cut -f1)"
    else
        print_error "Backup creation failed"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

main_menu() {
    while true; do
        print_header
        echo "Choose an option:"
        echo ""
        echo "1)  📊 Show detailed project status & URLs"
        echo "2)  🔄 Restart service"
        echo "3)  📝 View logs"
        echo "4)  🔄 Update project from Git"
        echo "5)  🔒 SSL certificate management"
        echo "6)  🛡️  Firewall management"
        echo "7)  💾 Create backup"
        echo "8)  ⚡ Quick health check"
        echo "9)  🌐 Test application URLs"
        echo "10) 📋 Show project information"
        echo "11) 🔧 Advanced troubleshooting"
        echo "12) 🚪 Exit"
        echo ""
        
        read -p "Enter your choice [1-12]: " choice
        
        case $choice in
            1) show_status ;;
            2) restart_service ;;
            3) view_logs ;;
            4) update_project ;;
            5) manage_ssl ;;
            6) manage_firewall ;;
            7) backup_project ;;
            8) quick_health_check ;;
            9) test_urls ;;
            10) show_project_info ;;
            11) advanced_troubleshooting ;;
            12) 
                echo "Goodbye!"
                exit 0
                ;;
            *) 
                echo "Invalid choice. Please try again."
                sleep 2
                ;;
        esac
    done
}

quick_health_check() {
    print_header
    echo "Quick Health Check:"
    echo "==================="
    
    # Service check
    if sudo supervisorctl status "$PROJECT_NAME" | grep -q "RUNNING"; then
        echo -e "✓ Service is ${GREEN}running${NC}"
    else
        echo -e "✗ Service is ${RED}not running${NC}"
    fi
    
    # HTTP check
    case "$DEPLOYMENT_TYPE" in
        "main") url="http://$DOMAIN_NAME/" ;;
        "subdirectory") url="http://$DOMAIN_NAME/$PROJECT_NAME/" ;;
        "port") url="http://$DOMAIN_NAME:$NGINX_PORT/" ;;
    esac
    
    if curl -s -o /dev/null -w "%{http_code}" "$url" | grep -q "200\|301\|302"; then
        echo -e "✓ Application is ${GREEN}responding${NC}"
    else
        echo -e "✗ Application is ${RED}not responding${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

test_urls() {
    print_header
    echo "Testing Application URLs"
    echo "========================"
    
    # Determine URLs based on deployment type
    local http_url=""
    local https_url=""
    
    case "$DEPLOYMENT_TYPE" in
        "main")
            http_url="http://$DOMAIN_NAME/"
            https_url="https://$DOMAIN_NAME/"
            ;;
        "subdirectory")
            http_url="http://$DOMAIN_NAME/$PROJECT_NAME/"
            https_url="https://$DOMAIN_NAME/$PROJECT_NAME/"
            ;;
        "port")
            http_url="http://$DOMAIN_NAME:$NGINX_PORT/"
            https_url="https://$DOMAIN_NAME:$NGINX_PORT/"
            ;;
    esac
    
    echo -e "${BLUE}Testing URLs for $PROJECT_NAME:${NC}"
    echo "----------------------------------------"
    
    # Test HTTP
    echo -n "Testing HTTP ($http_url): "
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "$http_url" 2>/dev/null || echo "000")
    local response_time=$(curl -s -o /dev/null -w "%{time_total}" "$http_url" 2>/dev/null || echo "N/A")
    
    case $http_code in
        200) echo -e "${GREEN}OK ($http_code)${NC} - Response time: ${response_time}s" ;;
        301|302) echo -e "${YELLOW}Redirect ($http_code)${NC} - Response time: ${response_time}s" ;;
        404) echo -e "${RED}Not Found ($http_code)${NC}" ;;
        500|502|503) echo -e "${RED}Server Error ($http_code)${NC}" ;;
        000) echo -e "${RED}Connection Failed${NC}" ;;
        *) echo -e "${YELLOW}Unexpected ($http_code)${NC}" ;;
    esac
    
    # Test HTTPS if SSL is enabled
    if [[ "$USE_SSL" == "true" ]]; then
        echo -n "Testing HTTPS ($https_url): "
        local https_code=$(curl -s -o /dev/null -w "%{http_code}" "$https_url" 2>/dev/null || echo "000")
        local https_response_time=$(curl -s -o /dev/null -w "%{time_total}" "$https_url" 2>/dev/null || echo "N/A")
        
        case $https_code in
            200) echo -e "${GREEN}OK ($https_code)${NC} - Response time: ${https_response_time}s" ;;
            301|302) echo -e "${YELLOW}Redirect ($https_code)${NC} - Response time: ${https_response_time}s" ;;
            404) echo -e "${RED}Not Found ($https_code)${NC}" ;;
            500|502|503) echo -e "${RED}Server Error ($https_code)${NC}" ;;
            000) echo -e "${RED}Connection Failed${NC}" ;;
            *) echo -e "${YELLOW}Unexpected ($https_code)${NC}" ;;
        esac
    else
        echo "HTTPS: Not configured"
    fi
    
    # Show copy-paste ready URLs
    echo ""
    echo -e "${CYAN}📋 Copy these URLs to test in your browser:${NC}"
    echo "HTTP:  $http_url"
    if [[ "$USE_SSL" == "true" ]]; then
        echo "HTTPS: $https_url"
    fi
    
    # Show curl commands for testing
    echo ""
    echo -e "${CYAN}🧪 Test commands you can run:${NC}"
    echo "curl -v $http_url"
    if [[ "$USE_SSL" == "true" ]]; then
        echo "curl -v $https_url"
    fi
    echo "curl -I $http_url  # Headers only"
    
    echo ""
    read -p "Press Enter to continue..."
}

show_project_info() {
    print_header
    echo "Project Information"
    echo "==================="
    
    echo -e "${BLUE}Basic Information:${NC}"
    echo "----------------------------------------"
    echo "Project Name: $PROJECT_NAME"
    echo "Project User: $PROJECT_USER"
    echo "Project Directory: $PROJECT_DIR"
    echo "Domain Name: $DOMAIN_NAME"
    echo "Deployment Type: $DEPLOYMENT_TYPE"
    if [[ "$DEPLOYMENT_TYPE" == "port" ]]; then
        echo "Custom Port: $NGINX_PORT"
    fi
    echo "SSL Enabled: $USE_SSL"
    echo "Security Setup: $SETUP_SECURITY"
    
    echo ""
    echo -e "${BLUE}Git Information:${NC}"
    echo "----------------------------------------"
    if cd "$PROJECT_DIR" 2>/dev/null; then
        echo "Repository: $(git remote get-url origin 2>/dev/null || echo 'Not available')"
        echo "Current Branch: $(git branch --show-current 2>/dev/null || echo 'Not available')"
        echo "Last Commit: $(git log -1 --oneline 2>/dev/null || echo 'Not available')"
        echo "Status: $(git status --porcelain | wc -l) modified files"
    else
        echo "Git information not available"
    fi
    
    echo ""
    echo -e "${BLUE}File Locations:${NC}"
    echo "----------------------------------------"
    echo "Project Files: $PROJECT_DIR"
    echo "Nginx Config: /etc/nginx/sites-available/$PROJECT_NAME"
    echo "Supervisor Config: /etc/supervisor/conf.d/$PROJECT_NAME.conf"
    echo "Application Log: /var/log/$PROJECT_NAME.log"
    echo "Nginx Access Log: /var/log/nginx/${PROJECT_NAME}_access.log"
    echo "Update Script: $PROJECT_DIR/update.sh"
    
    echo ""
    echo -e "${BLUE}Service Information:${NC}"
    echo "----------------------------------------"
    local service_status=$(sudo supervisorctl status "$PROJECT_NAME" 2>/dev/null || echo "Not found")
    echo "Supervisor Status: $service_status"
    
    if command -v systemctl >/dev/null; then
        echo "Nginx Status: $(sudo systemctl is-active nginx 2>/dev/null || echo 'Unknown')"
        if [[ "$SETUP_SECURITY" == "true" ]]; then
            echo "Fail2Ban Status: $(sudo systemctl is-active fail2ban 2>/dev/null || echo 'Unknown')"
            echo "Firewall Status: $(sudo ufw status | grep -o 'Status: [a-zA-Z]*' || echo 'Unknown')"
        fi
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

advanced_troubleshooting() {
    print_header
    echo "Advanced Troubleshooting"
    echo "========================"
    echo ""
    echo "1) Check service logs (detailed)"
    echo "2) Check Nginx configuration"
    echo "3) Check socket file status"
    echo "4) Check port availability"
    echo "5) Check process list"
    echo "6) Check disk space"
    echo "7) Restart all services"
    echo "8) Back to main menu"
    echo ""
    
    read -p "Enter choice [1-8]: " trouble_choice
    
    case $trouble_choice in
        1)
            echo ""
            echo "=== Service Logs ==="
            sudo tail -50 "/var/log/$PROJECT_NAME.log"
            echo ""
            echo "=== Supervisor Logs ==="
            sudo tail -20 "/var/log/supervisor/supervisord.log"
            ;;
        2)
            echo ""
            echo "=== Testing Nginx Configuration ==="
            sudo nginx -t
            echo ""
            echo "=== Nginx Error Log ==="
            sudo tail -20 /var/log/nginx/error.log
            ;;
        3)
            echo ""
            echo "=== Socket File Status ==="
            ls -la "$PROJECT_DIR/run/" 2>/dev/null || echo "Run directory not found"
            echo ""
            echo "=== Socket Permissions ==="
            ls -la "$PROJECT_DIR/run/gunicorn.sock" 2>/dev/null || echo "Socket file not found"
            ;;
        4)
            echo ""
            echo "=== Port Status ==="
            case "$DEPLOYMENT_TYPE" in
                "port")
                    sudo netstat -tulpn | grep ":$NGINX_PORT"
                    ;;
                *)
                    sudo netstat -tulpn | grep -E ":80|:443"
                    ;;
            esac
            echo ""
            echo "=== All Listening Ports ==="
            sudo ss -tulpn
            ;;
        5)
            echo ""
            echo "=== Project Processes ==="
            ps aux | grep -E "$PROJECT_NAME|gunicorn" | grep -v grep
            echo ""
            echo "=== Nginx Processes ==="
            ps aux | grep nginx | grep -v grep
            ;;
        6)
            echo ""
            echo "=== Disk Space ==="
            df -h
            echo ""
            echo "=== Log File Sizes ==="
            du -h /var/log/*.log | head -10
            ;;
        7)
            echo ""
            echo "Restarting all services..."
            sudo supervisorctl restart "$PROJECT_NAME"
            sudo systemctl reload nginx
            if [[ "$SETUP_SECURITY" == "true" ]]; then
                sudo systemctl restart fail2ban
            fi
            echo "All services restarted."
            ;;
        8)
            return
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
}
EOF
    
    chmod +x "$SCRIPT_DIR/manage_$PROJECT_NAME.sh"
    
    print_status "Management scripts created successfully"
}

# Function to perform final checks and display summary
final_summary() {
    print_header "Deployment Summary"
    
    echo -e "${GREEN}✓ Flask project deployed successfully!${NC}"
    echo ""
    echo -e "${BLUE}Project Details:${NC}"
    echo "----------------------------------------"
    echo "Project Name: $PROJECT_NAME"
    echo "Project User: $PROJECT_USER"
    echo "Project Directory: $PROJECT_DIR"
    echo "Domain: $DOMAIN_NAME"
    echo "Deployment Type: $DEPLOYMENT_TYPE"
    
    # Show access URLs
    echo ""
    echo -e "${BLUE}Access your application at:${NC}"
    case "$DEPLOYMENT_TYPE" in
        "main")
            echo "• HTTP:  http://$DOMAIN_NAME/"
            if [[ "$USE_SSL" == "true" ]]; then
                echo "• HTTPS: https://$DOMAIN_NAME/"
            fi
            ;;
        "subdirectory")
            echo "• HTTP:  http://$DOMAIN_NAME/$PROJECT_NAME/"
            if [[ "$USE_SSL" == "true" ]]; then
                echo "• HTTPS: https://$DOMAIN_NAME/$PROJECT_NAME/"
            fi
            ;;
        "port")
            echo "• HTTP:  http://$DOMAIN_NAME:$NGINX_PORT/"
            if [[ "$USE_SSL" == "true" ]]; then
                echo "• HTTPS: https://$DOMAIN_NAME:$NGINX_PORT/"
            fi
            ;;
    esac
    
    echo ""
    echo -e "${BLUE}Management:${NC}"
    echo "• Run management menu: $SCRIPT_DIR/manage_$PROJECT_NAME.sh"
    echo "• Update project: sudo -u $PROJECT_USER $PROJECT_DIR/update.sh"
    echo "• Restart service: sudo supervisorctl restart $PROJECT_NAME"
    echo "• View logs: sudo tail -f /var/log/$PROJECT_NAME.log"
    
    echo ""
    echo -e "${BLUE}Important Files:${NC}"
    echo "• Configuration: $CONFIG_FILE"
    echo "• Management script: $SCRIPT_DIR/manage_$PROJECT_NAME.sh"
    echo "• Nginx config: /etc/nginx/sites-available/$PROJECT_NAME"
    echo "• Supervisor config: /etc/supervisor/conf.d/$PROJECT_NAME.conf"
    echo "• Application logs: /var/log/$PROJECT_NAME.log"
    
    # Check service status
    echo ""
    echo -e "${BLUE}Current Status:${NC}"
    if sudo supervisorctl status "$PROJECT_NAME" | grep -q "RUNNING"; then
        echo -e "• Service: ${GREEN}RUNNING${NC}"
    else
        echo -e "• Service: ${RED}STOPPED${NC}"
    fi
    
    if sudo systemctl is-active nginx >/dev/null 2>&1; then
        echo -e "• Nginx: ${GREEN}RUNNING${NC}"
    else
        echo -e "• Nginx: ${RED}STOPPED${NC}"
    fi
    
    if [[ "$SETUP_SECURITY" == "true" ]]; then
        if sudo systemctl is-active fail2ban >/dev/null 2>&1; then
            echo -e "• Fail2Ban: ${GREEN}RUNNING${NC}"
        else
            echo -e "• Fail2Ban: ${RED}STOPPED${NC}"
        fi
        
        if sudo ufw status | grep -q "Status: active"; then
            echo -e "• Firewall: ${GREEN}ACTIVE${NC}"
        else
            echo -e "• Firewall: ${RED}INACTIVE${NC}"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}Next Steps:${NC}"
    echo "1. Test your application by visiting the URL above"
    echo "2. Run the management script: $SCRIPT_DIR/manage_$PROJECT_NAME.sh"
    echo "3. Check logs if there are any issues"
    echo "4. Setup your domain DNS if using a custom domain"
    
    if [[ "$USE_SSL" == "true" ]] && [[ "$DOMAIN_NAME" != "$(curl -s ifconfig.me)" ]]; then
        echo ""
        echo -e "${YELLOW}SSL Note:${NC} Make sure your domain points to this server's IP address"
        echo "Current server IP: $(curl -s ifconfig.me)"
    fi
}

# Function to run quick deployment
quick_deploy() {
    print_header "Quick Deployment Mode"
    
    # Use defaults for quick deployment
    PROJECT_NAME="flask-app"
    PROJECT_USER="flaskuser"
    DOMAIN_NAME="$(curl -s ifconfig.me)"
    GIT_REPO=""
    FLASK_APP_FILE="app.py"
    FLASK_APP_VAR="app"
    USE_SSL="false"
    SETUP_SECURITY="true"
    DEPLOYMENT_TYPE="main"
    NGINX_PORT="8080"
    PROJECT_DIR="/home/$PROJECT_USER/$PROJECT_NAME"
    
    echo "Quick deployment will use these defaults:"
    echo "• Project name: $PROJECT_NAME"
    echo "• User: $PROJECT_USER"
    echo "• Domain: $DOMAIN_NAME"
    echo "• SSL: Disabled"
    echo "• Security: Enabled"
    echo ""
    
    get_input "Git repository URL" "" GIT_REPO
    if [[ -z "$GIT_REPO" ]]; then
        print_error "Git repository URL is required"
        exit 1
    fi
    
    get_yes_no "Proceed with quick deployment?" "y" proceed
    if [[ "$proceed" != "true" ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
}

# Main deployment function
main_deploy() {
    print_header "Flask Auto-Deploy Script"
    echo "This script will automatically deploy a Flask application with:"
    echo "• User creation and project setup"
    echo "• Gunicorn + Supervisor configuration"
    echo "• Nginx reverse proxy setup"
    echo "• Optional SSL certificate (Let's Encrypt)"
    echo "• Optional security hardening (Fail2Ban, Firewall)"
    echo "• Management scripts for maintenance"
    echo ""
    
    # Check if this is a rerun with existing config
    if load_config; then
        print_status "Found existing configuration for project: $PROJECT_NAME"
        get_yes_no "Use existing configuration?" "y" use_existing
        
        if [[ "$use_existing" != "true" ]]; then
            collect_deployment_info
            save_config
        fi
    else
        collect_deployment_info
        save_config
    fi
    
    # Confirm deployment
    echo ""
    echo -e "${YELLOW}Deployment Summary:${NC}"
    echo "• Project: $PROJECT_NAME"
    echo "• User: $PROJECT_USER"
    echo "• Domain: $DOMAIN_NAME"
    echo "• Repository: $GIT_REPO"
    echo "• Type: $DEPLOYMENT_TYPE"
    echo "• SSL: $USE_SSL"
    echo "• Security: $SETUP_SECURITY"
    echo ""
    
    get_yes_no "Proceed with deployment?" "y" proceed
    if [[ "$proceed" != "true" ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
    
    # Run deployment steps
    install_dependencies
    create_project_user
    setup_project
    create_gunicorn_script
    setup_supervisor
    setup_nginx
    setup_ssl
    setup_security
    create_management_scripts
    
    # Save final configuration
    save_config
    
    # Show summary
    final_summary
    
    echo ""
    echo -e "${GREEN}Deployment completed successfully!${NC}"
    echo ""
    get_yes_no "Open management menu now?" "y" open_menu
    if [[ "$open_menu" == "true" ]]; then
        exec "$SCRIPT_DIR/manage_$PROJECT_NAME.sh"
    fi
}

# Script entry point
main() {
    # Check prerequisites
    check_root
    check_sudo
    
    # Parse command line arguments
    case "${1:-}" in
        "--quick")
            quick_deploy
            main_deploy
            ;;
        "--manage")
            if load_config; then
                exec "$SCRIPT_DIR/manage_$PROJECT_NAME.sh"
            else
                print_error "No deployment configuration found. Run deployment first."
                exit 1
            fi
            ;;
        "--help"|"-h")
            echo "Flask Auto-Deploy Script"
            echo ""
            echo "Usage:"
            echo "  $0                 Interactive deployment"
            echo "  $0 --quick         Quick deployment with minimal prompts"
            echo "  $0 --manage        Open management menu"
            echo "  $0 --help          Show this help"
            echo ""
            echo "Features:"
            echo "• Automated Flask app deployment"
            echo "• SSL certificate setup (Let's Encrypt)"
            echo "• Security hardening (Fail2Ban, UFW)"
            echo "• Multiple deployment types (main, subdirectory, port)"
            echo "• Management menu for maintenance"
            echo "• Automatic updates from Git"
            echo ""
            exit 0
            ;;
        "")
            main_deploy
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
