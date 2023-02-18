PROJECT = 'BW10'
VERSION = '0.0.2'
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

--App代码
require "uartdata"
require "nvmdata"

--======================= 全局常量和管脚定义 =======================
DEBUGMODE = true
--电源键长按时间，单位毫秒
PWRKEY_LONGTIME = 2000
--电源键短按时间，单位毫秒
PWRKEY_SHORTTIME = 50
IMEI = ''

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

--======================= 网络和MQTT部分 ====================
mqttc = nil
mqttclinetid = ''
mqtthost = ''
mqttport = '1883'
mqttuser = ''
mqttpassword = ''
mqttpubgga =''
mqttpubrtcm =''

--======================= 按键设置部分 ====================
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

function VoiceBatteryandSOC()
    local VBattStr = '电压'..string.format("%1.1f",batteryVoltage/1000)..'伏'..
        ',电量百分之'..string.format("%.0f",batteryPercent)
    if uartdata.RTKdata['FIX'] ~= nil then
        if uartdata.RTKdata['FIX'] > 0 then
            VBattStr = VBattStr..',海拔'..string.format('%d',uartdata.RTKdata['ELEV'])..'米'
        end
    end
    log.info(VBattStr)
    audio.play(0,"TTS",VBattStr,audioVolume)
end

--电源键长按
local function PwrKeyLongTimeCallBack()
    audio.play(0,"TTS","关机",audiocore.VOL1,function() sys.publish("AUDIO_PLAY_END") end)
    sys.waitUntil("AUDIO_PLAY_END")    
    rtos.poweroff()
end

--电源键短按
local function PwrKeyShortTimeCallBack()
    VoiceBatteryandSOC()
end

local function PTTIntCallback(msg)    -- PTT
    if msg == cpu.INT_GPIO_NEGEDGE then
	VoiceBatteryandSOC()
    end
end

local function VolumeUpIntCallback(msg)    -- VolumeUp，gpio1
    if msg == cpu.INT_GPIO_NEGEDGE then
        if audioVolume < 7 then
            audioVolume = audioVolume + 1
            audio.play(0,"TTS",string.format("音量%d级", audioVolume),audioVolume)
        else
            audio.play(0,"TTS","最大音量", audioVolume)
            audioVolume = 7
        end
        nvm.set("audioVolume",audioVolume)
    end
end

local function VolumeDownIntCallback(msg)   -- VolumeDown, gpio14
    if msg == cpu.INT_GPIO_NEGEDGE then
        if audioVolume > 1 then
            audioVolume = audioVolume -1
            audio.play(0,"TTS",string.format("音量%d级", audioVolume),audioVolume)
        else
            audio.play(0,"TTS","静音",audioVolume)
            audioVolume = 0
        end
        nvm.set("audioVolume",audioVolume)
    end
end

--======================= NVM初始化 =======================
--NVM读写的参数需要放到config.lua文件中，这里只是读写config.lua文件中的参数


--======================= 蓝牙相关函数 =======================
    
--设置蓝牙设备名称，由于使用了sys.wait，所以必须在task中调用
function SetBTName(BTname,BLEname)
    --如果是连接状态，就通过复位断开现有连接，因为只有在未连接状态发送AT指令才有效
    if uartdata.GetBTConnection() then
        pins.setup(PIN_BT_RESET,0)
        sys.wait(50)
        pins.setup(PIN_BT_RESET,1)
        sys.wait(1000)
    end        
    --如果是未连接状态，就可以发送AT指令设置蓝牙名称
    if not uartdata.GetBTConnection() then
        uartdata.btwrite('AT\r\n') 
        sys.wait(50)
        uartdata.btwrite('AT+NAME='..BTname..'\r\n') 
        sys.wait(50)
        uartdata.btwrite('AT+LENAME='..BLEname..'\r\n') 
        sys.wait(50)
    end
end


--======================= 网络初始化 =======================
--网络和MQTT初始化
local function wifipower(enable)
    --[[
    if enable then
        pmd.ldoset(15, pmd.LDO_VMMC)
    else
        pmd.ldoset(0, pmd.LDO_VMMC)
    end
    ]]
end

local para = {
    powerFunc = wifipower
}

function wifiinit()
    -- 切换到WIFI网络需要做的工作
    -- 1、确保wifiRil.lua文件开头的UART_ID，确保和实际产品中WIFI模块所在的端口一致
    -- 2、调用函数，设置WIFI热点
    --      socketESP8266.setApPara(ssid,password)
    -- 3、复位一下WIFI模块，先拉高再拉低即可，拉高时间不小于50ms
    -- 4、调用函数，打开WIFI网络
    --      link.setNetwork(link.ESP8266, para)   
    --复位一下WIFI模块
    pins.setup(pio.P0_12, 1)
    sys.wait(100)
    pins.setup(pio.P0_12, 0)    --保持拉低状态WIFI模组才能正常工作
    sys.wait(1000)
    --断开两次AP，确保断开
    sys.wait(100)
    wifiRil.request("AT+CWQAP\r\n")
    sys.wait(100)
    wifiRil.request("AT+CWQAP\r\n")
    sys.wait(100)
    --关闭自动连接
    wifiRil.request("AT+CWAUTOCONN=0\r\n")
    sys.wait(100)
    --开始连接WIFI
    socketESP8266.setApPara('myap','1234567890')
    link.openNetwork(link.ESP8266, para)   
    if not socket.isReady() then
        -- 等待网络环境准备就绪，超时时间是1分钟
        sys.waitUntil("IP_READY_IND", 60000)
    end    
end

function mqttinit()
    while not socket.isReady() do
        sys.wait(1000)
    end
    mqttc = mqtt.client(mqttclientid,60,mqttuser,mqttpassword)
    mqttc:connect(mqtthost,mqttport)
end

-- MQTT订阅数据处理
-- @param mqttClient，MQTT客户端对象
-- @return 处理成功返回true，处理出错返回false
function mqttproc()
    local result,data
    while true do
        if mqttc ~= nil then
            result,data = mqttc:receive(60000,"APP_SOCKET_SEND_DATA")
        end
        --接收到数据
        if result then
            log.info("mqtt received:",data.topic,string.len(data.payload))
            uartdata.rtkwrite(data.payload)
        end
    end
	
    return result or data=="timeout" or data=="APP_SOCKET_SEND_DATA"
end

function mqtttask()
    mqttinit()

    while true do
        if socket.isReady() then
            if nvmdata.settings['rtkmode'] == "ROVER" then
                mqttproc()
            else
                log.info("=============Publish GGA and RTCM33 data============")
                if string.len(uartdata.gnggastr) > 0 then
                    mqttc:publish(mqttpubgga, uartdata.mqttgga)
                end
                if string.len(uartdata.RTCMRAWdata) > 0 then
                    mqttc:publish(mqttpubrtcm, uartdata.mqttrtcm)
                end
            end
        else
            --[[
            mqttc:disconnect()
            --进入飞行模式，20秒之后，退出飞行模式
            net.switchFly(true)
            sys.wait(20000)
            net.switchFly(false)
            ]]            
        end
        sys.wait(1000)
    end
end

--======================= 指示灯状态更新 =======================
--总共有4个指示灯，分别是电源指示灯、蓝牙指示灯、RTK指示灯、网络指示灯
--网络指示灯由LUATOS系统自动维护，其余三个指示灯的状态需要自己每秒检查更新
--电源指示灯需要读取电压值，电压值是通过ADC采集的，采集频率是1秒一次，为了消除电池波动的影响，采集10次，然后取平均值
--蓝牙指示灯直接根据蓝牙状态管脚的电平来判断蓝牙连接状态
--RTK指示灯根据GGA消息中的定位状态来判断，如果在有IMU的机型上，还需要判断IMU的校准状态
--电源指示灯的状态更新函数
local function ledsUpdateTask()
    while true do
	    --RTK LED
        if uartdata.RTKFixQuality <1  then 
            led('gps','BLACK') -- 未定位，不亮
        else
            if uartdata.RTKFixQuality <4 then 
                led('gps','RED') -- 单点定位，红灯
            else
                if uartdata.RTKFixQuality == 4 then 
                    led('gps','GREEN') -- RTK固定，绿灯
                else
                    if uartdata.RTKFixQuality == 5 then 
                        led('gps','YELLOW') -- RTK浮动，黄灯
                    else  
                        led('gps','RED') -- -- 大于5的情况，视为单点定位
                    end
                end
            end
        end

        --BT  LED 
        if uartdata.GetBTConnection() then
            led("bt","GREEN")
        else
            led("bt","BLACK")
        end
        
        --PWR LED 
        adcvol, batteryVoltage = adc.read(ADC_VBAT)
        adcvol, powerVoltage = adc.read(ADC_PWR)
        batteryVoltage = batteryVoltage *2
        powerVoltage = powerVoltage *2
        batteryPercent = math.floor((batteryVoltage-3400)/(42-34))
        if batteryPercent > 100 then batteryPercent = 100 end

        if batteryPercent > 67 then
            led('pwr','GREEN')
        elseif batteryPercent > 33 then
            led('pwr','YELLOW')
        else
            led('pwr','RED')
        end
        sys.wait(1000)
    end
end

--======================= 获取设备状态=======================
local function deviceStatus()
    log.info("RAM free size:", 1024 - math.floor(collectgarbage("count")), "KB")
    log.info("ROM free size:", rtos.get_fs_free_size(0,1), "KB")
    log.info("hardware: ",rtos.get_hardware())
    log.info("firmware version: ",rtos.get_version())
    log.info("task messgae queue : ",rtos.get_env_usage(),"%")
    log.info("tf card total space: ",rtos.get_fs_total_size(1,1),'KB')
    log.info("tf card free space: ",rtos.get_fs_free_size(1,1),'KB')
    log.info("===========================================")
end

local function sdCardTask()
    sys.wait(5000)
    --挂载SD卡,返回值0表示失败，1表示成功
    io.mount(io.SDCARD)
    
    --第一个参数1表示sd卡
    --第二个参数1表示返回的总空间单位为KB
    local sdCardTotalSize = rtos.get_fs_total_size(1,1)
    log.info("sd card total size "..sdCardTotalSize.." KB")
    
    --第一个参数1表示sd卡
    --第二个参数1表示返回的总空间单位为KB
    local sdCardFreeSize = rtos.get_fs_free_size(1,1)
    log.info("sd card free size "..sdCardFreeSize.." KB")
    
    --遍历读取sd卡根目录下的最多10个文件或者文件夹
    if io.opendir("/sdcard0") then
        for i=1,10 do
            local fType,fName,fSize = io.readdir()
            if fType==32 then
                log.info("sd card file",fName,fSize)               
            elseif fType == nil then
                break
            end
        end        
        io.closedir("/sdcard0")
    end
    
    --创建log目录，验证两种方法那种可以正常工作
    if not io.exists("/sdcard0/nmea") then
        rtos.make_dir("/sdcard0/nmea")
    end
    --[[这个创建目录的方法无效，因为io库里边没有mkdir函数
    if not io.exists("/sdcard0/log1io") then
        io.mkdir("/sdcard0/log1io")
    end
    ]]

    --向sd卡根目录下写入一个pwron.mp3
    if not io.exists("/sdcdar0/pwron.mp3") then
        io.writeFile("/sdcard0/pwron.mp3",io.readFile("/lua/pwron.mp3"))
    end
    --audio.play(0,"FILE","/lua/pwron.mp3",audiocore.VOL2,function() sys.publish("AUDIO_PLAY_END") end)
    audio.play(0,"FILE","/sdcard0/pwron.mp3",audiocore.VOL1,function() sys.publish("AUDIO_PLAY_END") end)
    sys.waitUntil("AUDIO_PLAY_END")
	
	--卸载SD卡，返回值0表示失败，1表示成功
	--io.unmount(io.SDCARD)
end


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
    pmd.ldoset(15,pmd.LDO_VMMC) -- GPIO 24、25、26、27、28, SD卡需要3.1V电压，所以这里用15
        
	--1.06
    --打开电源,打开ADC
    pins.setup(PIN_3V3, 1) -- 3.3V供电打开 
    pins.setup(PIN_AMP, 1) -- 功放IC power on, 功放不打开就不会有声音 
    pins.setup(PIN_WIFI_RESET, 0) --保持拉低状态WIFI模组才能正常工作，这里拉低控制的是WIFI模组的GPIO15管脚
    adc.open(ADC_PWR)
    adc.open(ADC_VBAT)
    --点亮一遍指示灯，仪式感和让用户开机的时候确认指示灯是否有损坏
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
	--按键设置
    --长按电源键关机
    rtos.on(rtos.MSG_KEYPAD,keyMsg)
    rtos.init_module(rtos.MOD_KEYPAD,0,0,0)
    powerKey.setup(PWRKEY_LONGTIME, PwrKeyLongTimeCallBack, PwrKeyShortTimeCallBack)
    pins.setup(PIN_PTTKEY, PTTIntCallback) -- PTT button
    pins.setup(PIN_VOLUMEUP, VolumeUpIntCallback) -- Volume up button
    pins.setup(PIN_VOLUMEDOWN, VolumeDownIntCallback) -- Volume down button
    
	--1.13 设置蓝牙设备名称
    deviceIMEI = misc.getImei()
    --deviceICCID = sim.getIccid()
    sixchar = string.sub(deviceIMEI,#deviceIMEI-5)
	btname = 'IceRTK_'..sixchar..'_SPP'
	blename = 'IceRTK_'..sixchar..'_BLE'
	SetBTName(btname,blename)

    --每5秒打印一下RAM和ROOM剩余空间
    --sys.timerLoopStart(deviceStatus, 5000)
end

function MainTask()
	--先初始化UART是因为deviceInit()中会用到蓝牙串口    
	uartdata.Init()  
	deviceInit()
    sys.taskInit(ledsUpdateTask)
	sys.taskInit(sdCardTask)
    sys.taskInit(uartdata.Task)

    --播放开机语音
	adcvol, batteryVoltage = adc.read(ADC_VBAT)
	adcvol, powerVoltage = adc.read(ADC_PWR)
	batteryVoltage = batteryVoltage *2
	powerVoltage = powerVoltage *2
	batteryPercent = math.floor((batteryVoltage-3400)/(42-34))
	if batteryPercent > 100 then batteryPercent = 100 end
    VoiceBatteryandSOC()

    --初始化MQTT连接需要的参数
    IMEI = misc.getImei()
    mqttclientid = 'BW10'..IMEI
    mqttpubgga ='/ICE/CORS/'..IMEI..'/GGA'
    mqttpubrtcm ='/ICE/CORS/'..IMEI..'/RTCM33'
    log.info('MQTT topic',mqttpubgga,mqttpubrtcm)

    --因为会造成阻塞，因此放在最后
    wifiinit()
    mqttinit()

    while true do
        if socket.isReady() and (mqttc ~= nil) then
            if uartdata.GPSFIXED and uartdata.mqttgga ~= nil and uartdata.mqttrtcm ~= nil then
                mqttc:publish(mqttpubgga, uartdata.mqttgga) 
                uartdata.mqttgga = nil
                mqttc:publish(mqttpubrtcm, uartdata.mqttrtcm)
                uartdata.mqttrtcm = nil
            end
        end    
        sys.wait(1000)
    end
end

sys.taskInit(MainTask)

--1表示充电开机的时候不启动GSM协议栈
sys.init(1, 0)
sys.run()
