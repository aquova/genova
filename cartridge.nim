import errors

import bitops

const BANK_SIZE = 0x4000
const REGION_ADDR = 0x7FFF

type Region = enum
    INVALID,
    SMS_JPN,
    SMS_EXPORT,
    GG_JPN,
    GG_EXPORT,
    GG_INTRN,

type Slot* = enum
    Zero, One, Two

type Cartridge* = object
    data: seq[uint8]
    ram: array[BANK_SIZE, uint8]
    region: Region
    write_enabled: bool
    ram_enable_system: bool
    ram_enable_slot2: bool
    ram_bank_select: bool
    bank_shift: uint8
    slot0: uint8
    slot1: uint8
    slot2: uint8

# Forward declarations
proc get_bank(cart: Cartridge, slot: Slot): uint8
proc get_slot_control*(cart: Cartridge, slot: Slot): uint8

proc bank_read*(cart: Cartridge, slot: Slot, address: uint16): uint8 =
    if slot == Slot.Two and cart.ram_enable_slot2:
        let real_address = address - 2 * BANK_SIZE
        return cart.data[real_address]
    else:
        let bank_num = cart.get_bank(slot)
        let real_address = address + bank_num * BANK_SIZE
        return cart.data[real_address]

proc bank_write*(cart: var Cartridge, slot: Slot, address: uint16, value: uint8) =
    if slot == Slot.Two and cart.ram_enable_slot2:
        let real_address = address - 2 * BANK_SIZE
        cart.data[real_address] = value
    else:
        let bank_num = cart.get_bank(slot)
        let real_address = address + bank_num * BANK_SIZE
        cart.data[real_address] = value

proc get_mapper_control*(cart: Cartridge): uint8 =
    if cart.write_enabled: result.setBit(7)
    if cart.ram_enable_system: result.setBit(4)
    if cart.ram_enable_slot2: result.setBit(3)
    if cart.ram_bank_select: result.setBit(2)
    result = result or cart.bank_shift

proc get_bank(cart: Cartridge, slot: Slot): uint8 =
    result = cart.get_slot_control(slot)
    case cart.bank_shift:
        of 0b00: discard
        of 0b01: result += 0x18
        of 0b10: result += 0x10
        of 0b11: result += 0x08
        else: raise newException(UnreachableError, "")

proc get_slot_control*(cart: Cartridge, slot: Slot): uint8 =
    case slot:
        of Slot.Zero: return cart.slot0
        of Slot.One: return cart.slot1
        of Slot.Two: return cart.slot2

proc loadGame*(rom: openarray[char]): Cartridge =
    for byte in rom:
        result.data.add(uint8(byte))

    # Default slot values
    result.slot0 = 0
    result.slot1 = 1
    result.slot2 = 2

    let region_info = result.data[REGION_ADDR] and 0xF0 # Only high 4 bits used
    result.region = case region_info:
        of 0x30: Region.SMS_JPN
        of 0x40: Region.SMS_EXPORT
        of 0x50: Region.GG_JPN
        of 0x60: Region.GG_EXPORT
        of 0x70: Region.GG_INTRN
        else: Region.INVALID

proc is_cart_ram_mapped*(cart: Cartridge): bool =
    return cart.ram_enable_system

proc ram_read*(cart: Cartridge, address: uint16): uint8 =
    return cart.ram[address]

proc ram_write*(cart: var Cartridge, address: uint16, value: uint8) =
    cart.ram[address] = value

proc set_mapper_control*(cart: var Cartridge, value: uint8) =
    cart.write_enabled = value.testBit(7)
    cart.ram_enable_system = value.testBit(4)
    cart.ram_enable_slot2 = value.testBit(3)
    cart.ram_bank_select = value.testBit(2)
    cart.bank_shift = value and 0x3

proc set_slot_control*(cart: var Cartridge, slot: Slot, value: uint8) =
    case slot:
        of Slot.Zero: cart.slot0 = value
        of Slot.One: cart.slot1 = value
        of Slot.Two: cart.slot2 = value

proc unpaged_read*(cart: Cartridge, address: uint16): uint8 =
    return cart.data[address]

proc unpaged_write*(cart: var Cartridge, address: uint16, value: uint8) =
    cart.data[address] = value
