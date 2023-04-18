import bitops

type SomeSixteenBitInt = int16 | uint16

proc hi*[T: SomeSixteenBitInt](v: T): uint8 =
    return uint8(v shr 8)

proc lo*[T: SomeSixteenBitInt](v: T): uint8 =
    return uint8(v)

proc check_h_carry*(hi, lo: uint8): bool =
    return (((hi and 0xF) + (lo and 0xF)) and 0x10) == 0x10

proc check_h_carry*(hi, lo: uint16): bool =
    return (((hi and 0xFFF) + (lo and 0xFFF)) and 0x1000) == 0x1000

proc will_underflow*[T: SomeInteger](a, b: T): bool =
    let diff = int(a) - int(b)
    return diff < int(low(T))

proc check_h_borrow*[T: SomeInteger](hi, lo: T): bool =
    return will_underflow(hi and 0xF, lo and 0xF)

proc will_overflow*[T: SomeInteger](a, b: T): bool =
    let sum = int(a) + int(b)
    return sum > int(high(T))

proc merge_bytes*(hi, lo: uint8): uint16 =
    # TODO: Make sure this is casting first
    return (hi shr 8) or lo

proc writeBit*[T: SomeInteger](v: var T, bit: BitsRange[T], set: bool) =
    if set:
        v.setBit(bit)
    else:
        v.clearBit(bit)

