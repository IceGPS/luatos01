PROJECT = 'test'
VERSION = '2.0.0'
require 'log'
LOG_LEVEL = log.LOGLEVEL_TRACE
require "sys"
require "pins"
require "powerKey"
require "audio"
require "utils"
require "misc"
require "nvm"
require "sim"
require "console"
require "errDump"
require "net"
require "led"
require "netLed"
require "link"
require "wifiRil"
require "socket"
require "socket4G"
require "socketESP8266"
require "mqtt"


--======================= 全局常量和管脚定义 =======================
DEBUGMODE = true
--电源键长按时间，单位毫秒
PWRKEY_LONGTIME = 2000
--电源键短按时间，单位毫秒
PWRKEY_SHORTTIME = 50

--UART总共有4个，除了USB串口是固定的之外，其余三个都需要根据产品的实际情况做修改。
UART_BT = 3
UART_WIFI = 1
UART_GPS = 2
UART_USB = uart.USB

--各个功能模块的控制和状态管脚
--蓝牙连接状态管脚
PIN_BT_CONNECT = pio.P0_22
--蓝牙复位管脚
PIN_BT_RESET = pio.P0_10
--WIFI连接状态管脚
PIN_WIFI_RESET = pio.P0_12
--GPS复位管脚
PIN_GPS_RESET = pio.P0_11

--按键管脚定义
--电源键管脚
PIN_PWRKEY = pio.P0_28
--PTT/SOS管脚
PIN_PTTKEY = pio.P0_0
PIN_VOLUMEUP = pio.P0_1
PIN_VOLUMEDOWN = pio.P0_14

--音频功放管脚，9
PIN_AMP = pio.P0_9
--3.3V电源管脚，8
PIN_3V3 = pio.P0_8
--气压计片选管脚，23, SPI2CS
PIN_BAROMETER = pio.P0_23

--电池电压ADC，实际电压是AD值的2倍（毫伏）
ADC_VBAT = 1
--电源电压ADC，
ADC_PWR = 2

--4个双色指示灯的管脚定义
local leds = {
	gps = {G = pio.P0_2, R = pio.P0_3},
	pwr = {G = pio.P0_5, R = pio.P0_4},
	net = {G = pio.P0_15,R = pio.P0_19},
	bt  = {G = pio.P0_18, R = pio.P0_13}
}

-- 指示灯4种颜色的定义
local color = {
	black = 'BLACK',
	green = 'GREEN',
	red = 'RED',
	yellow = 'YELLOW'
}

--ledname: 'pwr' 'gps' 'net' 'bt'
--ledcolor: 'BLACK' 'RED' 'YELLOW' 'GREEN'  
function led(ledname,ledcolor)
	green, red = 0,0
	if ledcolor == color.green then green = 1
	elseif ledcolor == color.red then red = 1
	elseif ledcolor == color.yellow then green,red = 1,1 
	end
	pins.setup(leds[ledname].G,green)
	pins.setup(leds[ledname].R,red)
end

--由于内部有调用sys.wait做延时，本函数只能在Task内被调用
local function leds_marquee()
	--全红
	led('pwr','RED')
	led('gps','RED')
	led('net','RED')
	led('bt','RED')
	sys.wait(1000)
	--全黄
	led('pwr','YELLOW')
	led('gps','YELLOW')
	led('net','YELLOW')
	led('bt','YELLOW')
	sys.wait(1000)
	--全绿
	led('pwr','GREEN')
	led('gps','GREEN')
	led('net','GREEN')
	led('bt','GREEN')
	sys.wait(1000)
	--只保留电源灯绿
	led('gps','BLACK')
	led('net','BLACK')
	led('bt','BLACK')
end


--======================= 全局变量，用于在不同模块之间共享数据 =======================
audioVolume = 1
batteryPercent = 0
batteryVoltage = 0


--======================= 长按关机函数 ====================
--[[
下面的两个函数实现的是在松开长按的电源键之前先熄灯，通过注册按键消息回调函数实现。
需要在Init初始化函数中进行注册
        rtos.on(rtos.MSG_KEYPAD,keyMsg)
        rtos.init_module(rtos.MOD_KEYPAD,0,0,0)
sta：按键状态，IDLE表示空闲状态，PRESSED表示已按下状态，LONGPRESSED表示已经长按下状态
longprd：长按键判断时长，默认3秒；按下大于等于3秒再弹起判定为长按键；按下后，在3秒内弹起，判定为短按键
longcb：长按键处理函数
shortcb：短按键处理函数
]]

local sta,longprd,longcb,shortcb = "IDLE",2000

local function longtimercb()
    sta = "LONGPRESSED"        
    --遇到长按电源键就先熄灯
	led('gps','BLACK')
	led('net','BLACK')
	led('bt','BLACK')
	led('pwr','BLACK')
end

local function keyMsg(msg)
    log.info("keyMsg",msg.key_matrix_row,msg.key_matrix_col,msg.pressed)
    if msg.pressed then
        sta = "PRESSED"
        sys.timerStart(longtimercb,longprd)
    else
        sys.timerStop(longtimercb)
        if sta=="PRESSED" then
            if shortcb then shortcb() end
        elseif sta=="LONGPRESSED" then
            log.info("PowerOff",sta);
            (longcb or rtos.poweroff)()
        end
        sta = "IDLE"
    end
end

--电源键长按
local function PwrKeyLongTimeCallBack()
    audio.play(1, "TTS", "关机", audiovolume)  --但是好像没有声音，不知道是不是需要增加延时。这里不是Task，sys.wait函数不能使用
    rtos.poweroff()
end

--电源键短按
local function PwrKeyShortTimeCallBack()
end

--======================= 定位数据处理函数 =======================
--定位数据接收完整性处理
--根据定时器判断GPS数据接收完整之后，就做两件事，
--1）、从中提取GGA消息，然后解析GGA消息
--2）、将RTCM数据发送到云端的MQTT服务器或者NTRIP服务器


--NMEA0183校验和检查
local function checkSum(str)
	local sum = 0
	for i = 2, #str do
		sum = bit.bxor(sum, string.byte(str, i))
	end
	return sum
end

--从NMEA0183 GGA消息中提取所有数据
local function getGGAData(str)
	local data = {}
	local i = 1
	for v in string.gmatch(str, "[^,]+") do
		data[i] = v
		i = i + 1
	end
	return data
end


--======================= NVM初始化 =======================
--NVM读写的参数需要放到config.lua文件中，这里只是读写config.lua文件中的参数



--======================= AT指令分析处理函数 =======================
--AT指令有三个来源，USB串口，蓝牙SPP，蓝牙BLE


--======================= UART初始化和数据接收函数 =======================
    --wifi模组使用UART1，但是由于ESP8266通信库中已经打开了UART1，所以这里不能再打开UART1
local function initUART()
    --打开USB虚拟串口，由于是虚拟串口，因此速率不起作用
    uart.setup(uart.USB, 0, 8, uart.PAR_NONE, uart.STOP_1)
    uart.on(uart.USB, "receive", USBreader)

	--RTK模组的通信速率可以提高到921600
    uart.setup(RTKUART, 115200, 8, uart.PAR_NONE, uart.STOP_1)
    uart.on(RTKUART, "receive", RTKreader)

	--蓝牙模组的通信速率可以提高到921600，TI这个模组SPP模式下实测可以超过50KB/s
    uart.setup(BTUART, 115200, 8, uart.PAR_NONE, uart.STOP_1)
    uart.on(BTUART, "receive", BTreader)

end

--======================= 蓝牙相关函数 =======================
    --判断蓝牙连接状态
    local getGpio22Input = pins.setup(pio.P0_22) 
    function GetBTConnection()
        return (getGpio22Input() == 1 and true or false)
    end
    
    --设置蓝牙设备名称，由于使用了sys.wait，所以必须在task中调用
    function SetBTName(BTname,BLEname)
        --如果是连接状态，就通过复位断开现有连接，因为只有在未连接状态发送AT指令才有效
        if GetBTConnection() then
            pins.setup(PIN_BT_RESET,0)
            sys.wait(50)
            pins.setup(PIN_BT_RESET,1)
            sys.wait(100)
        end        
        --如果是未连接状态，就可以发送AT指令设置蓝牙名称
        if not GetBTConnection() then
            uart.write(BTUART,'AT+NAME='..BTname..'\r\n') 
            sys.wait(50)
            uart.write(BTUART,'AT+LENAME='..BLEname..'\r\n') 
            sys.wait(50)
        end
    end
    


--======================= 网络初始化 =======================


--======================= 指示灯状态更新 =======================
--总共有4个指示灯，分别是电源指示灯、蓝牙指示灯、RTK指示灯、网络指示灯
--网络指示灯由LUATOS系统自动维护，其余三个指示灯的状态需要自己每秒检查更新
--电源指示灯需要读取电压值，电压值是通过ADC采集的，采集频率是1秒一次，为了消除电池波动的影响，采集10次，然后取平均值
--蓝牙指示灯直接根据蓝牙状态管脚的电平来判断蓝牙连接状态
--RTK指示灯根据GGA消息中的定位状态来判断，如果在有IMU的机型上，还需要判断IMU的校准状态
--电源指示灯的状态更新函数
local function DeviceLeds()

end

--======================= UART初始化函数 =======================


--======================= UART初始化函数 =======================


--======================= 设备初始化函数 =======================

function deviceInit()
	--1.01
	--判断开机原因，如果是充电开机，就关机进入充电状态。为了调试方便，在非正式版的时候最好注释掉这一行
    --在初始化部分放一个标志，DEBUGMODE=true就做这样的初始化，正式版的时候DEBUGMODE改为false即可
    if not DEBUGMODE then 
        if rtos.poweron_reason() == rtos.POWERON_CHARGER then rtos.poweroff(1) end
    end
    
	--1.02
    --前一个参数0是禁用RNDIS上网功能，后一个参数1是自动保存此配置
    ril.request("AT+RNDISCALL=0,1")
    
	--1.03
    --禁止进入低功耗状态，确保UART2和UART3工作正常。如果不这样设置，断开USB之后，只有UART1工作正常。
    pm.wake("ALWAYS_ON") 
    
	--1.04
    --管脚初始化，BW10，指示灯的初始化，避免指示灯处于随机状态

	--1.05
    --打开电压域,BW10
    pmd.ldoset(2, pmd.LDO_VLCD)  --没有这一行电源灯G不亮，定位灯RG都不亮
    pmd.ldoset(2,pmd.LDO_VSIM1) -- GPIO 29、30、31
    pmd.ldoset(2,pmd.LDO_VMMC) -- GPIO 24、25、26、27、28
        
	--1.06
    --打开电源,BW10
    pins.setup(PIN_3V3, 1) -- 3.3V供电打开 
    pins.setup(PIN_AMP, 1) -- 功放IC power on, 功放不打开就不会有声音 
    pins.setup(PIN_WIFI_RESET, 0) --保持拉低状态WIFI模组才能正常工作，这里拉低控制的是WIFI模组的GPIO15管脚

    leds_marquee()

	--1.07
	--每1分钟查询一次手机网信号强度和基站信息
	net.startQueryAll(60000, 60000)

	--1.08
	--加载网络指示灯和LTE指示灯功能模块
	netLed.setup(true,pio.P0_19,pio.P0_15)   --网络红灯19，网络绿灯15
	--网络指示灯功能模块中，默认配置了各种工作状态下指示灯的闪烁规律，参考netLed.lua中ledBlinkTime配置的默认值
	--如果默认值满足不了需求，调用netLed.updateBlinkTime去配置闪烁时长
	--LTE指示灯功能模块中，配置的是注册上4G网络灯就常亮，其余任何状态灯都会熄灭

	--1.09
	--加载控制台调试功能模块（此处代码配置的是uart2，波特率115200）
	--使用时注意：控制台使用的uart不要和其他功能使用的uart冲突
	--使用说明参考demo/console下的《console功能使用说明.docx》
	--console.setup(2, 115200)

	--1.10
	--加载错误日志管理功能模块【强烈建议打开此功能】
	--如下2行代码，只是简单的演示如何使用errDump功能，详情参考errDump的api
	--errDump.request("udp://dev_msg1.openluat.com:12425", nil, true)

	--1.11
	--OTA升级功能依赖于ProductKey，如果需要使用OTA升级功能，需要在此处配置ProductKey
	--PRODUCT_KEY = "v32xEAKsGTIEQxtqgwCldp5aPlcnPs3K"
	--update.request()

	--1.12
    --长按电源键关机
    rtos.on(rtos.MSG_KEYPAD,keyMsg)
    rtos.init_module(rtos.MOD_KEYPAD,0,0,0)
    powerKey.setup(PWRKEY_LONGTIME, PwrKeyLongTimeCallBack, PwrKeyShortTimeCallBack)
    
	--1.13
	--打开配置并打开UART接口


	--1.14
	--网络初始化及连接MQTT服务器

    --每5秒打印一下RAM和ROOM剩余空间
    sys.timerLoopStart(function()  log.info("RAM free size:", 1024 - math.floor(collectgarbage("count")), "KB")
        log.info("ROM free size:", rtos.get_fs_free_size(0,1), "KB") end, 5000)
	
end

function MainTask()
    deviceInit()
    
    while true do
        sys.wait(1000)
    end
end

sys.taskInit(MainTask)
--1表示充电开机的时候不启动GSM协议栈
sys.init(1, 0)
sys.run()
