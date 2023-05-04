import bus
import cpu/opcodes
import cpu/z80

import os

type MasterSystem = object
    cpu: Z80
    bus: Bus

proc initMS(): MasterSystem =
    result.bus = Bus()
    result.cpu = newZ80(result.bus)

proc loadGame(ms: var MasterSystem, filename: string) =
    let rom = readFile(filename)
    ms.bus.load(rom)

proc tick(ms: var MasterSystem) =
    let cycles = ms.cpu.execute()
    sleep(100)

proc main() =
    if paramCount() != 1:
        echo("genova path/to/ROM")
        return

    let rom_name = paramStr(1)
    if not rom_name.fileExists():
        echo("Unable to locate ROM file")
        return

    var emu = initMS()
    emu.loadGame(rom_name)
    while true:
        emu.tick()

when isMainModule:
    main()
