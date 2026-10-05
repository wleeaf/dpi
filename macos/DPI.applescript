on run
    repeat
        set stateText to do shell script "/opt/dpi/dpi status"
        set choice to choose from list {"Connect / apply settings", "Disconnect", "Disable startup", "Status", "Quit"} with title "DPI" with prompt stateText default items {"Connect / apply settings"}
        if choice is false or item 1 of choice is "Quit" then return
        try
            set actionName to item 1 of choice
            if actionName is "Connect / apply settings" then
                set trafficChoice to choose from list {"Discord", "All websites"} with title "DPI traffic" default items {"Discord"}
                if trafficChoice is not false then
                    set strategyChoice to choose from list {"Default", "Alternate"} with title "DPI strategy" with prompt "Try Alternate if connections fail with Default." default items {"Default"}
                    if strategyChoice is not false then
                        set trafficValue to "discord"
                        if item 1 of trafficChoice is "All websites" then set trafficValue to "all"
                        set strategyValue to "default"
                        if item 1 of strategyChoice is "Alternate" then set strategyValue to "split"
                        do shell script "/opt/dpi/dpi configure " & trafficValue & " " & strategyValue with administrator privileges
                        display dialog "Connected. Restart Discord. Calls may still fail on some networks." with title "DPI" buttons {"OK"} default button "OK"
                    end if
                end if
            else if actionName is "Disconnect" then
                do shell script "/opt/dpi/dpi stop" with administrator privileges
            else if actionName is "Disable startup" then
                do shell script "/opt/dpi/dpi disable" with administrator privileges
            else
                display dialog stateText with title "DPI" buttons {"OK"} default button "OK"
            end if
        on error errorText number errorNumber
            if errorNumber is not -128 then display dialog errorText with title "DPI" buttons {"OK"} default button "OK"
        end try
    end repeat
end run
