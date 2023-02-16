module(..., package.seeall)

-- 这里保存可配置参数，存储在NVM存储器中，用户可以通过串口助手、APP、小程序发出相应的AT指令进行修改
--0-7
audiovolume = 1    

--ROVER, BASE, MOBILE
rtkmode  = 0  

--4G, WIFI, ETHERNET
network = 0      

--0:MQTT, 1:NTRIP
protocol = 0    

--0:BT, 1:LORA, 2:CORS
rtcmsource = 0    

--0:Disable, 1:Enable
rtk2usb = 1      
rtk2btspp = 1      --0:Disable, 1:Enable
rtk2ble = 0        --0:Disable, 1:Enable
rtk2tfcard = 0     --0:Disable, 1:Enable
imu2usb = 1        --0:Disable, 1:Enable   
imu2btspp = 1      --0:Disable, 1:Enable
imu2ble = 0        --0:Disable, 1:Enable
imu2tfcard = 0     --0:Disable, 1:Enable
gnssbaudrate = "115200"  
btbaudrate = "115200"
imubaudurate = "115200"
wifibaudurate = "115200"

--SSID,Password
wifiap = "" 

--Channel,NetID
lorainfo = ""        

--Host,Port,Username,Password,QoS
mqttaccount = ""     

--Host,Port,Username,Password,MountPoint,Auto
ntripaccount = ""   

--Host,Port,Username,Password
jtt808account = ""   

-- t is table
tlorainfo = {
    channel = "0",    -- 取值范围
    netid = "0"       -- 取值范围
}

twifiap = {    -- WIFI AP信息应该没有存储的必要，因为在配置WIFI的时候，WIFI模块已经自动保存了AP信息，下次上电会自动重连
    ssid = "",
    password = ""
}

tmqttaccount = {
    host = "mqtt.icegps.com",
    port = "1883",
    username = "",
    password = "",
    qos = 0
}

tntripaccount = {
    auto = false,
    host = "sdk.pnt.10086.cn",
    port = "8002",
    mountpoint = "RTCM33_GRCEJ",
    username = "",
    password = ""
}

tjtt808account = {
    host = "",
    port = "7018",
    username = "",
    password = ""
}
