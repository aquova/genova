import flags
import registers
import ../utils

type Z80* = object
    pc: uint16
    sp: uint16
    r: uint8
    i: uint8
    af: Register
    bc: Register
    de: Register
    hl: Register
    af_shadow: Register
    bc_shadow: Register
    de_shadow: Register
    hl_shadow: Register
    ix: Register
    iy: Register
    halted: bool
    irq_enabled: bool

# Forward declarations
proc ram_read*(z80: var Z80, address: uint16): uint8

proc newZ80*(): Z80 =
    # TODO: These are the init values for GB, need to check what these should be set to
    result.pc = 0x100
    result.sp = 0xFFFE
    result.af.u16 = 0x01B0
    result.bc.u16 = 0x0013
    result.de.u16 = 0x00D8
    result.hl.u16 = 0x014D
    result.halted = false
    result.irq_enabled = false

proc exchange*(z80: var Z80, reg: Reg16) =
    case (reg):
        of Reg16.AF: swap(z80.af, z80.af_shadow)
        of Reg16.BC: swap(z80.bc, z80.bc_shadow)
        of Reg16.DE: swap(z80.de, z80.de_shadow)
        of Reg16.HL: swap(z80.hl, z80.hl_shadow)
        else: assert(false, "Invalid register")

proc fetch*(z80: var Z80): uint8 =
    let val = z80.ram_read(z80.pc)
    z80.pc = z80.pc + 1
    return val

proc fetch16*(z80: var Z80): uint16 =
    let low = z80.fetch()
    let high = z80.fetch()
    result = merge_bytes(high, low)

proc flag*(z80: Z80, flag: Flag): bool =
    case flag:
        of Flag.S: result = (z80.af.lo and 0b1000_0000) != 0
        of Flag.Z: result = (z80.af.lo and 0b0100_0000) != 0
        of Flag.H: result = (z80.af.lo and 0b0001_0000) != 0
        of Flag.PV: result = (z80.af.lo and 0b0000_0100) != 0
        of Flag.N: result = (z80.af.lo and 0b0000_0010) != 0
        of Flag.C: result = (z80.af.lo and 0b0000_0001) != 0

proc flag_clear*(z80: var Z80, flag: Flag) =
    let f = z80.af.lo
    case flag:
        of Flag.S: z80.af.lo = f and 0b0111_1111
        of Flag.Z: z80.af.lo = f and 0b1011_1111
        of Flag.H: z80.af.lo = f and 0b1110_1111
        of Flag.PV: z80.af.lo = f and 0b1111_1011
        of Flag.N: z80.af.lo = f and 0b1111_1101
        of Flag.C: z80.af.lo = f and 0b1111_1110

proc flag_set*(z80: var Z80, flag: Flag) =
    let f = z80.af.lo
    case flag:
        of Flag.S: z80.af.lo = f or 0b1000_0000
        of Flag.Z: z80.af.lo = f or 0b0100_0000
        of Flag.H: z80.af.lo = f or 0b0001_0000
        of Flag.PV: z80.af.lo = f or 0b0000_0100
        of Flag.N: z80.af.lo = f or 0b0000_0010
        of Flag.C: z80.af.lo = f or 0b0000_0001

proc flag_write*(z80: var Z80, f: Flag, val: bool) =
    if val: z80.flag_set(f) else: z80.flag_clear(f)

proc halted*(z80: Z80): bool =
    return z80.halted

proc `halted=`*(z80: var Z80, halt: bool) =
    z80.halted = halt

proc `irq_enabled=`*(z80: var Z80, irq: bool) =
    z80.irq_enabled = irq

proc pc*(z80: Z80): uint16 =
    z80.pc

proc `pc=`*(z80: var Z80, val: uint16) =
    z80.pc = val

proc port_read*(z80: Z80, port: uint8): uint8 =
    return 0 # FIXME

proc port_write*(z80: var Z80, port: uint8, data: uint8) =
    discard # FIXME

proc ram_read*(z80: var Z80, address: uint16): uint8 =
    return 0 # FIXME

proc ram_write*(z80: var Z80, address: uint16, byte: uint8) =
    discard # FIXME

proc reg*(z80: Z80, r: Reg8): uint8 =
    case r:
        of Reg8.A: z80.af.hi
        of Reg8.B: z80.bc.hi
        of Reg8.C: z80.bc.lo
        of Reg8.D: z80.de.hi
        of Reg8.E: z80.de.lo
        of Reg8.F: z80.af.lo
        of Reg8.H: z80.hl.hi
        of Reg8.L: z80.hl.lo

proc reg*(z80: Z80, r: Reg16): uint16 =
    case r:
        of Reg16.AF: z80.af.u16
        of Reg16.BC: z80.bc.u16
        of Reg16.DE: z80.de.u16
        of Reg16.HL: z80.hl.u16
        of Reg16.IX: z80.ix.u16
        of Reg16.IY: z80.iy.u16

proc reg_write*(z80: var Z80, r: Reg8, val: uint8) =
    case r:
        of Reg8.A: z80.af.hi = val
        of Reg8.B: z80.bc.hi = val
        of Reg8.C: z80.bc.lo = val
        of Reg8.D: z80.de.hi = val
        of Reg8.E: z80.de.lo = val
        of Reg8.F: z80.af.lo = val
        of Reg8.H: z80.hl.hi = val
        of Reg8.L: z80.hl.lo = val

proc reg_write*(z80: var Z80, r: Reg16, val: uint16) =
    case r:
        of Reg16.AF: z80.af.u16 = val
        of Reg16.BC: z80.bc.u16 = val
        of Reg16.DE: z80.de.u16 = val
        of Reg16.HL: z80.hl.u16 = val
        of Reg16.IX: z80.ix.u16 = val
        of Reg16.IY: z80.iy.u16 = val

proc sp*(z80: Z80): uint16 =
    z80.sp

proc `sp=`*(z80: var Z80, val: uint16) =
    z80.sp = val

