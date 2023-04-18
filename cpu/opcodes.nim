import bitops

import flags
import registers
import z80

import ../utils

proc add_a(z80: var Z80, val: uint8, adc: bool) =
    var carry: uint8 = 0
    if adc and z80.flag(Flag.C):
        carry = 1
    let a = z80.reg(Reg8.A)

    let result1 = a + val
    let overflowed1 = will_overflow(a, val)
    let h_check1 = check_h_carry(a, val)

    let result2 = result1 + carry
    let overflowed2 = will_overflow(result1, carry)
    let h_check2 = check_h_carry(result1, carry)

    let set_h = h_check1 or h_check2
    let set_c = overflowed1 or overflowed2

    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.C, set_c)
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.Z, result2 == 0)
    z80.reg_write(Reg8.A, result2)

proc add(z80: var Z80, reg: Reg16, source: uint16) =
    let target = z80.reg(reg)
    let sum = target + source
    let overflowed = will_overflow(target, source)
    let set_h = check_h_carry(target, source)

    z80.reg_write(reg, sum)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.C, overflowed)
    z80.flag_write(Flag.H, set_h)

proc and_a(z80: var Z80, val: uint8) =
    var a = z80.reg(Reg8.A)
    a = a and val
    z80.flag_clear(Flag.N)
    z80.flag_set(Flag.H)
    z80.flag_clear(Flag.C)
    z80.flag_write(Flag.Z, a == 0)
    z80.reg_write(Reg8.A, a)

proc check_bit(z80: var Z80, val: uint8, digit: uint8) =
    let bit = val.test_bit(digit)

    z80.flag_write(Flag.Z, not bit)
    z80.flag_clear(Flag.N)
    z80.flag_set(Flag.H)

proc check_bit_reg(z80: var Z80, reg: Reg8, digit: uint8) =
    let byte = z80.reg(reg)
    z80.check_bit(byte, digit)

proc cp_a(z80: var Z80, val: uint8) =
    let a = z80.reg(Reg8.A)
    let set_h = check_h_borrow(a, val)

    z80.flag_write(Flag.Z, a == val)
    z80.flag_set(Flag.N)
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.C, a < val)

proc daa(z80: var Z80) =
    var a = int32(z80.reg(Reg8.A))

    if not z80.flag(Flag.N):
        if z80.flag(Flag.H) or (a and 0x0F) > 0x09:
            a += 0x06

        if z80.flag(Flag.C) or a > 0x9F:
            a += 0x60
    else:
        if z80.flag(Flag.H):
            a = (a - 6) and 0xFF

        if z80.flag(Flag.C):
            a -= 0x60

    z80.flag_clear(Flag.H)
    z80.flag_clear(Flag.Z)

    if (a and 0x100) == 0x100:
        z80.flag_set(Flag.C)

    a = a and 0xFF
    z80.flag_write(Flag.Z, a == 0)
    z80.reg_write(Reg8.A, uint8(a))

proc dec(z80: var Z80, reg: Reg8) =
    let val = z80.reg(reg)
    let sub = val - 1
    let set_h = check_h_borrow(val, 1)
    z80.reg_write(reg, sub)
    z80.flag_set(Flag.N)
    z80.flag_write(Flag.Z, sub == 0)
    z80.flag_write(Flag.H, set_h)

proc dec(z80: var Z80, reg: Reg16) =
    let val = z80.reg(reg)
    let sum = val + 1
    z80.reg_write(reg, sum)

proc inc(z80: var Z80, reg: Reg8) =
    let val = z80.reg(reg)
    let sum = val + 1
    let set_h = check_h_carry(val, 1)
    z80.reg_write(reg, sum)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.Z, sum == 0)
    z80.flag_write(Flag.H, set_h)

proc inc(z80: var Z80, reg: Reg16) =
    let val = z80.reg(reg)
    let sum = val + 1
    z80.reg_write(reg, sum)

proc ld(z80: var Z80, reg: Reg8, val: uint8) =
    z80.reg_write(reg, val)

proc ld(z80: var Z80, reg: Reg16, val: uint16) =
    z80.reg_write(reg, val)

proc or_a(z80: var Z80, val: uint8) =
    var a = z80.reg(Reg8.A)
    a = a or val
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_clear(Flag.C)
    z80.flag_write(Flag.Z, a == 0)
    z80.reg_write(Reg8.A, a)

proc pop(z80: var Z80): uint16 =
    assert(z80.sp != 0xFFFE, "Trying to pop when stack is empty")
    let lo = z80.ram_read(z80.sp)
    let hi = z80.ram_read(z80.sp + 1)
    result = merge_bytes(hi, lo)
    z80.sp = z80.sp + 2

proc push(z80: var Z80, val: uint16) =
    let sp = z80.sp - 2
    z80.ram_write(sp + 1, val.hi())
    z80.ram_write(sp, val.lo())
    z80.sp = sp

proc rot_left(z80: var Z80, byte: uint8, carry: bool): uint8 =
    let msb = byte.test_bit(7)
    var rot = byte.rotate_left_bits(1)
    if carry:
        let old_c = z80.flag(Flag.C)
        rot.write_bit(0, old_c)
    z80.flag_write(Flag.C, msb)
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_write(Flag.Z, rot == 0)
    return rot

proc rot_left_reg(z80: var Z80, reg: Reg8, carry: bool) =
    let val = z80.reg(reg)
    let rot = z80.rot_left(val, carry)
    z80.reg_write(reg, rot)

proc rot_right(z80: var Z80, byte: uint8, carry: bool): uint8 =
    let lsb = byte.test_bit(0)
    var rot = byte.rotate_right_bits(1)
    if carry:
        let old_c = z80.flag(Flag.C)
        rot.write_bit(7, old_c)
    z80.flag_write(Flag.C, lsb)
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_write(Flag.Z, rot == 0)
    return rot

proc rot_right_reg(z80: var Z80, reg: Reg8, carry: bool) =
    let val = z80.reg(reg)
    let rot = z80.rot_right(val, carry)
    z80.reg_write(reg, rot)

proc shift_left(z80: var Z80, byte: uint8): uint8 =
    let msb = byte.test_bit(7)
    let shifted = byte shl 1

    z80.flag_write(Flag.Z, shifted == 0)
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_write(Flag.C, msb)
    return shifted

proc shift_left_reg(z80: var Z80, reg: Reg8) =
    let byte = z80.reg(reg)
    let shifted = z80.shift_left(byte)
    z80.reg_write(reg, shifted)

proc shift_right(z80: var Z80, byte: uint8, arith: bool): uint8 =
    let lsb = byte.test_bit(0)
    let msb = byte.test_bit(7)
    var shifted = byte shr 1
    if arith:
        shifted.write_bit(7, msb)

    z80.flag_write(Flag.Z, shifted == 0)
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_write(Flag.C, lsb)

    return shifted

proc shift_right_reg(z80: var Z80, reg: Reg8, arith: bool) =
    let byte = z80.reg(reg)
    let shifted = z80.shift_right(byte, arith)
    z80.reg_write(reg, shifted)

proc sub_a(z80: var Z80, val: uint8, sbc: bool) =
    let carry: uint8 = if sbc and z80.flag(Flag.C): 1 else: 0
    let a = z80.reg(Reg8.A)

    let result1 = a - val
    let underflowed1 = will_underflow(a, val)
    let check_h1 = check_h_borrow(a, val)

    let result2 = result1 - carry
    let underflowed2 = will_underflow(result1, carry)
    let check_h2 = check_h_borrow(result1, carry)

    let set_h = check_h1 or check_h2
    let set_c = underflowed1 or underflowed2

    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.C, set_c)
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.Z, result2 == 0)
    z80.reg_write(Reg8.A, result2)

proc swap_bits(z80: var Z80, val: uint8): uint8 =
    let new_high = val and 0xF
    let new_low = (val and 0xF0) shr 4
    let new_val = (new_high shl 4) or new_low

    z80.flag_write(Flag.Z, new_val == 0)
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_clear(Flag.C)

    return new_val

proc swap_bits_reg(z80: var Z80, reg: Reg8) =
    let byte = z80.reg(reg)
    let swapped = z80.swap_bits(byte)
    z80.reg_write(reg, swapped)

proc write_bit_n(z80: var Z80, reg: Reg8, digit: uint8, set: bool) =
    var r = z80.reg(reg)
    r.writeBit(digit, set)
    z80.reg_write(reg, r)

proc write_bit_ram(z80: var Z80, address: uint16, digit: uint8, set: bool) =
    var val = z80.ram_read(address)
    val.writeBit(digit, set)
    z80.ram_write(address, val)

proc xor_a(z80: var Z80, val: uint8) =
    var a = z80.reg(Reg8.A)
    a = a xor val
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_clear(Flag.C)
    z80.flag_write(Flag.Z, a == 0)
    z80.reg_write(Reg8.A, a)

# NOP
proc nop_00(z80: var Z80): uint8 = 1

# LD BC, d16
proc ld_01(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let val = merge_bytes(high, low)
    z80.ld(Reg16.BC, val)
    return 3

# LD (BC), A
proc ld_02(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    let val = z80.reg(Reg8.A)
    z80.ram_write(bc, val)
    return 2

# INC BC
proc inc_03(z80: var Z80): uint8 =
    z80.inc(Reg16.BC)
    return 2

# INC B
proc inc_04(z80: var Z80): uint8 =
    z80.inc(Reg8.B)
    return 1

# DEC B
proc dec_05(z80: var Z80): uint8 =
    z80.dec(Reg8.B)
    return 1

# LD B, d8
proc ld_06(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.ld(Reg8.B, byte)
    return 2

# RLCA
proc rlca_07(z80: var Z80): uint8 =
    z80.rot_left_reg(Reg8.A, false)
    # RLCA wants Z to be cleared (unlike other shift ops)
    z80.flag_clear(Flag.Z)
    return 1

# LD (a16), SP
proc ld_08(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let address = merge_bytes(high, low)
    let sp = z80.sp()
    z80.ram_write(address, sp.lo())
    z80.ram_write(address + 1, sp.hi())
    return 5

# ADD HL, BC
proc add_09(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    z80.add(Reg16.HL, bc)
    return 2

# LD A, (BC)
proc ld_0a(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    let val = z80.ram_read(bc)
    z80.ld(Reg8.A, val)
    return 2

# DEC BC
proc dec_0b(z80: var Z80): uint8 =
    z80.dec(Reg16.BC)
    return 2

# INC C
proc inc_0c(z80: var Z80): uint8 =
    z80.inc(Reg8.C)
    return 1

# DEC C
proc dec_0d(z80: var Z80): uint8 =
    z80.dec(Reg8.C)
    return 1

# LD C, d8
proc ld_0e(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.ld(Reg8.C, byte)
    return 2

# RRCA
proc rrca_0f(z80: var Z80): uint8 =
    z80.rot_right_reg(Reg8.A, false)
    # RRCA wants Z to be cleared (unlike other shift ops)
    z80.flag_clear(Flag.Z)
    return 1

# STOP
proc stop_10(z80: var Z80): uint8 =
    # Do nothing
    return 1

# LD DE, d16
proc ld_11(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let val = merge_bytes(high, low)
    z80.ld(Reg16.DE, val)
    return 3

# LD (DE), A
proc ld_12(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    let val = z80.reg(Reg8.A)
    z80.ram_write(de, val)
    return 2

# INC DE
proc inc_13(z80: var Z80): uint8 =
    z80.inc(Reg16.DE)
    return 2

# INC D
proc inc_14(z80: var Z80): uint8 =
    z80.inc(Reg8.D)
    return 1

# DEC D
proc dec_15(z80: var Z80): uint8 =
    z80.dec(Reg8.D)
    return 1

# LD D, d8
proc ld_16(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.ld(Reg8.D, byte)
    return 2

# RLA
proc rla_17(z80: var Z80): uint8 =
    z80.rot_left_reg(Reg8.A, true)
    # RLA wants Z to be cleared (unlike other shift ops)
    z80.flag_clear(Flag.Z)
    return 1

# JR r8
proc jr_18(z80: var Z80): uint8 =
    let offset = z80.fetch()
    var pc = z80.pc
    pc = pc + offset
    z80.pc = pc
    return 3

# ADD HL, DE
proc add_19(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    z80.add(Reg16.HL, de)
    return 2

# LD A, (DE)
proc ld_1a(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    let val = z80.ram_read(de)
    z80.reg_write(Reg8.A, val)
    return 2

# DEC DE
proc dec_1b(z80: var Z80): uint8 =
    z80.dec(Reg16.DE)
    return 2

# INC E
proc inc_1c(z80: var Z80): uint8 =
    z80.inc(Reg8.E)
    return 1

# DEC E
proc dec_1d(z80: var Z80): uint8 =
    z80.dec(Reg8.E)
    return 1

# LD E, d8
proc ld_1e(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.ld(Reg8.E, byte)
    return 2

# RRA
proc rra_1f(z80: var Z80): uint8 =
    z80.rot_right_reg(Reg8.A, true)
    # RRA wants Z to be cleared (unlike other shift ops)
    z80.flag_clear(Flag.Z)
    return 1

# JR NZ, r8
proc jr20(z80: var Z80): uint8 =
    let offset = z80.fetch()
    let signed = cast[int8](offset)
    if not z80.flag(Flag.Z):
        var pc = z80.pc()
        pc += uint16(signed)
        z80.pc = pc
        return 3
    else:
        return 2

# LD HL, d16
proc ld_21(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let val = merge_bytes(high, low)
    z80.ld(Reg16.HL, val)
    return 3

# LD (HL+), A
proc ld_22(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.reg(Reg8.A)
    z80.ram_write(hl, val)
    z80.inc(Reg16.HL)
    return 2

# INC HL
proc inc_23(z80: var Z80): uint8 =
    z80.inc(Reg16.HL)
    return 2

# INC H
proc inc_24(z80: var Z80): uint8 =
    z80.inc(Reg8.H)
    return 1

# DEC H
proc dec_25(z80: var Z80): uint8 =
    z80.dec(Reg8.H)
    return 1

# LD H, d8
proc ld_26(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.ld(Reg8.H, byte)
    return 2

# DAA
proc daa_27(z80: var Z80): uint8 =
    z80.daa()
    return 1

# JR Z, r8
proc jr_28(z80: var Z80): uint8 =
    let offset = z80.fetch()
    let signed = cast[int8](offset)
    if z80.flag(Flag.Z):
        var pc = z80.pc()
        pc += uint16(signed)
        z80.pc = pc
        return 3
    else:
        return 2

# ADD HL, HL
proc add_29(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    z80.add(Reg16.HL, hl)
    return 2

# LD A, (HL+)
proc ld_2a(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.reg_write(Reg8.A, val)
    z80.inc(Reg16.HL)
    return 2

# DEC HL
proc dec_2b(z80: var Z80): uint8 =
    z80.dec(Reg16.HL)
    return 2

# INC L
proc inc_2c(z80: var Z80): uint8 =
    z80.inc(Reg8.L)
    return 1

# DEC L
proc dec_2d(z80: var Z80): uint8 =
    z80.dec(Reg8.L)
    return 1

# LD L, d8
proc ld_2e(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.ld(Reg8.L, byte)
    return 2

# CPL
proc cpl_2f(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.reg_write(Reg8.A, not val)
    z80.flag_set(Flag.N)
    z80.flag_set(Flag.H)
    return 1

# JR NC, r8
proc jr_30(z80: var Z80): uint8 =
    let offset = z80.fetch()
    let signed = cast[int8](offset)
    if not z80.flag(Flag.C):
        var pc = z80.pc()
        pc += uint16(signed)
        z80.pc = pc
        return 3
    else:
        return 2

# LD SP, d16
proc ld_31(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    z80.sp = merge_bytes(high, low)
    return 3

# LD (HL-), A
proc ld_32(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.reg(Reg8.A)
    z80.ram_write(hl, val)
    z80.dec(Reg16.HL)
    return 2

# INC SP
proc inc_33(z80: var Z80): uint8 =
    let sp = z80.sp()
    z80.sp = (sp - 1)
    return 2

# INC (HL)
proc inc_34(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    let new_val = val + 1
    z80.ram_write(hl, new_val)

    let set_h = check_h_carry(val, 1)
    z80.flag_write(Flag.Z, new_val == 0)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.H, set_h)
    return 3

# DEC (HL)
proc dec_35(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    let new_val = val + 1
    z80.ram_write(hl, new_val)

    let set_h = check_h_borrow(val, 1)
    z80.flag_write(Flag.Z, new_val == 0)
    z80.flag_set(Flag.N)
    z80.flag_write(Flag.H, set_h)
    return 3

# LD (HL), d8
proc ld_36(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.fetch()
    z80.ram_write(hl, val)
    return 3

# SCF
proc scf_37(z80: var Z80): uint8 =
    z80.flag_set(Flag.C)
    z80.flag_clear(Flag.H)
    z80.flag_clear(Flag.N)
    return 1

# JR C, r8
proc jr_38(z80: var Z80): uint8 =
    let offset = z80.fetch()
    let signed = cast[int8](offset)
    if z80.flag(Flag.C):
        var pc = z80.pc()
        pc += uint16(signed)
        z80.pc = pc
        return 3
    else:
        return 2

# ADD HL, SP
proc add_39(z80: var Z80): uint8 =
    let sp = z80.sp()
    z80.add(Reg16.HL, sp)
    return 2

# LD A, (HL-)
proc ld_3a(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.reg_write(Reg8.A, val)
    z80.dec(Reg16.HL)
    return 2

# DEC SP
proc dec_3b(z80: var Z80): uint8 =
    let sp = z80.sp()
    z80.sp = (sp - 1)
    return 2

# INC A
proc inc_3c(z80: var Z80): uint8 =
    z80.inc(Reg8.A)
    return 1

# DEC A
proc dec_3d(z80: var Z80): uint8 =
    z80.dec(Reg8.A)
    return 1

# LD A, d8
proc ld_3e(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.ld(Reg8.A, byte)
    return 2

# CCF
proc ccf_3f(z80: var Z80): uint8 =
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    let cf = z80.flag(Flag.C)
    z80.flag_write(Flag.C, not cf)
    return 1

# LD B, B
proc ld_40(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.ld(Reg8.B, byte)
    return 1

# LD B, C
proc ld_41(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.ld(Reg8.B, byte)
    return 1

# LD B, D
proc ld_42(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.ld(Reg8.B, byte)
    return 1

# LD B, E
proc ld_43(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.ld(Reg8.B, byte)
    return 1

# LD B, H
proc ld_44(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.ld(Reg8.B, byte)
    return 1

# LD B, L
proc ld_45(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.ld(Reg8.B, byte)
    return 1

# LD B, (HL)
proc ld_46(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.reg_write(Reg8.B, val)
    return 2

# LD B, A
proc ld_47(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.ld(Reg8.B, byte)
    return 1

# LD C, B
proc ld_48(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.ld(Reg8.C, byte)
    return 1

# LD C, C
proc ld_49(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.ld(Reg8.C, byte)
    return 1

# LD C, D
proc ld_4a(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.ld(Reg8.C, byte)
    return 1

# LD C, E
proc ld_4b(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.ld(Reg8.C, byte)
    return 1

# LD C, H
proc ld_4c(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.ld(Reg8.C, byte)
    return 1

# LD C, L
proc ld_4d(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.ld(Reg8.C, byte)
    return 1

# LD C, (HL)
proc ld_4e(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.reg_write(Reg8.C, val)
    return 2

# LD C, A
proc ld_4f(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.ld(Reg8.C, byte)
    return 1

# LD D, B
proc ld_50(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.ld(Reg8.D, byte)
    return 1

# LD D, C
proc ld_51(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.ld(Reg8.D, byte)
    return 1

# LD D, D
proc ld_52(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.ld(Reg8.D, byte)
    return 1

# LD D, E
proc ld_53(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.ld(Reg8.D, byte)
    return 1

# LD D, H
proc ld_54(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.ld(Reg8.D, byte)
    return 1

# LD D, L
proc ld_55(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.ld(Reg8.D, byte)
    return 1

# LD D, (HL)
proc ld_56(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.reg_write(Reg8.D, val)
    return 2

# LD D, A
proc ld_57(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.ld(Reg8.D, byte)
    return 1

# LD E, B
proc ld_58(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.ld(Reg8.E, byte)
    return 1

# LD E, C
proc ld_59(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.ld(Reg8.E, byte)
    return 1

# LD E, D
proc ld_5a(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.ld(Reg8.E, byte)
    return 1

# LD E, E
proc ld_5b(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.ld(Reg8.E, byte)
    return 1

# LD E, H
proc ld_5c(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.ld(Reg8.E, byte)
    return 1

# LD E, L
proc ld_5d(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.ld(Reg8.E, byte)
    return 1

# LD E, (HL)
proc ld_5e(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.reg_write(Reg8.E, val)
    return 2

# LD E, A
proc ld_5f(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.ld(Reg8.E, byte)
    return 1

# LD H, B
proc ld_60(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.ld(Reg8.H, byte)
    return 1

# LD H, C
proc ld_61(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.ld(Reg8.H, byte)
    return 1

# LD H, D
proc ld_62(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.ld(Reg8.H, byte)
    return 1

# LD H, E
proc ld_63(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.ld(Reg8.H, byte)
    return 1

# LD H, H
proc ld_64(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.ld(Reg8.H, byte)
    return 1

# LD H, L
proc ld_65(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.ld(Reg8.H, byte)
    return 1

# LD H, (HL)
proc ld_66(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.reg_write(Reg8.H, val)
    return 2

# LD H, A
proc ld_67(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.ld(Reg8.H, byte)
    return 1

# LD L, B
proc ld_68(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.ld(Reg8.L, byte)
    return 1

# LD L, C
proc ld_69(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.ld(Reg8.L, byte)
    return 1

# LD L, D
proc ld_6a(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.ld(Reg8.L, byte)
    return 1

# LD L, E
proc ld_6b(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.ld(Reg8.L, byte)
    return 1

# LD L, H
proc ld_6c(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.ld(Reg8.L, byte)
    return 1

# LD L, L
proc ld_6d(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.ld(Reg8.L, byte)
    return 1

# LD L, (HL)
proc ld_6e(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.reg_write(Reg8.L, val)
    return 2

# LD L, A
proc ld_6f(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.ld(Reg8.E, byte)
    return 1

# LD (HL), B
proc ld_70(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    let hl = z80.reg(Reg16.HL)
    z80.ram_write(hl, val)
    return 2

# LD (HL), C
proc ld_71(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    let hl = z80.reg(Reg16.HL)
    z80.ram_write(hl, val)
    return 2

# LD (HL), D
proc ld_72(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    let hl = z80.reg(Reg16.HL)
    z80.ram_write(hl, val)
    return 2

# LD (HL), E
proc ld_73(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    let hl = z80.reg(Reg16.HL)
    z80.ram_write(hl, val)
    return 2

# LD (HL), H
proc ld_74(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    let hl = z80.reg(Reg16.HL)
    z80.ram_write(hl, val)
    return 2

# LD (HL), L
proc ld_75(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    let hl = z80.reg(Reg16.HL)
    z80.ram_write(hl, val)
    return 2

# HALT
proc halt_76(z80: var Z80): uint8 =
    z80.halted = true
    return 1

# LD (HL), A
proc ld_77(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    let hl = z80.reg(Reg16.HL)
    z80.ram_write(hl, val)
    return 2

# LD A, B
proc ld_78(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.ld(Reg8.A, byte)
    return 1

# LD A, C
proc ld_79(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.ld(Reg8.A, byte)
    return 1

# LD A, D
proc ld_7a(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.ld(Reg8.A, byte)
    return 1

# LD A, E
proc ld_7b(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.ld(Reg8.A, byte)
    return 1

# LD A, H
proc ld_7c(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.ld(Reg8.A, byte)
    return 1

# LD A, L
proc ld_7d(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.ld(Reg8.A, byte)
    return 1

# LD A, (HL)
proc ld_7e(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.reg_write(Reg8.A, val)
    return 2

# LD A, A
proc ld_7f(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.ld(Reg8.A, byte)
    return 1

# ADD A, B
proc add_80(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.add_a(val, false)
    return 1

# ADD A, C
proc add_81(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.add_a(val, false)
    return 1

# ADD A, D
proc add_82(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.add_a(val, false)
    return 1

# ADD A, E
proc add_83(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.add_a(val, false)
    return 1

# ADD A, H
proc add_84(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.add_a(val, false)
    return 1

# ADD A, L
proc add_85(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.add_a(val, false)
    return 1

# ADD A, (HL)
proc add_86(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.add_a(val, false)
    return 2

# ADD A, A
proc add_87(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.add_a(val, true)
    return 1

# ADC A, B
proc adc_88(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.add_a(val, true)
    return 1

# ADC A, C
proc adc_89(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.add_a(val, true)
    return 1

# ADC A, D
proc adc_8a(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.add_a(val, true)
    return 1

# ADC A, E
proc adc_8b(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.add_a(val, true)
    return 1

# ADC A, H
proc adc_8c(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.add_a(val, true)
    return 1

# ADC A, L
proc adc_8d(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.add_a(val, true)
    return 1

# ADC A, (HL)
proc adc_8e(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.add_a(val, true)
    return 2

# ADC A, A
proc adc_8f(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.add_a(val, true)
    return 1

# SUB B
proc sub_90(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.sub_a(val, false)
    return 1

# SUB C
proc sub_91(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.sub_a(val, false)
    return 1

# SUB D
proc sub_92(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.sub_a(val, false)
    return 1

# SUB E
proc sub_93(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.sub_a(val, false)
    return 1

# SUB H
proc sub_94(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.sub_a(val, false)
    return 1

# SUB L
proc sub_95(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.sub_a(val, false)
    return 1

# SUB (HL)
proc sub_96(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.sub_a(val, false)
    return 2

# SUB A
proc sub_97(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.sub_a(val, false)
    return 1

# SBC B
proc sbc_98(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.sub_a(val, true)
    return 1

# SBC C
proc sbc_99(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.sub_a(val, true)
    return 1

# SBC D
proc sbc_9a(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.sub_a(val, true)
    return 1

# SBC E
proc sbc_9b(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.sub_a(val, true)
    return 1

# SBC H
proc sbc_9c(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.sub_a(val, true)
    return 1

# SBC L
proc sbc_9d(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.sub_a(val, true)
    return 1

# SBC (HL)
proc sbc_9e(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.sub_a(val, true)
    return 2

# SBC A
proc sbc_9f(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.sub_a(val, true)
    return 1

# AND B
proc and_a0(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.and_a(val)
    return 1

# AND C
proc and_a1(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.and_a(val)
    return 1

# AND D
proc and_a2(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.and_a(val)
    return 1

# AND E
proc and_a3(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.and_a(val)
    return 1

# AND H
proc and_a4(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.and_a(val)
    return 1

# AND L
proc and_a5(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.and_a(val)
    return 1

# AND (HL)
proc and_a6(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.and_a(val)
    return 2

# AND A
proc and_a7(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.and_a(val)
    return 1

# XOR B
proc xor_a8(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.xor_a(val)
    return 1

# XOR C
proc xor_a9(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.xor_a(val)
    return 1

# XOR D
proc xor_aa(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.xor_a(val)
    return 1

# XOR E
proc xor_ab(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.xor_a(val)
    return 1

# XOR H
proc xor_ac(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.xor_a(val)
    return 1

# XOR L
proc xor_ad(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.xor_a(val)
    return 1

# XOR (HL)
proc xor_ae(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.xor_a(val)
    return 2

# XOR A
proc xor_af(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.xor_a(val)
    return 1

# OR B
proc or_b0(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.or_a(val)
    return 1

# OR C
proc or_b1(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.or_a(val)
    return 1

# OR D
proc or_b2(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.or_a(val)
    return 1

# OR E
proc or_b3(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.or_a(val)
    return 1

# OR H
proc or_b4(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.or_a(val)
    return 1

# OR L
proc or_b5(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.or_a(val)
    return 1

# OR (HL)
proc or_b6(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.or_a(val)
    return 2

# OR A
proc or_b7(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.or_a(val)
    return 1

# CP B
proc cp_b8(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.cp_a(val)
    return 1

# CP C
proc cp_b9(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.cp_a(val)
    return 1

# CP D
proc cp_ba(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.cp_a(val)
    return 1

# CP E
proc cp_bb(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.cp_a(val)
    return 1

# CP H
proc cp_bc(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.cp_a(val)
    return 1

# CP L
proc cp_bd(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.cp_a(val)
    return 1

# CP (HL)
proc cp_be(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.cp_a(val)
    return 2

# CP A
proc cp_bf(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.cp_a(val)
    return 1

# RET NZ
proc ret_c0(z80: var Z80): uint8 =
    if not z80.flag(Flag.Z):
        let address = z80.pop()
        z80.pc = address
        return 5
    else:
        return 2

# POP BC
proc pop_c1(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.reg_write(Reg16.BC, val)
    return 3

# JP NZ, a16
proc jp_c2(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let offset = merge_bytes(high, low)
    if not z80.flag(Flag.Z):
        z80.pc = offset
        return 4
    else:
        return 3

# JP a16
proc jp_c3(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let offset = merge_bytes(high, low)
    z80.pc = offset
    return 4

# CALL NZ, a16
proc call_c4(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    if not z80.flag(Flag.Z):
        let address = merge_bytes(high, low)
        z80.push(z80.pc)
        z80.pc = address
        return 6
    else:
        return 3

# PUSH BC
proc push_c5(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    z80.push(bc)
    return 4

# ADD A, d8
proc add_c6(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.add_a(val, false)
    return 2

# RST 00
proc rst_c7(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0000
    return 4

# RET Z
proc ret_c8(z80: var Z80): uint8 =
    if z80.flag(Flag.Z):
        let address = z80.pop()
        z80.pc = address
        return 5
    else:
        return 2

# RET
proc ret_c9(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.pc = val
    return 4

# JP Z, a16
proc jp_ca(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let offset = merge_bytes(high, low)
    if z80.flag(Flag.Z):
        z80.pc = offset
        return 4
    else:
        return 3

# PREFIX CB
proc prefix_cb(z80: var Z80): uint8 =
    assert(false, "Should be using CB table")

# CALL Z, a16
proc call_cc(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    if z80.flag(Flag.Z):
        let address = merge_bytes(high, low)
        z80.push(z80.pc)
        z80.pc = address
        return 6
    else:
        return 3

# CALL a16
proc call_cd(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let address = merge_bytes(high, low)
    z80.push(z80.pc)
    z80.pc = address
    return 6

# ADC A, d8
proc adc_ce(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.add_a(val, true)
    return 2

# RST 08
proc rst_cf(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0008
    return 4

# RET NC
proc ret_d0(z80: var Z80): uint8 =
    if not z80.flag(Flag.C):
        let val = z80.pop()
        z80.pc = val
        return 5
    else:
        return 2

# POP DE
proc pop_d1(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.reg_write(Reg16.DE, val)
    return 3

# JP NC, a16
proc jp_d2(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let offset = merge_bytes(high, low)
    if not z80.flag(Flag.C):
        z80.pc = offset
        return 4
    else:
        return 3

# CALL NC, a16
proc call_d4(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    if not z80.flag(Flag.C):
        let address = merge_bytes(high, low)
        z80.push(z80.pc)
        z80.pc = address
        return 6
    else:
        return 3

# PUSH DE
proc push_d5(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    z80.push(de)
    return 4

# SUB d8
proc sub_d6(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.sub_a(val, false)
    return 2

# RST 10
proc rst_d7(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0010
    return 4

# RET C
proc ret_d8(z80: var Z80): uint8 =
    if z80.flag(Flag.C):
        let val = z80.pop()
        z80.pc = val
        return 5
    else:
        return 2

# RETI
proc reti_d9(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.pc = val
    z80.irq_enabled = true
    return 4

# JP C, a16
proc jp_da(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let offset = merge_bytes(high, low)
    if z80.flag(Flag.C):
        z80.pc = offset
        return 4
    else:
        return 3

# CALL C, a16
proc call_dc(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    if z80.flag(Flag.C):
        let address = merge_bytes(high, low)
        z80.push(z80.pc)
        z80.pc = address
        return 6
    else:
        return 3

# SBC A, d8
proc sbc_de(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.sub_a(val, true)
    return 2

# RST 18
proc rst_df(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0018
    return 4

# LDH (a8), A
proc ldh_e0(z80: var Z80): uint8 =
    let offset = z80.fetch()
    let val = z80.reg(Reg8.A)
    z80.ram_write(0xFF + offset, val)
    return 3

# POP HL
proc pop_e1(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.reg_write(Reg16.HL, val)
    return 3

# LD (C), A
proc ld_e2(z80: var Z80): uint8 =
    let c = z80.reg(Reg8.C)
    let val = z80.reg(Reg8.A)
    z80.ram_write(0xFF00u16 + c, val)
    return 2

# PUSH HL
proc push_e5(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    z80.push(hl)
    return 4

# AND d8
proc and_e6(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.and_a(val)
    return 2

# RST 20
proc rst_e7(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0020
    return 4

# ADD SP, r8
proc add_e8(z80: var Z80): uint8 =
    let val = z80.fetch()
    let signed = uint16(cast[int8](val))
    let sp = z80.sp
    z80.sp = sp + signed

    let set_c = will_overflow(sp.lo(), signed.lo())
    let set_h = check_h_carry(sp.lo(), signed.lo())
    z80.flag_clear(Flag.Z)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.C, set_c)
    z80.flag_write(Flag.H, set_h)
    return 4

# JP HL
proc jp_e9(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    z80.pc = hl
    return 1

# LD (a16), A
proc ld_ea(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let address = merge_bytes(high, low)
    let a = z80.reg(Reg8.A)
    z80.ram_write(address, a)
    return 4

# XOR d8
proc xor_ee(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.xor_a(val)
    return 2

# RST 28
proc rst_ef(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0028
    return 4

# LDH A, (a8)
proc ldh_f0(z80: var Z80): uint8 =
    let offset = z80.fetch()
    let val = z80.ram_read(0xFF00u16 + offset)
    z80.reg_write(Reg8.A, val)
    return 3

# POP AF
proc pop_f1(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.reg_write(Reg16.AF, val)
    return 3

# LD A, (C)
proc ld_f2(z80: var Z80): uint8 =
    let c = z80.reg(Reg8.C)
    let val = z80.ram_read(0xFF00u16 + c)
    z80.reg_write(Reg8.A, val)
    return 2

# DI
proc di_f3(z80: var Z80): uint8 =
    z80.irq_enabled = false
    return 1

# PUSH AF
proc push_f5(z80: var Z80): uint8 =
    let af = z80.reg(Reg16.AF)
    z80.push(af)
    return 4

# OR d8
proc or_f6(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.or_a(val)
    return 2

# RST 30
proc rst_f7(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0030
    return 4

# LD HL, SP+r8
proc ld_f8(z80: var Z80): uint8 =
    let val = z80.fetch()
    let signed = uint16(cast[int8](val))
    let sp = z80.sp
    z80.reg_write(Reg16.HL, sp + signed)

    let set_c = will_overflow(sp.lo(), signed.lo())
    let set_h = check_h_carry(sp.lo(), signed.lo())
    z80.flag_clear(Flag.Z)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.C, set_c)
    z80.flag_write(Flag.H, set_h)
    return 3

# LD SP, HL
proc ld_f9(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    z80.sp = hl
    return 2

# LD A, (a16)
proc ld_fa(z80: var Z80): uint8 =
    let low = z80.fetch()
    let high = z80.fetch()
    let address = merge_bytes(high, low)
    let val = z80.ram_read(address)
    z80.reg_write(Reg8.A, val)
    return 4

# EI
proc ei_fb(z80: var Z80): uint8 =
    z80.irq_enabled = true
    return 1

# CP d8
proc cp_fe(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.cp_a(val)
    return 2

# RST 38
proc rst_ff(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0038
    return 4

proc invalid(z80: var Z80): uint8 =
    assert(false, "Invalid opcode")

const OPCODES = [
#   $00,     $01,     $02,    $03,     $04,     $05,     $06,     $07,     $08,     $09,     $0A,    $0B,       $0C,     $0D,     $0E,     $0F
    nop_00,  ld_01,   ld_02,  inc_03,  inc_04,  dec_05,  ld_06,   rlca_07, ld_08,   add_09,  ld_0a,  dec_0b,    inc_0c,  dec_0d,  ld_0e,   rrca_0f, # $00
    stop_10, ld_11,   ld_12,  inc_13,  inc_14,  dec_15,  ld_16,   rla_17,  jr_18,   add_19,  ld_1a,  dec_1b,    inc_1c,  dec_1d,  ld_1e,   rra_1f,  # $10
    jr_20,   ld_21,   ld_22,  inc_23,  inc_24,  dec_25,  ld_26,   daa_27,  jr_28,   add_29,  ld_2a,  dec_2b,    inc_2c,  dec_2d,  ld_2e,   cpl_2f,  # $20
    jr_30,   ld_31,   ld_32,  inc_33,  inc_34,  dec_35,  ld_36,   scf_37,  jr_38,   add_39,  ld_3a,  dec_3b,    inc_3c,  dec_3d,  ld_3e,   ccf_3f,  # $30
    ld_40,   ld_41,   ld_42,  ld_43,   ld_44,   ld_45,   ld_46,   ld_47,   ld_48,   ld_49,   ld_4a,  ld_4b,     ld_4c,   ld_4d,   ld_4e,   ld_4f,   # $40
    ld_50,   ld_51,   ld_52,  ld_53,   ld_54,   ld_55,   ld_56,   ld_57,   ld_58,   ld_59,   ld_5a,  ld_5b,     ld_5c,   ld_5d,   ld_5e,   ld_5f,   # $50
    ld_60,   ld_61,   ld_62,  ld_63,   ld_64,   ld_65,   ld_66,   ld_67,   ld_68,   ld_69,   ld_6a,  ld_6b,     ld_6c,   ld_6d,   ld_6e,   ld_6f,   # $60
    ld_70,   ld_71,   ld_72,  ld_73,   ld_74,   ld_75,   halt_76, ld_77,   ld_78,   ld_79,   ld_7a,  ld_7b,     ld_7c,   ld_7d,   ld_7e,   ld_7f,   # $70
    add_80,  add_81,  add_82, add_83,  add_84,  add_85,  add_86,  add_87,  adc_88,  adc_89,  adc_8a, adc_8b,    adc_8c,  adc_8d,  adc_8e,  adc_8f,  # $80
    sub_90,  sub_91,  sub_92, sub_93,  sub_94,  sub_95,  sub_96,  sub_97,  sbc_98,  sbc_99,  sbc_9a, sbc_9b,    sbc_9c,  sbc_9d,  sbc_9e,  sbc_9f,  # $90
    and_a0,  and_a1,  and_a2, and_a3,  and_a4,  and_a5,  and_a6,  and_a7,  xor_a8,  xor_a9,  xor_aa, xor_ab,    xor_ac,  xor_ad,  xor_ae,  xor_af,  # $A0
    or_b0,   or_b1,   or_b2,  or_b3,   or_b4,   or_b5,   or_b6,   or_b7,   cp_b8,   cp_b9,   cp_ba,  cp_bb,     cp_bc,   cp_bd,   cp_be,   cp_bf,   # $B0
    ret_c0,  pop_c1,  jp_c2,  jp_c3,   call_c4, push_c5, add_c6,  rst_c7,  ret_c8,  ret_c9,  jp_ca,  prefix_cb, call_cc, call_cd, adc_ce,  rst_cf,  # $C0
    ret_d0,  pop_d1,  jp_d2,  invalid, call_d4, push_d5, sub_d6,  rst_d7,  ret_d8,  reti_d9, jp_da,  invalid,   call_dc, invalid, sbc_de,  rst_df,  # $D0
    ldh_e0,  pop_e1,  ld_e2,  invalid, invalid, push_e5, and_e6,  rst_e7,  add_e8,  jp_e9,   ld_ea,  invalid,   invalid, invalid, xor_ee,  rst_ef,  # $E0
    ldh_f0,  pop_f1,  ld_f2,  di_f3,   invalid, push_f5, or_f6,   rst_f7,  ld_f8,   ld_f9,   ld_fa,  ei_fb,     invalid, invalid, cp_fe,   rst_ff,  # $F0
]

proc decode_cb_reg(op: uint8): Reg8 =
    case (op and 0xF):
        of 0x00, 0x08: return Reg8.B
        of 0x01, 0x09: return Reg8.C
        of 0x02, 0x0A: return Reg8.D
        of 0x03, 0x0B: return Reg8.E
        of 0x04, 0x0C: return Reg8.H
        of 0x05, 0x0D: return Reg8.L
        of 0x07, 0x0F: return Reg8.A
        else: assert(false, "Unreachable")

proc execute_cb_op(z80: var Z80, op: uint8) =
    # $00-$07 -> RLC
    # $08-$0F -> RRC
    # $10-$17 -> RL
    # $18-$1F -> RR
    # $20-$27 -> SLA
    # $28-$2F -> SRA
    # $30-$37 -> SWAP
    # $38-$3F -> SRL
    # $40-$7F -> BIT
    # $80-$BF -> RES
    # $C0-$FF -> SET

    # Operations involving (HL) have different functionality than the
    # other registers, so those need to be handled separately
    case op:
        of 0x00..0x05, 0x07:
            let reg = decode_cb_reg(op)
            z80.rot_left_reg(reg, false)
        of 0x06:
            let hl = z80.reg(Reg16.HL)
            let byte = z80.ram_read(hl)
            let rot = z80.rot_left(byte, false)
            z80.ram_write(hl, rot)
        of 0x08..0x0D, 0x0F:
            let reg = decode_cb_reg(op)
            z80.rot_right_reg(reg, false)
        of 0x0E:
            let hl = z80.reg(Reg16.HL)
            let byte = z80.ram_read(hl)
            let rot = z80.rot_right(byte, false)
            z80.ram_write(hl, rot)
        of 0x10..0x15, 0x17:
            let reg = decode_cb_reg(op)
            z80.rot_left_reg(reg, true)
        of 0x16:
            let hl = z80.reg(Reg16.HL)
            let byte = z80.ram_read(hl)
            let rot = z80.rot_left(byte, true)
            z80.ram_write(hl, rot)
        of 0x18..0x1D, 0x1F:
            let reg = decode_cb_reg(op)
            z80.rot_right_reg(reg, true)
        of 0x1E:
            let hl = z80.reg(Reg16.HL)
            let byte = z80.ram_read(hl)
            let rot = z80.rot_right(byte, true)
            z80.ram_write(hl, rot)
        of 0x20..0x25, 0x27:
            let reg = decode_cb_reg(op)
            z80.shift_left_reg(reg)
        of 0x26:
            let address = z80.reg(Reg16.HL)
            let byte = z80.ram_read(address)
            let shifted = z80.shift_left(byte)
            z80.ram_write(address, shifted)
        of 0x28..0x2D, 0x2F:
            let reg = decode_cb_reg(op)
            z80.shift_right_reg(reg, true)
        of 0x2E:
            let hl = z80.reg(Reg16.HL)
            let val = z80.ram_read(hl)
            let shifted = z80.shift_right(val, true)
            z80.ram_write(hl, shifted)
        of 0x30..0x35, 0x37:
            let reg = decode_cb_reg(op)
            z80.swap_bits_reg(reg)
        of 0x36:
            let hl = z80.reg(Reg16.HL)
            let val = z80.ram_read(hl)
            let swapped = z80.swap_bits(val)
            z80.ram_write(hl, swapped)
        of 0x38..0x3D, 0x3F:
            let reg = decode_cb_reg(op)
            z80.shift_right_reg(reg, false)
        of 0x3E:
            let hl = z80.reg(Reg16.HL)
            let val = z80.ram_read(hl)
            let shifted = z80.shift_right(val, false)
            z80.ram_write(hl, shifted)
        of 0x40..0x7F:
            let rel_offset = op - 0x40
            let digit = rel_offset div 0x08

            case op and 0x0F:
                of 0x06, 0x0E:
                    let hl = z80.reg(Reg16.HL)
                    let val = z80.ram_read(hl)
                    z80.check_bit(val, digit)
                else:
                    let reg = decode_cb_reg(op)
                    z80.check_bit_reg(reg, digit)
        of 0x80..0xBF:
            let rel_offset = op - 0x80
            let digit = rel_offset div 0x08

            case op and 0x0F:
                of 0x06, 0x0E:
                    let hl = z80.reg(Reg16.HL)
                    z80.write_bit_ram(hl, digit, false)
                else:
                    let reg = decode_cb_reg(op)
                    z80.write_bit_n(reg, digit, false)
        of 0xC0..0xFF:
            let rel_offset = op - 0xC0
            let digit = rel_offset div 0x08

            case op and 0x0F:
                of 0x06, 0x0E:
                    let hl = z80.reg(Reg16.HL)
                    z80.write_bit_ram(hl, digit, true)
                else:
                    let reg = decode_cb_reg(op)
                    z80.write_bit_n(reg, digit, true)

proc execute*(z80: var Z80): uint8 =
    let opcode = z80.fetch()
    if opcode == 0xCB:
        let cb_op = z80.fetch()
        z80.execute_cb_op(cb_op)
        return 2
    else:
        let op_fn = OPCODES[opcode]
        return z80.op_fn()
