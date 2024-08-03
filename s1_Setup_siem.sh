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

