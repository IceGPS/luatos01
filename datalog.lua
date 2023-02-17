module(..., package.seeall)

--首先根据GGA消息生成文件名，需要在定位成功之后GGA包含的日期时间数据才是正确的。因此需要设置一个全局标记，用于记录是否成功定位过

function date2logname()
    return os.date("%Y-%m-%d %H-%M-%S").."nmea"
end

function gga2logname()
    local ggaarray = {}
    for field in gpgga_message:gmatch("[^,]+") do
      table.insert(ggaarray, field)
    end
    local year = tonumber(ggaarray[2]:sub(1, 2))
    local month = tonumber(ggaarray[2]:sub(3, 4))
    local day = tonumber(ggaarray[2]:sub(5))
    local hour = tonumber(ggaarray[2]:sub(7, 8))
    local minute = tonumber(ggaarray[2]:sub(9, 10))
    local second = tonumber(ggaarray[2]:sub(11))
    local date = os.date("*t")
    date.year = year
    date.month = month
    date.day = day
    date.hour = hour
    date.min = minute
    date.sec = second
    local datetime_string = os.date("%Y%m%d%H%M%S", os.time(date))
    return datetime_string
end



function parse_gpgga(gpgga_message)
    local fields = {}
    for field in gpgga_message:gmatch("[^,]+") do
      table.insert(fields, field)
    end
  
    -- Extract the UTC time from the GPGGA message
    local time = fields[2]
  
    -- Convert the time to a Lua date object
    local hour = tonumber(time:sub(1, 2))
    local minute = tonumber(time:sub(3, 4))
    local second = tonumber(time:sub(5))
    local date = os.date("*t")
    date.hour = hour
    date.min = minute
    date.sec = second
  
    -- Format the date and time as a string
    local datetime_string = os.date("%Y-%m-%d %H:%M:%S", os.time(date))
  
    return datetime_string
  end
  
function log2file()
    -- Example usage
    local gpgga_message = "$GPGGA,030516.000,2239.5739,N,11401.7274,E,1,8,1.03,23.0,M,-3.3,M,,0000*60"
    local datetime_string = parse_gpgga(gpgga_message)
    print(datetime_string) -- Outputs "2023-02-16 03:05:16"

    local file = io.open("log.txt", "a")
    file:write("Hello World!")
    file:close()
end  
