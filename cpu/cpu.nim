import opcodes
import z80

type CPU* = object
    z80: Z80

proc newCPU*(): CPU =
    result.z80 = newZ80()

proc tick(cpu: var CPU) =
    let cycles = if cpu.z80.halted: 1u8 else: cpu.z80.execute()
