term.clear()
term.setCursorPos(1,1)
print("Welcome to Passport Manage System")
print("Version = 0.1 ALPHA")
print("1=Create a new pastport disk")
print("2=Check now pastport disk")
print("3=Edit now passport disk")
print("Choise and Enter")
while true do
    Disk_drive = peripheral.wrap("right") 
    local input = read()
    if input == "1" then
        term.clear()
        term.setCursorPos(1,1)
        print("Create a new passport disk")
        if disk.isPresent("right") == true then
            print("Warning!This action will delete all data of this disk!")
            print("Are you sure?")
            print("Enter yes or no below")
            local input1 = read()
            if input1 == "yes" then
                --fs.delete("disk/")
                print("No delete!")
                local P = io.open("Passport.txt","w")
                print("Enter Name")
                local Name = read()
                print("Enter Age")
                local Age= read()
                local Time = os.day()
                print("Time:",Time)
                print("Enter ID")
                local ID = read()
                P:write("Name:",Name,"\n")
                P:write("Age:",Age,"\n")
                P:write("ID:",ID,"\n")
                P:write("Time:",Time,"\n")
                P:close()
                print("Write done!")
                fs.move("/Passport.txt","/disk/")
                break
                else
                    disk.eject("right")
                    print("Disk ejected!")
                    break
            end
            else
                print("Plese input a disk!")
                break
        end
        
        
    end
end
