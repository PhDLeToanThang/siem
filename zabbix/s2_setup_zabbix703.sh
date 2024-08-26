# Ref: https://www.zabbix.com/download?zabbix=7.0&os_distribution=ubuntu&os_version=24.04&components=server_frontend_agent&db=mysql&ws=apache
#	Zabbix 7.0.3 LTS / Ubuntu 24.04 LTS 
#	Deploy Server, FrontEnd , Agent Funcations
#	MySQL, MariaDB, PHPmyAdmin
#   NGINX
#	SSMTP
###########################################




# Step 3. Install and configure Zabbix for your platform
sudo -s

wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-2+ubuntu24.04_all.deb
dpkg -i zabbix-release_7.0-2+ubuntu24.04_all.deb
sudo apt update -your


# Step 4. Install Zabbix server, frontend, agent
sudo apt install zabbix-server-mysql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts zabbix-agent

# Step 5. Create initial database:
 mysql -uroot -p
password
mysql> create database zabbix character set utf8mb4 collate utf8mb4_bin;
mysql> create user zabbix@localhost identified by 'password';
mysql> grant all privileges on zabbix.* to zabbix@localhost;
mysql> set global log_bin_trust_function_creators = 1;
mysql> quit;


#On Zabbix server host import initial schema and data. You will be prompted to enter your newly created password.

zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -uzabbix -p zabbix

#Disable log_bin_trust_function_creators option after importing database schema.


mysql -uroot -p
password
mysql> set global log_bin_trust_function_creators = 0;
mysql> quit;

#Configure the database for Zabbix server
nano /etc/zabbix/zabbix_server.conf

DBPassword=password

#Configure PHP for Zabbix frontend
Edit file /etc/zabbix/nginx.conf uncomment and set 'listen' and 'server_name' directives.

listen 8080;
server_name example.com;

# Start Zabbix server and agent processes
# Start Zabbix server and agent processes and make it start at system boot.

systemctl restart zabbix-server zabbix-agent nginx php8.3-fpm
systemctl enable zabbix-server zabbix-agent nginx php8.3-fpm

#h. Open Zabbix UI web page
#The URL for Zabbix UI when using Nginx depends on the configuration changes you should have made.

