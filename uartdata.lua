module(..., package.seeall)
require "log"
require "bit"
require "pins"
require "uart"

--require "nvmdata"

--UART定义
local UART1 = 1
local UART2 = 2
local UART3 = 3

WIFIUART = UART1
RTKUART = UART2
BTUART = UART3
USBUART = uart.USB

--UART之间是否转发数据的标记
USBRTK = 1
USBBT = 0
RTKBT = 0

--data log部分的全局变量
GPSFIXED = false
logfile = nil
logfilename = ''


--NMEA0183格式的定位消息
gnggastrstr = ''
gnrmcstr = ''
gngststr = ''

--解析之后的定位数据
--[[
    根据逗号解析之后的GGA数据，
    1GGA，2UTChhmmss.ss，3纬度，4NS，5经度，6EW，7定位状态，8卫星数，9HDOP，
    10海拔，11M，12椭球修正，13M，14差分龄期，15基站编号，16Checksum

    7定位状态的10种情况
    0，未定
    1，单点
    2，伪距差分
    3，3D定位
    4，RTK固定
    5，RTK浮动
    6，航位推算
    7，手工输入固定坐标
    8，模拟
    9，WAAS

    12椭球修正值的用法
    椭球修正值的意思是WGS84椭球的比当地的大地海拔高多少米，用10的WGS84海拔减去12椭球修正值，就得到正确的大地海拔。
]]
ggaarray = {}
rmcarray = {}
gstarray = {}
RTKFixQuality = 0
RTKElevation = 0

--从RTK模组接收到的每帧整包数据
RTCMRAWdata = ''
RTKdata = {}
TimeofGotRTKData = 0
local RTCMReadyFlag = false   --RTCM数据完整性标记
local RTCMUploadFlag = true   --RTCM数据是否已经上传到网络
local counter = 0
local usbstr = ''

--根据尾部校验和判断收到的NMEA83数据是否正确
local function checknmea0183(nmea0183msg)
    local s = ''
    if nmea0183msg ~= nil then
        --log.info('Check sum:'..nmea0183msg)
        local dollarsign = string.find(nmea0183msg,'$',1,true)   -- 最后的参数 true 用于禁止按正则表达式查找
        local starsign = string.find(nmea0183msg,'*',1,true)
        s = string.sub(nmea0183msg,dollarsign+1,starsign-1)  -- 去掉头尾不参与计算校验和的字符
        checksum = string.sub(nmea0183msg,starsign+1,starsign+2)
        local i = string.byte(s)
        for j = 2, string.len(s) do
            i = bit.bxor(i, string.byte(s,j))
        end
        return (i==tonumber(checksum,16))
    else
        return false
    end
end

-- RTK数据完整性检查回调函数，根据时间进行判断。在RTK串口回调函数每次被调用的时候都重新启动50ms定时器，等收到这个定时器消息的时候就认为数据接收完毕。
local function RTKdatatimer()   
    RTKdata['RTCM'] = RTCMRAWdata
    RTKdata['GGA'] = gnggastr
    if gnggastr == nil then 
        log.error('-------------------gnggastr is nil') 
    elseif string.len(gnggastr) < 30 then
        log.error('-------------------gnggastr is too short:',gnggastr) 
    elseif checknmea0183(gnggastr) then 
        ggaarray = string.split(gnggastr,',')
        RTKFixQuality = tonumber(ggaarray[7])
        RTKElevation = tonumber(ggaarray[10])    
        RTKdata['FIX'] = tonumber(ggaarray[7])
        RTKdata['ELEV'] = tonumber(ggaarray[10])    
        RTKdata['UTC'] = tonumber(ggaarray[2])    

        --增加data log功能，把GPS模组输出的定位数据保存到TF卡上
        if GPSFIXED then
            if io.writeFile(logfilename,RTCMRAWdata,"a+b") then
                log.error("NMEA0183 log file write failed") 
            end
        else
            if RTKFixQuality > 0 then
                GPSFIXED = true    
                if logfile == nil then
                    local t = os.date("*t")
                    if t.year <2023 then
                        --最后三位是毫秒，尽可能避免文件名冲突
                        logfilename = "/sdcard0/nmea/"..string.format("%09d",tonumber(ggaarray[2])*1000)..".nmea"
                    else
                        logfilename = string.format("/sdcard0/nmea/%04d%02d%02d-%02d%02d%02d.nmea", t.year,t.month,t.day,t.hour,t.min,t.sec)
                    end
                end
            end
        end
    else
        log.error("GGA checksum ERROR:"..gnggastr) 
    end
    RTCMRAWdata = ''
    gnggastr = ''    
end

--[[
    三种类型的自定义AT指令，开头的三个字母分别是：
    1、ICE，直接控制串口转发的指令，立即生效
    2、NVM，保存到NVM的产品配置参数，下次开机生效
    3、RTK，直接发送给RTK模块的配置命令，立即生效
    自定义AT指令来自于USB串口或者蓝牙SPP串口，是否支持BLE待定
]]
local function PrivateATCheck(s)
    if string.len(s) > 10 then
        local atprefix = string.sub(s,1,4)
        local a = string.find(s,'=',5,1)
        local atcommand = string.sub(s,5, a-1)   -- 1表示简单查找，不用正则表达式
        local atparameters = string.sub(s,a+1 ) 
        if atprefix == 'ICE+' then  -- 判断收到的数据是不是以“ICE+”三个字母开始的
            if string.find(atcommand,'USBRTK',1) == 1 then -- 以简单查找方式确认是否找到相应AT指令
                USBRTK = tonumber(atparameters)
            elseif string.find(atcommand,'USBBT',1)  == 1 then
                USBBT = tonumber(atparameters)
            elseif string.find(atcommand,'RTKBT',1)  == 1 then
                RTKBT = tonumber(atparameters)
            end
            return true
        elseif atprefix == 'NVM+' then      --NVM开头的指令都保存到NVM中，不做缓冲，立即生效
            nvm.set(atcommand,atparameters)
            nvm.flush()
            return true
        elseif atprefix == 'RTK+' then      --RTK开头的指令都直接发送给RTK模块
            rtkwrite(atparameters.."\r\n")
            return true
        else    
            return flase
        end
    else
        --log.info("======================AT command too short====================")
        --log.info("AT command:",s)
        return false
    end
end



-- BT连接状态
local getGpio22Input = pins.setup(pio.P0_22) 
function GetBTConnection()
    return (getGpio22Input() == 1 and true or false)
end

function usbwrite(s)
    uart.write(USBUART, s) 
end

function btwrite(s)
    uart.write(BTUART, s) 
end

function rtkwrite(s)
    uart.write(RTKUART, s) 
end

local function usbreader()
    local s
    while true do
        s = uart.read(uart.USB, "*l", 0)
        if string.len(s) ~= 0 then
            if PrivateATCheck(s) then
               usbwrite("OK\r\n")
            else 
                if USBRTK>0 then rtkwrite(s) end
                if USBBT>0 then btwrite(s) end
            end
        else
            break
        end
    end
end

-- 每次被调用的时候都重新启动50ms定时器，当定时器执行的时候就知道接收到数据已经过去了50ms，就可以认为本次定位数据接收完毕
local function rtkreader()
    local tempstr , fullstr = '',''
    --重新设置50ms定时器
    sys.timerStart(RTKdatatimer,100) 

    while true do
        tempstr = uart.read(RTKUART, "*l", 0)
        if string.len(tempstr) ~= 0 then
            fullstr = fullstr..tempstr
            if string.find(tempstr,'$G%aGGA')  then
                gnggastr = tempstr
            end
        else
            if USBRTK>0 then usbwrite(fullstr) end
            if GetBTConnection() and RTKBT then
                btwrite(fullstr)
            end
            RTCMRAWdata = RTCMRAWdata..fullstr   
            break
        end
    end
end

local function btreader()
    local s    
    while true do
        s = uart.read(BTUART, "*l", 0)
        if string.len(s) ~= 0 then
            if PrivateATCheck(s) then
                uart.write(BTUART,"OK\r\n")
            else  
                if USBBT>0 then usbwrite(s) end
                if RTKBT>0 then rtkwrite(s) end
            end
        else
            break
        end
    end
end

function Init()
    uart.setup(USBUART,921600, 8, uart.PAR_NONE, uart.STOP_1)
    uart.on(USBUART, "receive", usbreader)

    uart.setup(RTKUART, 115200, 8, uart.PAR_NONE, uart.STOP_1)
    uart.on(RTKUART, "receive", rtkreader)

    uart.setup(BTUART, 115200, 8, uart.PAR_NONE, uart.STOP_1)
    uart.on(BTUART, "receive", btreader)
end

function Task()    
    while true do
        sys.wait(1000)
    end
end
