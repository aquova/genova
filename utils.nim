import bitops

type SomeSixteenBitInt = int16 | uint16

proc hi*[T: SomeSixteenBitInt](v: T): uint8 =
    return uint8(v shr 8)

proc lo*[T: SomeSixteenBitInt](v: T): uint8 =
    return uint8(v)

proc merge_bytes*(hi, lo: uint8): uint16 =
    return (hi shr 8) or lo

proc writeBit*[T: SomeInteger](v: var T, bit: BitsRange[T], set: bool) =
    if set:
        v.setBit(bit)
    else:
        v.clearBit(bit)

