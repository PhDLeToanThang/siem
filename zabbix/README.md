# Zabbix 6 / 7x


## Cách 1. Cài bằng cách download bản VM Appliance cho VMware .vmx

![image](https://github.com/user-attachments/assets/7653c841-6264-49eb-ae0f-7861cbcacffd)

Bước 1. Download bản VM Appliance, mình chọn bản cho VMware .vmx:
https://www.zabbix.com/documentation/6.4/en/manual/appliance

Bước 2.	Dùng Winscp và PuTTy kết nối tới ESXi và dùng lệnh: 
```ssh
 vmkfstools -i /vmfs/volumes/84-5a7526ef-88e-acb1/zabbix.privatecloud/zabbix_appliance-6.4.18-disk1.vmdk /vmfs/volumes/84-5a7526ef-88e-acb1/zabbix.privatecloud/zabbix_app_6418_d1.vmdk
 
Destination disk format: VMFS zeroedthick
Cloning disk '/vmfs/volumes/84-5a7526ef-88e-acb1/zabbix.privatecloud/zabbix_app_6418_d1.vmdk'...
Clone: 100% done.
```

Bước 3. edit settings VM: Add exist HDD NVME controller , VMware Paravirtual và chọn ổ VD kiểu NVME Control 0:0

Bước 4. Bật VM power on và mở Console login

System Access:

root:zabbix
Zabbix frontend:

Admin:zabbix
Database:

root:<random>
zabbix:<random>
-------------
Bước 5. Truy cập website và chọn mục cấu hình mediatype để fix email gửi: 

![image](https://github.com/user-attachments/assets/9ec236b8-7015-4765-84b8-d4019f35d828)

Bước 6. Nếu bạn có hệ thống email Doanh nghiệp ( Gmail / MSO365 ):

**MSO365:**

![image](https://github.com/user-attachments/assets/31885d87-3eac-49ea-b393-7080d08b6035)

Sau khi cấu hình, chúng ta test:

![image](https://github.com/user-attachments/assets/e543485e-97d9-4cba-a690-1c496e18a458)


**Gmail:**
- Không thành công do ArchLinux 8.10 không cho cài ssmtp,
- Gmail phải bật chế độ Less Security trong khi Account email lại bật MFA/2FA là không khả thi.
  
