# Zabbix 6 / 7x


Cách 1. Cài bằng cách download bản VM Appliance cho VMware .vmx

![image](https://github.com/user-attachments/assets/7653c841-6264-49eb-ae0f-7861cbcacffd)


https://www.zabbix.com/documentation/6.4/en/manual/appliance

	- phai dung ssh ket noi ESXi, dung lenh: 
 vmkfstools -i /vmfs/volumes/84-5a7526ef-88e-acb1/zabbix.privatecloud/zabbix_appliance-6.4.18-disk1.vmdk /vmfs/volumes/84-5a7526ef-88e-acb1/zabbix.privatecloud/zabbix_app_6418_d1.vmdk
 
Destination disk format: VMFS zeroedthick
Cloning disk '/vmfs/volumes/84-5a7526ef-88e-acb1/zabbix.privatecloud/zabbix_app_6418_d1.vmdk'...
Clone: 100% done.
	-	edit settings VM: Add exist HDD NVME controller , VMware Paravirtual. 

System:

root:zabbix
Zabbix frontend:

Admin:zabbix
Database:

root:<random>
zabbix:<random>
