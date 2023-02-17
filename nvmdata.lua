module(..., package.seeall)
require "log"
require "nvm"

require "config"

settings = {
    audiovolume = "1",    --0-7
    rtkmode  = "ROVER",   --ROVER, BASE, MOBILE
    rtkmodule = "P20M",    --P20M,UM960,UM980...
    network = "4G",       --4G, WIFI, ETHERNET
    protocol = "0",       --0:MQTT, 1:NTRIP
    rtcmsource = "0",     --0:BT, 1:LORA, 2:CORS
    rtk2usb = "1",        --0:Disable, 1:Enable
    rtk2btspp = "1",      --0:Disable, 1:Enable
    rtk2ble = "0",        --0:Disable, 1:Enable
    rtk2tfcard = "0",     --0:Disable, 1:Enable
    imu2usb = "1",        --0:Disable, 1:Enable   
    imu2btspp = "1",      --0:Disable, 1:Enable
    imu2ble = "0",        --0:Disable, 1:Enable
    imu2tfcard = "0",     --0:Disable, 1:Enable
    gnssbaudrate = "115200",  
    btbaudrate = "115200",
    imubaudurate = "115200",
    wifibaudurate = "115200",
    wifiap = "",          --SSID,Password
    lorainfo = "",        --Channel,NetID
    mqttaccount = "",     --Host,Port,Username,Password,QoS
    ntripaccount = "",    --Host,Port,Username,Password,MountPoint
    jtt808account = ""    --Host,Port,Username,Password
}

function init()
    nvm.init("config.lua")
    for k, v in pairs(settings) do
        if nvm.get(k) == nil then
            settings[k] = v
            log.info("nvmdata.init", k, v)
        end
    end
end

function SetPara(paraName,paraValue)
    nvm.set(paraName,paraValue)
end

function GetPara(paraName)
    return nvm.get(paraName)
end

--[[
    对AT指令的优化
    1、BH开头的AT指令
    2、ICENVM开头的AT指令，这个指令里边的内容是之间写入到NVM中的。要不要区分两种类型的参数，数字型和Table型？
    还是统一按String写入NVM，然后在使用的时候再进行进一步处理？逗号分隔的String用CSV方式转换成table很简单，但是键值如何处理？
    3、ICEGPS开头的AT指令，直接发给GNSS模组，对GNSS模组进行配置
    4、ICEBT开头的指令，直接发给蓝牙模组，对蓝牙模组进行配置
    
You can convert the given string into a Lua table by following these steps:

local str = "a=1,b=2,c=3,d=4"
local result = {}

for pair in str:gmatch("([^,]+)") do
  local key, value = pair:match("([^=]+)=(.+)")
  result[key] = tonumber(value)
end

-- now the table 'result' contains the following key-value pairs:
-- result["a"] = 1
-- result["b"] = 2
-- result["c"] = 3
-- result["d"] = 4

Create an empty table result.
Split the input string using string.gmatch() function into key-value pairs.
For each key-value pair, split it into two separate strings using the string.match() function.
Add the key-value pair to the result table using the key as the table index and the value as the table value.

]]

init()
