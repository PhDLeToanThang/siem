# Ref: https://www.zabbix.com/download?zabbix=7.0&os_distribution=ubuntu&os_version=24.04&components=server_frontend_agent&db=mysql&ws=apache
#	Zabbix 7.0.3 LTS / Ubuntu 24.04.1 LTS 
#	Deploy Server, FrontEnd , Agent Funcations
#	MySQL 5.6, MariaDB 10., PHPmyAdmin  5.2.1
#   NGINX 1.2.4
#	SSMTP 1.2.1
###########################################
# Step 1. var
############### Tham số cần thay đổi ở đây ###################
echo "FQDN: e.g: demo.company.vn"   # Đổi địa chỉ web thứ nhất Website Master for Resource code - để tạo cùng 1 Source code duy nhất 
read -e FQDN
echo "DBName: e.g: zabbix"   # Tên DBNane
read -e dbname
echo "DBUser: e.g: zabbix"   # Tên DBUser access DB
read -e dbuser
echo "DBPassword Password: e.g: P@$$w0rd-1.22"
read -s dbpass
echo "phpmyadmin folder name: e.g: phpmyadmin"   # Đổi tên thư mục phpmyadmin khi add link symbol vào Website 
read -e phpmyadmin
echo "Zabbix Folder Data: e.g: zabbixdata"   # Tên Thư mục chưa Data vs Cache
read -e FOLDERDATA
echo "DBType name: e.g: mariadb"   # Tên kiểu Database
read -e dbtype
echo "DBHost name: e.g: localhost"   # Tên Db host connector
read -e dbhost
echo "Your Email address for Certbot e.g: thang@company.vn" # Địa chỉ email của bạn để quản lý CA
read -e emailcertbot
echo "Your Email address for Gmail/pavn SMTP Replay Notification e.g: support_company gmail" 
# Địa chỉ email email của bạn để quản lý thông báo từ Zabbix gửi đi, chỉ dùng cho gmail (Yahoo, MSO365 không cần)
read -e emailgmail
echo "Gmail Password: e.g: Password realtime of Gmail"
read -s gmailpass

GitZabbixversion="zabbix-release_7.0-2+ubuntu24.04_all.deb"

echo "run install? (y/n)"
read -e run
if [ "$run" == n ] ; then
  exit
else

# step 1. install nginx, libs, SSMTP
sudo apt-get update -y
sudo apt-get install nginx -y
sudo systemctl stop nginx.service
sudo systemctl start nginx.service
sudo systemctl enable nginx.service

# Step 2. Install ssmtp relay gmail and configure ssmtp email address for notification
sudo apt-get -y install ssmtp mailutils 

# Edit ####################################
#File cấu hình SSMTP : /etc/ssmtp/ssmtp.conf
# Config file for sSMTP sendmail
# The person who gets all mail for userids < 1000
# Make this empty to disable rewriting.
# root=postmaster
#The place where the mail goes. The actual machine name is required no
#MX records are consulted. Commonly mailhosts are named mail.domain.com
#mailhub=mail
# Where will the mail seem to come from?
#rewriteDomain=
# The full hostname
# Are users allowed to set their own From: address?
# YES - Allow the user to specify their own From: address
# NO - Use the system generated From: address
# Xoa trang va Thêm dòng
cat > /etc/ssmtp/ssmtp.conf <<END
END

echo "root=${emailgmail}"  >> /etc/ssmtp/ssmtp.conf
echo "mailhub=smtp.gmail.com:587" >> /etc/ssmtp/ssmtp.conf
echo "AuthUser=${emailgmail}" >> /etc/ssmtp/ssmtp.conf
echo "AuthPass=${gmailpass}" >> /etc/ssmtp/ssmtp.conf
echo "UseTLS=YES" >> /etc/ssmtp/ssmtp.conf
echo "UseSTARTTLS=YES" >> /etc/ssmtp/ssmtp.conf
echo "rewriteDomain=gmail.com" >> /etc/ssmtp/ssmtp.conf
echo "hostname=ssmtpServer"
echo "FromLineOverride=YES"

# Cho phép ứng dụng truy cập gmail, 
#Nếu bạn sử dụng gmail làm địa chỉ người gửi thì bạn phải cho phép ứng dụng truy cập gmail của bạn
# Đăng nhập bằng gmail để thực hiện gửi mail đã khai báo bên trên trên trình duyệt và truy cập vào địa chỉ sau:
# https://myaccount.google.com/lesssecureapps
# Bật chế độ cho phép ứng dụng truy cập
# Tạo alias cho user local. Mở file sau và sửa
# Edit /etc/ssmtp/revaliases
# Xoa trang va Thêm dòng
cat > /etc/ssmtp/revaliases <<END
END
echo "root:${emailgmail}:smtp.gmail.com:587" >> /etc/ssmtp/revaliases

# Step 3. Install and configure Zabbix for your platform
sudo wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/$GitZabbixversion
dpkg -i $GitZabbixversion
sudo apt update -your


# Step 4. Install Zabbix server, frontend, agent
sudo apt -y install zabbix-server-mysql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts zabbix-agent2 php-mysql php-gd php-bcmath php-net-socket

# Step 5. Create initial database:
#Run the following commands to install MariaDB database for Moode. You may also use MySQL instead.

sudo apt-get install mariadb-server mariadb-client -y

#we will run the following commands to enable MariaDB to autostart during reboot, and also start now.
sudo systemctl stop mysql.service 
sudo systemctl start mysql.service 
sudo systemctl enable mysql.service

#Run the following command to secure MariaDB installation.
#password mysql mariadb , i'm fixed: M@tKh@uS3cr3t  --> you must changit. 

sudo mysql_secure_installation  <<EOF
n
M@tKh@uS3cr3t
M@tKh@uS3cr3t
y
n
y
y
EOF
#You will see the following prompts asking to allow/disallow different type of logins. Enter Y as shown.
# Enter current password for root (enter for none): Just press the Enter
# Set root password? [Y/n]: Y
# New password: Enter password
# Re-enter new password: Repeat password
# Remove anonymous users? [Y/n]: Y
# Disallow root login remotely? [Y/n]: N
# Remove test database and access to it? [Y/n]:  Y
# Reload privilege tables now? [Y/n]:  Y
# After you enter response for these questions, your MariaDB installation will be secured.

#Step 6. Install PHP-FPM & Related modules
sudo apt-get install software-properties-common -y
sudo -S add-apt-repository ppa:ondrej/php -y
sudo apt update -y
sudo apt install php8.3-fpm php8.3-common php8.3-mbstring php8.3-xmlrpc php8.3-soap php8.3-gd php8.3-xml php8.3-intl php8.3-mysql php8.3-cli php8.3-mcrypt php8.3-ldap php8.3-zip php8.3-curl -y

#Open PHP-FPM config file.

#sudo nano /etc/php/8.3/fpm/php.ini
#Add/Update the values as shown. You may change it as per your requirement.
cat > /etc/php/8.3/fpm/php.ini <<END
file_uploads = On
allow_url_fopen = On
memory_limit = 1200M
upload_max_filesize = 4096M
max_execution_time = 360
cgi.fix_pathinfo = 0
date.timezone = asia/ho_chi_minh
max_input_time = 60
max_input_nesting_level = 64
max_input_vars = 5000
post_max_size = 4096M
END
systemctl restart php8.3-fpm.service

#Step 7. Create Zabbix Database
#Log into MySQL and create database for Zabbix.

# install tool mysql-workbench-community from Tonin Bolzan (tonybolzan)
sudo snap install mysql-workbench-community

mysql -uroot -prootpassword -e "DROP DATABASE IF EXISTS ${dbname};"
mysql -uroot -prootpassword -e "CREATE DATABASE IF NOT EXISTS ${dbname} CHARACTER SET utf8 COLLATE utf8_unicode_ci;"
mysql -uroot -prootpassword -e "CREATE USER IF NOT EXISTS '${dbuser}'@'${dbhost}' IDENTIFIED BY \"${dbpass}\";"
mysql -uroot -prootpassword -e "GRANT ALL PRIVILEGES ON ${dbname}.* TO '${dbuser}'@'${dbhost}';"
mysql -uroot -prootpassword -e "set global log_bin_trust_function_creators = 1;"
mysql -uroot -prootpassword -e "FLUSH PRIVILEGES;"
mysql -uroot -prootpassword -e "SHOW DATABASES;"

#Step 8. Next, edit the MariaDB default configuration file and define the innodb_file_format:
#nano /etc/mysql/mariadb.conf.d/50-server.cnf
#Add the following lines inside the [mysqld] section: 
cat > /etc/mysql/mariadb.conf.d/50-server.cnf <<END
[mysqld]
innodb_file_format = Barracuda
innodb_file_per_table = 1
innodb_large_prefix = ON
END

#Save the file then restart the MariaDB service to apply the changes.
systemctl restart mariadb

#Step 9. 
#On Zabbix server host import initial schema and data. You will be prompted to enter your newly created password.
 # the password you set above for [zabbix] user
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -uzabbix -p zabbix 

#Disable log_bin_trust_function_creators option after importing database schema.
#Configure the database for Zabbix server  /etc/zabbix/zabbix_server.conf
#set database details with perl find and replace
cat > /etc/zabbix/zabbix_server.conf <<END
END
echo "DBName=${dbname}" >> /etc/zabbix/zabbix_server.conf
echo "DBUser=${dbuser}" >> /etc/zabbix/zabbix_server.conf
echo "DBHost=${dbhost}" >>  /etc/zabbix/zabbix_server.conf
echo "DBPassword=${dbpass}" >> /etc/zabbix/zabbix_server.conf
echo "LogFile=/var/log/zabbix/zabbix_server.log" >> /etc/zabbix/zabbix_server.conf
echo "LogFileSize=0" >> /etc/zabbix/zabbix_server.conf
echo "PidFile=/run/zabbix/zabbix_serer.pid" >> /etc/zabbix/zabbix_server.conf
echo "SocketDir=/run/zabbix" >> /etc/zabbix/zabbix_server.conf
echo "SNMPTrapperFile=/var/log/snmptrap/snmptrap.log" >> /etc/zabbix/zabbix_server.conf
echo "Timeout=4" >> /etc/zabbix/zabbix_server.conf
echo "FpingLocation=/usr/bin/fping" >> /etc/zabbix/zabbix_server.conf
echo "Fping6Location=/usr/bin/fping6" >> /etc/zabbix/zabbix_server.conf
echo "LogSlowQueries=3000" >> /etc/zabbix/zabbix_server.conf
echo "StatsAllowedIP=127.0.0.1" >> /etc/zabbix/zabbix_server.conf
echo "EnableGlobalScripts=0" >> /etc/zabbix/zabbix_server.conf

#Step 10. Configure PHP for Zabbix frontend /etc/hosts
# line 1 : specify Zabbix server
echo "127.0.0.1 ${FQDN}" >> /etc/hosts

cat > /etc/nginx/conf.d/${FQDN}.conf <<END
END

echo 'server {'  >> /etc/nginx/conf.d/${FQDN}.conf
echo '    listen 80;' >> /etc/nginx/conf.d/${FQDN}.conf
echo '    server_name '$FQDN';'>> /etc/nginx/conf.d/${FQDN}.conf
echo '    root /usr/share/zabbix;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '    index  index.php;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '    client_max_body_size 512M;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '    autoindex off;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '    location / {'>> /etc/nginx/conf.d/${FQDN}.conf
echo '        try_files $uri $uri/ =404;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '    }'>> /etc/nginx/conf.d/${FQDN}.conf
echo '    location /dataroot/ {'>> /etc/nginx/conf.d/${FQDN}.conf
echo '      internal;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '      alias /var/www/html/;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '    }'>> /etc/nginx/conf.d/${FQDN}.conf
echo '    location ~ [^/].php(/|$) {'>> /etc/nginx/conf.d/${FQDN}.conf
echo '        include snippets/fastcgi-php.conf;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '        fastcgi_pass unix:/run/php/php8.3-fpm.sock;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '        include fastcgi_params;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '    }'>> /etc/nginx/conf.d/${FQDN}.conf
echo '	location ~ ^/(doc|sql|setup)/{'>> /etc/nginx/conf.d/${FQDN}.conf
echo '		deny all;'>> /etc/nginx/conf.d/${FQDN}.conf
echo '	}'>> /etc/nginx/conf.d/${FQDN}.conf
echo '}'>> /etc/nginx/conf.d/${FQDN}.conf

#Save and close the file then verify the Nginx for any syntax error with the following command: 
nginx -t

#Step 11. Setup and Configure PhpMyAdmin
sudo apt update -y
sudo apt install phpmyadmin -y

#Step 12. gỡ bỏ apache:
sudo service apache2 stop
sudo apt-get purge apache2 apache2-utils apache2.2-bin apache2-common
sudo apt-get purge apache2 apache2-utils apache2-bin apache2.2-common

sudo apt-get autoremove
whereis apache2
apache2: /etc/apache2
sudo rm -rf /etc/apache2

sudo ln -s /usr/share/phpmyadmin /var/www/html/${FQDN}/${phpmyadmin}
sudo chown -R root:root /var/lib/phpmyadmin
sudo nginx -t

#Step 13. Nâng cấp PhpmyAdmin lên version 5.2.1:
sudo mv /usr/share/phpmyadmin/ /usr/share/phpmyadmin.bak
sudo mkdir /usr/share/phpmyadmin/
cd /usr/share/phpmyadmin/
sudo wget https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.tar.gz
sudo tar xzf phpMyAdmin-5.2.1-all-languages.tar.gz
#Once extracted, list folder.
ls
#You should see a new folder phpMyAdmin-5.2.1-all-languages
#We want to move the contents of this folder to /usr/share/phpmyadmin
sudo mv phpMyAdmin-5.2.1-all-languages/* /usr/share/phpmyadmin
ls /usr/share/phpmyadmin
mkdir /usr/share/phpMyAdmin/tmp   # tạo thư mục cache cho phpmyadmin

sudo systemctl restart nginx
systemctl restart php8.3-fpm.service

#Step 14. Install Certbot
sudo apt install certbot python3-certbot-nginx -y
#sudo certbot --nginx -n -d $FQDN --email $emailcertbot --agree-tos --redirect --hsts

# You should test your configuration at:
# https://www.ssllabs.com/ssltest/analyze.html?d=$FQDN
#/etc/letsencrypt/live/$FQDN/fullchain.pem
#   Your key file has been saved at:
#   /etc/letsencrypt/live/$FQDN/privkey.pem
#   Your cert will expire on yyyy-mm-dd. To obtain a new or tweaked
#   version of this certificate in the future, simply run certbot again
#   with the certonly option. To non-interactively renew *all* of
#   your certificates, run certbot renew

# Start Zabbix server and agent processes
# Start Zabbix server and agent processes and make it start at system boot.

systemctl restart zabbix-server zabbix-agent nginx php8.3-fpm
systemctl enable zabbix-server zabbix-agent nginx php8.3-fpm

#h. Open Zabbix UI web page
#The URL for Zabbix UI when using Nginx depends on the configuration changes you should have made.

fi