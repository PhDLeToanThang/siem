#!/bin/bash -e
###############################
# 
#
#

# ref: https://thangletoan.wordpress.com/2023/06/16/lab-11-cau-hinh-serverlog-tu-elasticsearch-kibana-suricata-filebeat-logstash-tren-ubuntu-22-04-server/
# Install Elasticsearch, Logstash, Kibana and Filebeat
sudo apt install nano -y
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg –dearmor -o /usr/share/keyrings/elastic.gpg
echo “deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/7.x/apt stable main” | sudo tee -a /etc/apt/sources.list.d/elastic-7.x.list
 sudo apt update -y
sudo apt install elasticsearch -y
#ip address show command:
ip -brief address show
nano /etc/elasticsearch/elasticsearch.yml
# Set the bind address to a specific IP (IPv4 or IPv6):
network.host: your_private_ip
sudo systemctl start elasticsearch
sudo systemctl enable elasticsearch
curl -X GET “your_private_ip:9200”
sudo apt install kibana
sudo systemctl enable kibana
systemctl start kibana
systemctl status kibana
echo “kibanaadmin:’openssl passwd -apr1′” | sudo tee -a /etc/nginx/htpasswd.users

sudo apt install logstash -y
sudo nano /etc/logstash/conf.d/02-beats-input.conf
input {
beats {
port = 5044
}
}
sudo nano /etc/logstash/conf.d/30-elasticsearch-output.conf
output {
if [@metadata][pipeline] {
elasticsearch {
hosts = [“your_private_ip:9200”]
manage_template = false
index = “%{[@metadata][beat]}-%{[@metadata][version]}-%{+YYYY.MM.dd}”
pipeline = “%{[@metadata][pipeline]}”
}
} else {
elasticsearch {
hosts = [“your_private_ip:9200”]
manage_template = false
index = “%{[@metadata][beat]}-%{[@metadata][version]}-%{+YYYY.MM.dd}”
}
}
}
sudo -u logstash /usr/share/logstash/bin/logstash –path.settings /etc/logstash -t
sudo systemctl start logstash
sudo systemctl enable logstash

#Cài đặt Filebeat bằng apt:
sudo apt install filebeat -y
sudo nano /etc/filebeat/filebeat.yml
# tìm tới đoạn
#output.elasticsearch:
# Array of hosts to connect to.
#hosts: [“your_private_ip:9200”]
# The Logstash hosts
# hosts: [“your_private_ip:5044”]
sudo filebeat modules enable system
nano /etc/filebeat/filebeat.yml
sudo filebeat modules list
#Output
#Enabled:
# system
#Disabled:
#apache2
#auditd
#elasticsearch
#icinga
#iis
#kafka
#kibana
#logstash
#mongodb
#mysql
#nginx
#osquery
#postgresql
#redis
#traefik
sudo nano /etc/filebeat/modules.d/system.yml
sudo filebeat setup –pipelines –modules system
sudo filebeat setup –index-management -E output.logstash.enabled=false -E ‘output.elasticsearch.hosts=[“your_private_ip:9200”]’
sudo filebeat setup -E output.logstash.enabled=false -E output.elasticsearch.hosts=[‘your_private_ip:9200’] -E setup.kibana.host=your_private_ip:5601

#Bây giờ bạn có thể bắt đầu và kích hoạt Filebeat:
sudo systemctl start filebeat
sudo systemctl enable filebeat

curl -XGET ‘http://your_private_ip:9200/filebeat-*/_search?pretty&#8217;
