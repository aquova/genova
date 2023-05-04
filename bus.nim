# Memory Map
#
# +--Cartridge-ROM/RAM---+ $0000
# |     Unpaged ROM      |
# +----------------------+ $0400
# |                      |
# |      Slot 0 ROM      |
# |                      |
# +----------------------+ $4000
# |                      |
# |      Slot 1 ROM      |
# |                      |
# +----------------------+ $8000
# |                      |
# |    Slot 2 ROM/RAM    |
# |                      |
# +------System-RAM------+ $C000
# |      System RAM      |
# +----------------------+ $E000
# |   System RAM Mirror  |
# +----------------------+ $FFF8
# | 3D Glasses Controls  |
# +----------------------+ $FFFC
# |    Mapper Control    |
# +----------------------+ $FFFD
# |    Slot 0 Control    |
# +----------------------+ $FFFE
# |    Slot 1 Control    |
# +----------------------+ $FFFF
# |    Slot 2 Control    |
# +----------------------+

import cartridge

type Bus* = ref object
    cart: Cartridge
    internal_RAM: array[0xC000..0xDFFF, uint8]

proc load*(bus: var Bus, data: openarray[char]) =
    bus.cart = loadGame(data)

proc ram_read*(bus: Bus, address: uint16): uint8 =
    case address:
        of 0x0000..0x03FF: # Unpaged ROM
            return bus.cart.unpaged_read(address)
        of 0x0400..0x3FFF: # Slot 0 ROM
            return bus.cart.bank_read(Slot.Zero, address)
        of 0x4000..0x7FFF: # Slot 1 ROM
            return bus.cart.bank_read(Slot.One, address)
        of 0x8000..0xBFFF: # Slot 2 ROM/RAM
            return bus.cart.bank_read(Slot.Two, address)
        of 0xC000..0xDFFF: # Internal RAM
            if bus.cart.is_cart_ram_mapped():
                return bus.cart.ram_read(address - 0xC000)
            else:
                return bus.internal_RAM[address]
        of 0xE000..0xFFFB: # RAM Mirror
            if bus.cart.is_cart_ram_mapped():
                return bus.cart.ram_read(address - 0xE000)
            else:
                let mirrored_addr = address - 0x2000
                return bus.internal_RAM[mirrored_addr]
        of 0xFFFC: # Mapper control
            return bus.cart.get_mapper_control()
        of 0xFFFD: # Slot 0 control
            return bus.cart.get_slot_control(Slot.Zero)
        of 0xFFFE: # Slot 1 control
            return bus.cart.get_slot_control(Slot.One)
        of 0xFFFF: # Slot 2 control
            return bus.cart.get_slot_control(Slot.Two)

proc ram_write*(bus: var Bus, address: uint16, value: uint8) =
    case address:
        of 0x0000..0x03FF: # Unpaged ROM
            bus.cart.unpaged_write(address, value)
        of 0x0400..0x3FFF: # Slot 0 ROM
            bus.cart.bank_write(Slot.Zero, address, value)
        of 0x4000..0x7FFF: # Slot 1 ROM
            bus.cart.bank_write(Slot.One, address, value)
        of 0x8000..0xBFFF: # Slot 2 ROM/RAM
            bus.cart.bank_write(Slot.Two, address, value)
        of 0xC000..0xDFFF: # Internal RAM
            if bus.cart.is_cart_ram_mapped():
                bus.cart.ram_write(address - 0xC000, value)
            else:
                bus.internal_RAM[address] = value
        of 0xE000..0xFFFB: # RAM Mirror
            if bus.cart.is_cart_ram_mapped():
                bus.cart.ram_write(address - 0xE000, value)
            else:
                let mirrored_addr = address - 0x2000
                bus.internal_RAM[mirrored_addr] = value
        of 0xFFFC: # Mapper control
            bus.cart.set_mapper_control(value)
        of 0xFFFD: # Slot 0 control
            bus.cart.set_slot_control(Slot.Zero, value)
        of 0xFFFE: # Slot 1 control
            bus.cart.set_slot_control(Slot.One, value)
        of 0xFFFF: # Slot 2 control
            bus.cart.set_slot_control(Slot.Two, value)

