module(..., package.seeall)
require "log"
require "bit"
require "pins"
require "uart"

--UART定义
local UART1 = 1
local UART2 = 2
local UART3 = 3

WIFIUART = UART1
RTKUART = UART2
BTUART = UART3
USBUART = uart.USB

--[[
    数据传输方向和作用
    1、定位数据的传输
        RTK -> BT           定位数据通过蓝牙发送给手簿等设备，这是第一重要的数据发送功能
        RTK -> USB          定位数据通过USB虚拟串口发送给电脑，便于使用电脑上的数据处理功能进行采集和分析，这个功能第二重要

    2、差分数据的传输
        BT -> RTK           通过蓝牙接收手簿发来的RTCM数据实现差分，这是RTK设备的最基础功能
        LORA -> RTK         通过LORA接收便携基站发送的RTCM数据实现差分，这个功能对国外客户非常关键
        RS232 -> RTK        把RS232串口上外挂的数传电台接受到的RTCM数据发送给RTK实现差分，这是现在国外非常需要的RTK功能
        WIFI+MQTT -> RTK    通过WIFI连接MQTT服务器上传或者接收RTCM差分数据   
        WIFI+NTRIP -> RTK   通过WIFI连接NTRIP服务器上传或者接收RTCM差分数据
        4G+MQTT -> RTK      通过4G连接MQTT服务器上传或者接收RTCM差分数据   
        4G+NTRIP -> RTK     通过4G连接NTRIP服务器上传或者接收RTCM差分数据

    3、配置指令的传输，配置指令有USB和BT两个来源，按指令作用可以分为两种，对终端设备进行配置的指令，对RTK模组进行配置的指令
        USB -> 终端+RTK 
        BT -> 终端+RTK

    4、定位数据的完整性处理
        LUAT模组从RTK模组读取数据的时候不能保证报文的完整性，但是某些传输途径要求数据完整，这就需要在接收时候进行判断处理。

        需要发送完整数据的是4G、WIFI网络通信场景，一来数据完整才能确保实现差分，二来串口WIFI模块的通信能力有限，每秒不能发送太多的消息。
        1）、MQTT上传RTCM差分数据
        2）、NTRIP上传RTCM差分数据
        3）、MQTT接收RTCM差分数据
        4）、NTRIP接收RTCM差分数据

        为了保证接收到的定位数据是完整的，有两种实现思路
        1）、标准做法，根据NMEA0183和RTCM3.3的定义把收到的数据包拼接然后拆分成独立的消息。彻底解决问题，但是难度最大，并且产品不需要做RTCM数据的解码。
        2）、简易做法，根据时间延迟判断数据传输是否完成。每次收到数据的时候都启动一个100ms的单次定时器并更新时间标记，在定时器激活的时候检查当前时间和标记时间相差是否达到100ms，如果达到就认为数据接收完成，就启动发送。
            这个做法的弱点是验证依赖空闲时间，只适合网络基站的1HZ低频定位场景。

        先计算一下每次从RTK模组接收数据使用的时间，用loginfo打印出来看看，每次收到的字节数和距离上次接收数据的时间ms

]]

--UART之间是否转发数据的标记
USBRTK = 1
USBBT = 0
RTKBT = 1

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
    --log.info('-------------------RTK data timer')
    if gnggastr == nil then 
        log.error('-------------------gnggastr is nil') 
    elseif string.len(gnggastr) < 30 then
        log.error('-------------------gnggastr is to short:',gnggastr) 
    elseif checknmea0183(gnggastr) then 
        ggaarray = string.split(gnggastr,',')
        RTKFixQuality = tonumber(ggaarray[7])
        RTKElevation = tonumber(ggaarray[10])    
        RTKdata['FIX'] = tonumber(ggaarray[7])
        RTKdata['ELEV'] = tonumber(ggaarray[10])    
        RTKdata['UTC'] = tonumber(ggaarray[2])    
    else
        log.error("GGA checksum ERROR:"..gnggastr) 
    end
    RTCMRAWdata = ''
    gnggastr = ''    
end

local function PrivateATCheck(s)
    local atprefix = string.sub(s,1,3)
    if atprefix == 'BH+' then  -- 判断收到的数据是不是以“BH+”三个字母开始的，如果想用AT开始，就需要写AT指令的处理函数
        local a = string.find(s,'=',4,1)
        local atcommand = string.sub(s,4, a-1)   -- 1表示简单查找，不用正则表达式
        local atparameters = string.sub(s,a+1 ) 
        log.info("AT:"..s)
        log.info("AT command:"..atcommand)
        log.info("AT Parameters:"..atparameters)
        if string.find(atcommand,'USBRTK',1) == 1 then -- 以简单查找方式确认是否找到相应AT指令
            USBRTK = tonumber(atparameters)
        elseif string.find(atcommand,'USBBT',1)  == 1 then
            USBBT = tonumber(atparameters)
        elseif string.find(atcommand,'RTKBT',1)  == 1 then
            RTKBT = tonumber(atparameters)
        end
        return true
    else
        return flase
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
	log.info("RTK Fix status: ",RTKFixQuality)
	log.info("Elevation: ",RTKElevation)
        sys.wait(1000)
    end
end
