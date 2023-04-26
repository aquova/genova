import ../utils

type Reg8* = enum
    A, F,
    B, C,
    D, E,
    H, L,

type Reg16* = enum
    AF,
    BC,
    DE,
    HL,
    IX,
    IY,

type Register* = object
    lo, hi: uint8

proc lo*(r: Register): uint8 =
    r.lo

proc `lo=`*(r: var Register, v: uint8) =
    r.lo = v

proc hi*(r: Register): uint8 =
    r.hi

proc `hi=`*(r: var Register, v: uint8) =
    r.hi = v

proc u16*(r: Register): uint16 =
    return merge_bytes(r.hi, r.lo)

proc `u16=`*(r: var Register, v: uint16) =
    r.lo = uint8(v and 0xF)
    r.hi = uint8((v and 0xF0) shr 8)
