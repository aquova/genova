import bitops
import strformat # TODO: For testing

import flags
import registers
import z80

import ../errors
import ../utils

# Forward declaration
proc execute_cb_op(z80: var Z80): uint8
proc execute_dd_op(z80: var Z80): uint8
proc execute_ed_op(z80: var Z80): uint8

# Info on z80 flag behavior: https://www.smspower.org/Development/Flags
proc check_s(value: uint8): bool =
    return value.testBit(7)

proc check_s(value: uint16): bool =
    return value.testBit(15)

proc check_h_add(a, b: uint8): bool =
    return (((a and 0xF) + (b and 0xF)) and 0x10) == 0x10

proc check_h_add(a, b: uint16): bool =
    return (((a and 0xFFF) + (b and 0xFFF)) and 0x1000) == 0x1000

proc check_h_sub(a, b: uint8): bool =
    return (int(a and 0xF) - int(b and 0xF)) < 0

proc check_h_sub(a, b: uint16): bool =
    return (int(a and 0xFFF) - int(b and 0xFFF)) < 0

proc check_p[T: SomeInteger](value: T): bool =
    return (value.countSetBits() mod 2) == 1

proc check_v_add(a, b: uint8): bool =
    let sa = cast[int8](a)
    let sb = cast[int8](b)
    let sum = int16(sa) + int16(sb)
    return sum < -128 or sum > 127

proc check_v_sub(a, b: uint8): bool =
    let sa = cast[int8](a)
    let sb = cast[int8](b)
    let diff = int16(sa) - int16(sb)
    return diff < -128 or diff > 127

proc check_v_add(a, b: uint16): bool =
    let sa = cast[int16](a)
    let sb = cast[int16](b)
    let diff = int(sa) + int(sb)
    return diff < -32768 or diff > 32767

proc check_v_sub(a, b: uint16): bool =
    let sa = cast[int16](a)
    let sb = cast[int16](b)
    let diff = int(sa) - int(sb)
    return diff < -32768 or diff > 32767

proc check_c_add[T: SomeUnsignedInt](a, b: T): bool =
    let sum = int(a) + int(b)
    return sum > int(high(T))

proc check_c_sub[T: SomeUnsignedInt](a, b: T): bool =
    let diff = int(a) - int(b)
    return diff < int(low(T))

# Info on opcode flags from here: https://clrhome.org/table/

proc adc_hl(z80: var Z80, val: uint16) =
    let carry: uint8 = if z80.flag(Flag.C): 1 else: 0
    let hl = z80.reg(Reg16.HL)

    let result1 = hl + val
    let check_c1 = check_c_add(hl, val)
    let check_h1 = check_h_add(hl, val)
    let check_v1 = check_v_add(hl, val)

    let result2 = result1 - carry
    let check_c2 = check_c_add(result1, carry)
    let check_h2 = check_h_add(result1, carry)
    let check_v2 = check_v_add(result1, carry)

    let set_h = check_h1 or check_h2
    let set_c = check_c1 or check_c2
    let set_v = check_v1 or check_v2

    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.C, set_c)
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.Z, result2 == 0)
    z80.flag_write(Flag.PV, set_v)
    z80.flag_write(Flag.S, check_s(result2))
    z80.reg_write(Reg16.HL, result2)

# C0VHZS
proc add_a(z80: var Z80, val: uint8, adc: bool) =
    var carry: uint8 = 0
    if adc and z80.flag(Flag.C):
        carry = 1
    let a = z80.reg(Reg8.A)

    let result1 = a + val
    let c_check1 = check_c_add(a, val)
    let h_check1 = check_h_add(a, val)
    let v_check1 = check_v_add(a, val)

    let result2 = result1 + carry
    let c_check2 = check_c_add(result1, carry)
    let h_check2 = check_h_add(result1, carry)
    let v_check2 = check_v_add(result1, carry)

    let set_h = h_check1 or h_check2
    let set_c = c_check1 or c_check2
    let set_v = v_check1 or v_check2

    z80.flag_write(Flag.C, set_c)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.PV, set_v)
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.Z, result2 == 0)
    z80.flag_write(Flag.S, check_s(result2))
    z80.reg_write(Reg8.A, result2)

# C0-H--
proc add(z80: var Z80, reg: Reg16, source: uint16) =
    let target = z80.reg(reg)
    let sum = target + source
    let set_c = check_c_add(target, source)
    let set_h = check_h_add(target, source)

    z80.reg_write(reg, sum)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.C, set_c)
    z80.flag_write(Flag.H, set_h)

# 00P1ZS
proc and_a(z80: var Z80, val: uint8) =
    var a = z80.reg(Reg8.A)
    a = a and val

    z80.flag_clear(Flag.C)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.PV, check_p(a))
    z80.flag_set(Flag.H)
    z80.flag_write(Flag.Z, a == 0)
    z80.flag_write(Flag.S, check_s(a))
    z80.reg_write(Reg8.A, a)

# -0-1Z-
proc check_bit(z80: var Z80, val: uint8, digit: uint8) =
    let bit = val.test_bit(digit)

    z80.flag_write(Flag.Z, not bit)
    z80.flag_clear(Flag.N)
    z80.flag_set(Flag.H)

# -0-1Z-
proc check_bit_reg(z80: var Z80, reg: Reg8, digit: uint8) =
    let byte = z80.reg(reg)
    z80.check_bit(byte, digit)

# C1VHZS
proc cp_a(z80: var Z80, val: uint8) =
    let a = z80.reg(Reg8.A)
    let diff = a - val
    let set_h = check_h_add(a, val)

    z80.flag_write(Flag.C, check_c_sub(a, val))
    z80.flag_set(Flag.N)
    z80.flag_write(Flag.PV, check_v_add(a, val))
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.Z, diff == 0)
    z80.flag_write(Flag.S, check_s(diff))

proc cpd(z80: var Z80) =
    let bc = z80.reg(Reg16.BC)
    let hl = z80.reg(Reg16.HL)
    let data = z80.ram_read(hl)
    let a = z80.reg(Reg8.A)

    z80.reg_write(Reg16.BC, bc - 1)
    z80.reg_write(Reg16.HL, hl - 1)

    z80.flag_clear(Flag.N)

proc cpi(z80: var Z80) =
    let bc = z80.reg(Reg16.BC)
    let hl = z80.reg(Reg16.HL)
    let data = z80.ram_read(hl)
    let a = z80.reg(Reg8.A)

    z80.reg_write(Reg16.BC, bc - 1)
    z80.reg_write(Reg16.HL, hl + 1)

    z80.flag_clear(Flag.N)

# ?-P?ZS
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
    z80.flag_write(Flag.PV, check_p(a))
    z80.flag_write(Flag.Z, a == 0)
    z80.reg_write(Reg8.A, uint8(a))

# -NVHZS
proc dec(z80: var Z80, reg: Reg8) =
    let val = z80.reg(reg)
    let sub = val - 1
    let set_h = check_h_sub(val, 1)
    let set_pv = check_v_sub(val, 0xFF)
    let set_s = check_s(sub)
    z80.reg_write(reg, sub)

    z80.flag_set(Flag.N)
    z80.flag_write(Flag.Z, sub == 0)
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.PV, set_pv)
    z80.flag_write(Flag.S, set_s)

# ------
proc dec(z80: var Z80, reg: Reg16) =
    let val = z80.reg(reg)
    let sum = val + 1
    z80.reg_write(reg, sum)

# -0P0ZS
proc in_port(z80: var Z80, reg: Reg8) =
    let port = z80.reg(Reg8.C)
    let data = z80.port_read(port)
    z80.reg_write(reg, data)

    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_write(Flag.PV, check_p(data))
    z80.flag_write(Flag.S, check_s(data))
    z80.flag_write(Flag.Z, data == 0)

# -NVHZS
proc inc(z80: var Z80, reg: Reg8) =
    let val = z80.reg(reg)
    let sum = val + 1
    let set_h = check_h_add(val, 1)
    let set_pv = check_v_add(val, 1)
    let set_s = check_s(sum)
    z80.reg_write(reg, sum)

    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.Z, sum == 0)
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.PV, set_pv)
    z80.flag_write(Flag.S, set_s)

# ------
proc inc(z80: var Z80, reg: Reg16) =
    let val = z80.reg(reg)
    let sum = val + 1
    z80.reg_write(reg, sum)

proc ind(z80: var Z80) =
    let b = z80.reg(Reg8.B)
    let c = z80.reg(Reg8.C)
    let data = z80.port_read(c)
    let hl = z80.reg(Reg16.HL)
    z80.ram_write(hl, data)

    z80.reg_write(Reg16.HL, hl - 1)
    z80.reg_write(Reg8.B, b - 1)
    z80.flag_clear(Flag.N)

proc ini(z80: var Z80) =
    let b = z80.reg(Reg8.B)
    let c = z80.reg(Reg8.C)
    let data = z80.port_read(c)
    let hl = z80.reg(Reg16.HL)
    z80.ram_write(hl, data)

    z80.reg_write(Reg16.HL, hl + 1)
    z80.reg_write(Reg8.B, b - 1)
    z80.flag_clear(Flag.N)

# ------
proc ld_into_ptr(z80: var Z80, src: Reg8, dst: Reg16) =
    let address = case dst:
        of Reg16.IX:
            let ix = z80.reg(dst)
            let offset = cast[int8](z80.fetch())
            ix + uint16(offset)
        else:
            z80.reg(dst)
    let val = z80.reg(src)
    z80.ram_write(address, val)

# ------
proc ld_outof_ptr(z80: var Z80, src: Reg16, dst: Reg8) =
    let address = case src:
        of Reg16.IX:
            let ix = z80.reg(src)
            let offset = cast[int8](z80.fetch())
            ix + uint16(offset)
        else:
            z80.reg(src)
    let val = z80.ram_read(address)
    z80.reg_write(dst, val)

proc ldd(z80: var Z80) =
    let bc = z80.reg(Reg16.BC)
    let de = z80.reg(Reg16.DE)
    let hl = z80.reg(Reg16.HL)
    let data = z80.ram_read(hl)
    z80.ram_write(de, data)

    z80.reg_write(Reg16.BC, bc - 1)
    z80.reg_write(Reg16.DE, de - 1)
    z80.reg_write(Reg16.HL, hl - 1)
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)

proc ldi(z80: var Z80) =
    let bc = z80.reg(Reg16.BC)
    let de = z80.reg(Reg16.DE)
    let hl = z80.reg(Reg16.HL)

    let de_data = z80.ram_read(de)
    let hl_data = z80.ram_read(hl)
    z80.ram_write(hl, de_data)
    z80.ram_write(de, hl_data)

    z80.reg_write(Reg16.DE, de + 1)
    z80.reg_write(Reg16.HL, hl + 1)
    z80.reg_write(Reg16.BC, bc - 1)

    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)

# 00P0ZS
proc or_a(z80: var Z80, val: uint8) =
    var a = z80.reg(Reg8.A)
    a = a or val

    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_clear(Flag.C)
    z80.flag_write(Flag.PV, check_p(a))
    z80.flag_write(Flag.Z, a == 0)
    z80.flag_write(Flag.S, check_s(a))
    z80.reg_write(Reg8.A, a)

# ------
proc out_port(z80: var Z80, reg: Reg8) =
    let data = z80.reg(reg)
    let port = z80.reg(Reg8.C)
    z80.port_write(port, data)

proc outd(z80: var Z80) =
    let b = z80.reg(Reg8.B)
    let c = z80.reg(Reg8.C)
    let hl = z80.reg(Reg16.HL)
    let data = z80.ram_read(hl)
    z80.port_write(c, data)
    z80.reg_write(Reg8.B, b - 1)
    z80.reg_write(Reg16.HL, hl - 1)

proc outi(z80: var Z80) =
    let b = z80.reg(Reg8.B)
    let c = z80.reg(Reg8.C)
    let hl = z80.reg(Reg16.HL)
    let data = z80.ram_read(hl)
    z80.port_write(c, data)
    z80.reg_write(Reg8.B, b - 1)
    z80.reg_write(Reg16.HL, hl + 1)

# ------
proc pop(z80: var Z80): uint16 =
    if z80.sp == 0xDFF0:
        raise newException(InvalidError, &"Trying to pop when stack is empty: {z80.sp:#2x}")
    let lo = z80.ram_read(z80.sp)
    let hi = z80.ram_read(z80.sp + 1)
    result = merge_bytes(hi, lo)
    z80.sp = z80.sp + 2

# ------
proc push(z80: var Z80, val: uint16) =
    let sp = z80.sp - 2
    z80.ram_write(sp + 1, val.hi())
    z80.ram_write(sp, val.lo())
    z80.sp = sp

# C0P0ZS
proc rot_left(z80: var Z80, byte: uint8, carry: bool): uint8 =
    let msb = byte.test_bit(7)
    var rot = byte.rotate_left_bits(1)
    if carry:
        let old_c = z80.flag(Flag.C)
        rot.write_bit(0, old_c)
    z80.flag_write(Flag.C, msb)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.PV, check_p(rot))
    z80.flag_clear(Flag.H)
    z80.flag_write(Flag.Z, rot == 0)
    z80.flag_write(Flag.S, check_s(rot))
    return rot

# C0P0ZS
proc rot_left_reg(z80: var Z80, reg: Reg8, carry: bool) =
    let val = z80.reg(reg)
    let rot = z80.rot_left(val, carry)
    z80.reg_write(reg, rot)

# C0P0ZS
proc rot_right(z80: var Z80, byte: uint8, carry: bool): uint8 =
    let lsb = byte.test_bit(0)
    var rot = byte.rotate_right_bits(1)
    if carry:
        let old_c = z80.flag(Flag.C)
        rot.write_bit(7, old_c)
    z80.flag_write(Flag.C, lsb)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.PV, check_p(rot))
    z80.flag_clear(Flag.H)
    z80.flag_write(Flag.Z, rot == 0)
    z80.flag_write(Flag.S, check_s(rot))
    return rot

# C0P0ZS
proc rot_right_reg(z80: var Z80, reg: Reg8, carry: bool) =
    let val = z80.reg(reg)
    let rot = z80.rot_right(val, carry)
    z80.reg_write(reg, rot)

# C0P0ZS
proc shift_left(z80: var Z80, byte: uint8): uint8 =
    let msb = byte.test_bit(7)
    let shifted = byte shl 1

    z80.flag_write(Flag.S, check_s(shifted))
    z80.flag_write(Flag.Z, shifted == 0)
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_write(Flag.PV, check_p(shifted))
    z80.flag_write(Flag.C, msb)
    return shifted

# C0P0ZS
proc shift_left_reg(z80: var Z80, reg: Reg8) =
    let byte = z80.reg(reg)
    let shifted = z80.shift_left(byte)
    z80.reg_write(reg, shifted)

# C0P0ZS
proc shift_right(z80: var Z80, byte: uint8, arith: bool): uint8 =
    let lsb = byte.test_bit(0)
    let msb = byte.test_bit(7)
    var shifted = byte shr 1
    if arith:
        shifted.write_bit(7, msb)

    z80.flag_write(Flag.PV, check_p(shifted))
    z80.flag_write(Flag.Z, shifted == 0)
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_write(Flag.S, check_s(shifted))
    z80.flag_write(Flag.C, lsb)

    return shifted

# C0P0ZS
proc shift_right_reg(z80: var Z80, reg: Reg8, arith: bool) =
    let byte = z80.reg(reg)
    let shifted = z80.shift_right(byte, arith)
    z80.reg_write(reg, shifted)

# C0VHZS
proc sbc_hl(z80: var Z80, val: uint16) =
    let carry: uint8 = if z80.flag(Flag.C): 1 else: 0
    let hl = z80.reg(Reg16.HL)

    let result1 = hl - val
    let check_c1 = check_c_sub(hl, val)
    let check_h1 = check_h_sub(hl, val)
    let check_v1 = check_v_sub(hl, val)

    let result2 = result1 - carry
    let check_c2 = check_c_sub(result1, carry)
    let check_h2 = check_h_sub(result1, carry)
    let check_v2 = check_v_sub(result1, carry)

    let set_h = check_h1 or check_h2
    let set_c = check_c1 or check_c2
    let set_v = check_v1 or check_v2

    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.C, set_c)
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.Z, result2 == 0)
    z80.flag_write(Flag.PV, set_v)
    z80.flag_write(Flag.S, check_s(result2))
    z80.reg_write(Reg16.HL, result2)

# CNVHZS
proc sub_a(z80: var Z80, val: uint8, sbc: bool) =
    let carry: uint8 = if sbc and z80.flag(Flag.C): 1 else: 0
    let a = z80.reg(Reg8.A)

    let result1 = a - val
    let check_c1 = check_c_sub(a, val)
    let check_h1 = check_h_add(a, val)
    let check_v1 = check_v_sub(a, val)

    let result2 = result1 - carry
    let check_c2 = check_c_sub(result1, carry)
    let check_h2 = check_h_add(result1, carry)
    let check_v2 = check_v_sub(result1, carry)

    let set_h = check_h1 or check_h2
    let set_c = check_c1 or check_c2
    let set_v = check_v1 or check_v2

    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.C, set_c)
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.Z, result2 == 0)
    z80.flag_write(Flag.PV, set_v)
    z80.flag_write(Flag.S, check_s(result2))
    z80.reg_write(Reg8.A, result2)

# -0-1Z-
proc swap_bits(z80: var Z80, val: uint8): uint8 =
    let new_high = val and 0xF
    let new_low = (val and 0xF0) shr 4
    let new_val = (new_high shl 4) or new_low

    z80.flag_write(Flag.Z, new_val == 0)
    z80.flag_clear(Flag.N)
    z80.flag_set(Flag.H)

    return new_val

# -0-1Z-
proc swap_bits_reg(z80: var Z80, reg: Reg8) =
    let byte = z80.reg(reg)
    let swapped = z80.swap_bits(byte)
    z80.reg_write(reg, swapped)

# ------
proc write_bit_n(z80: var Z80, reg: Reg8, digit: uint8, set: bool) =
    var r = z80.reg(reg)
    r.writeBit(digit, set)
    z80.reg_write(reg, r)

# ------
proc write_bit_ram(z80: var Z80, address: uint16, digit: uint8, set: bool) =
    var val = z80.ram_read(address)
    val.writeBit(digit, set)
    z80.ram_write(address, val)

# 00P0ZS
proc xor_a(z80: var Z80, val: uint8) =
    var a = z80.reg(Reg8.A)
    a = a xor val
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    z80.flag_clear(Flag.C)
    z80.flag_write(Flag.Z, a == 0)
    z80.flag_write(Flag.S, check_s(a))
    z80.flag_write(Flag.PV, check_p(a))
    z80.reg_write(Reg8.A, a)

# NOP
proc nop_00(z80: var Z80): uint8 = 4

# LD BC, nn
proc ld_01(z80: var Z80): uint8 =
    let val = z80.fetch16()
    z80.reg_write(Reg16.BC, val)
    return 10

# LD (BC), A
proc ld_02(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    let val = z80.reg(Reg8.A)
    z80.ram_write(bc, val)
    return 7

# INC BC
proc inc_03(z80: var Z80): uint8 =
    z80.inc(Reg16.BC)
    return 6

# INC B
proc inc_04(z80: var Z80): uint8 =
    z80.inc(Reg8.B)
    return 4

# DEC B
proc dec_05(z80: var Z80): uint8 =
    z80.dec(Reg8.B)
    return 4

# LD B, n
proc ld_06(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.reg_write(Reg8.B, byte)
    return 7

# RLCA
proc rlca_07(z80: var Z80): uint8 =
    z80.rot_left_reg(Reg8.A, false)
    # RLCA wants Z to be cleared (unlike other shift ops)
    z80.flag_clear(Flag.Z)
    return 4

# EX AF, AF'
proc ex_08(z80: var Z80): uint8 =
    z80.exchange(Reg16.AF)
    return 4

# ADD HL, BC
proc add_09(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    z80.add(Reg16.HL, bc)
    return 11

# LD A, (BC)
proc ld_0a(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    let val = z80.ram_read(bc)
    z80.reg_write(Reg8.A, val)
    return 7

# DEC BC
proc dec_0b(z80: var Z80): uint8 =
    z80.dec(Reg16.BC)
    return 6

# INC C
proc inc_0c(z80: var Z80): uint8 =
    z80.inc(Reg8.C)
    return 4

# DEC C
proc dec_0d(z80: var Z80): uint8 =
    z80.dec(Reg8.C)
    return 4

# LD C, n
proc ld_0e(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.reg_write(Reg8.C, byte)
    return 7

# RRCA
proc rrca_0f(z80: var Z80): uint8 =
    z80.rot_right_reg(Reg8.A, false)
    # RRCA wants Z to be cleared (unlike other shift ops)
    z80.flag_clear(Flag.Z)
    return 4

# DJNZ d
proc djnz_10(z80: var Z80): uint8 =
    let byte = z80.fetch()
    let offset = cast[int8](byte)
    var b = z80.reg(Reg8.B)
    dec(b)
    z80.reg_write(Reg8.B, b)
    if b != 0:
        z80.pc = z80.pc + uint16(offset)
        return 13
    else:
        return 8

# LD DE, nn
proc ld_11(z80: var Z80): uint8 =
    let val = z80.fetch16()
    z80.reg_write(Reg16.DE, val)
    return 10

# LD (DE), A
proc ld_12(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    let val = z80.reg(Reg8.A)
    z80.ram_write(de, val)
    return 7

# INC DE
proc inc_13(z80: var Z80): uint8 =
    z80.inc(Reg16.DE)
    return 6

# INC D
proc inc_14(z80: var Z80): uint8 =
    z80.inc(Reg8.D)
    return 4

# DEC D
proc dec_15(z80: var Z80): uint8 =
    z80.dec(Reg8.D)
    return 4

# LD D, n
proc ld_16(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.reg_write(Reg8.D, byte)
    return 7

# RLA
proc rla_17(z80: var Z80): uint8 =
    z80.rot_left_reg(Reg8.A, true)
    # RLA wants Z to be cleared (unlike other shift ops)
    z80.flag_clear(Flag.Z)
    return 4

# JR d
proc jr_18(z80: var Z80): uint8 =
    let offset = z80.fetch()
    var pc = z80.pc
    pc = pc + offset
    z80.pc = pc
    return 12

# ADD HL, DE
proc add_19(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    z80.add(Reg16.HL, de)
    return 11

# LD A, (DE)
proc ld_1a(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    let val = z80.ram_read(de)
    z80.reg_write(Reg8.A, val)
    return 7

# DEC DE
proc dec_1b(z80: var Z80): uint8 =
    z80.dec(Reg16.DE)
    return 6

# INC E
proc inc_1c(z80: var Z80): uint8 =
    z80.inc(Reg8.E)
    return 4

# DEC E
proc dec_1d(z80: var Z80): uint8 =
    z80.dec(Reg8.E)
    return 4

# LD E, n
proc ld_1e(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.reg_write(Reg8.E, byte)
    return 7

# RRA
proc rra_1f(z80: var Z80): uint8 =
    z80.rot_right_reg(Reg8.A, true)
    # RRA wants Z to be cleared (unlike other shift ops)
    z80.flag_clear(Flag.Z)
    return 4

# JR NZ, d
proc jr20(z80: var Z80): uint8 =
    let offset = z80.fetch()
    let signed = cast[int8](offset)
    if not z80.flag(Flag.Z):
        var pc = z80.pc()
        pc += uint16(signed)
        z80.pc = pc
        return 12
    else:
        return 7

# LD HL, nn
proc ld_21(z80: var Z80): uint8 =
    let val = z80.fetch16()
    z80.reg_write(Reg16.HL, val)
    return 10

# LD (nn), HL
proc ld_22(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let hl = z80.reg(Reg16.HL)
    let data = z80.ram_read(hl)
    z80.ram_write(address, data)
    return 16

# INC HL
proc inc_23(z80: var Z80): uint8 =
    z80.inc(Reg16.HL)
    return 6

# INC H
proc inc_24(z80: var Z80): uint8 =
    z80.inc(Reg8.H)
    return 4

# DEC H
proc dec_25(z80: var Z80): uint8 =
    z80.dec(Reg8.H)
    return 4

# LD H, n
proc ld_26(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.reg_write(Reg8.H, byte)
    return 7

# DAA
proc daa_27(z80: var Z80): uint8 =
    z80.daa()
    return 4

# JR Z, d
proc jr_28(z80: var Z80): uint8 =
    let offset = z80.fetch()
    let signed = cast[int8](offset)
    if z80.flag(Flag.Z):
        var pc = z80.pc()
        pc += uint16(signed)
        z80.pc = pc
        return 12
    else:
        return 7

# ADD HL, HL
proc add_29(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    z80.add(Reg16.HL, hl)
    return 11

# LD HL, (nn)
proc ld_2a(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let data = z80.ram_read(address)
    z80.reg_write(Reg16.HL, data)
    return 16

# DEC HL
proc dec_2b(z80: var Z80): uint8 =
    z80.dec(Reg16.HL)
    return 6

# INC L
proc inc_2c(z80: var Z80): uint8 =
    z80.inc(Reg8.L)
    return 4

# DEC L
proc dec_2d(z80: var Z80): uint8 =
    z80.dec(Reg8.L)
    return 4

# LD L, n
proc ld_2e(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.reg_write(Reg8.L, byte)
    return 7

# CPL
proc cpl_2f(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.reg_write(Reg8.A, not val)
    z80.flag_set(Flag.N)
    z80.flag_set(Flag.H)
    return 4

# JR NC, d
proc jr_30(z80: var Z80): uint8 =
    let offset = z80.fetch()
    let signed = cast[int8](offset)
    if not z80.flag(Flag.C):
        var pc = z80.pc()
        pc += uint16(signed)
        z80.pc = pc
        return 12
    else:
        return 7

# LD SP, nn
proc ld_31(z80: var Z80): uint8 =
    z80.sp = z80.fetch16()
    return 10

# LD (nn), A
proc ld_32(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let a = z80.reg(Reg8.A)
    z80.ram_write(address, a)
    return 16

# INC SP
proc inc_33(z80: var Z80): uint8 =
    let sp = z80.sp()
    z80.sp = (sp - 1)
    return 6

# INC (HL)
proc inc_34(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    let new_val = val + 1
    z80.ram_write(hl, new_val)

    let set_h = check_h_add(val, 1)
    z80.flag_write(Flag.Z, new_val == 0)
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.H, set_h)
    z80.flag_write(Flag.S, check_s(new_val))
    return 11

# DEC (HL)
proc dec_35(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    let new_val = val + 1
    z80.ram_write(hl, new_val)

    let set_h = check_h_add(val, 1)
    z80.flag_write(Flag.Z, new_val == 0)
    z80.flag_set(Flag.N)
    z80.flag_write(Flag.H, set_h)
    return 11

# LD (HL), n
proc ld_36(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.fetch()
    z80.ram_write(hl, val)
    return 10

# SCF
proc scf_37(z80: var Z80): uint8 =
    z80.flag_set(Flag.C)
    z80.flag_clear(Flag.H)
    z80.flag_clear(Flag.N)
    return 4

# JR C, d
proc jr_38(z80: var Z80): uint8 =
    let offset = z80.fetch()
    let signed = cast[int8](offset)
    if z80.flag(Flag.C):
        var pc = z80.pc()
        pc += uint16(signed)
        z80.pc = pc
        return 12
    else:
        return 7

# ADD HL, SP
proc add_39(z80: var Z80): uint8 =
    let sp = z80.sp()
    z80.add(Reg16.HL, sp)
    return 11

# LD A, (nn)
proc ld_3a(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let data = z80.ram_read(address)
    z80.reg_write(Reg8.A, data)
    return 13

# DEC SP
proc dec_3b(z80: var Z80): uint8 =
    let sp = z80.sp()
    z80.sp = (sp - 1)
    return 6

# INC A
proc inc_3c(z80: var Z80): uint8 =
    z80.inc(Reg8.A)
    return 4

# DEC A
proc dec_3d(z80: var Z80): uint8 =
    z80.dec(Reg8.A)
    return 4

# LD A, n
proc ld_3e(z80: var Z80): uint8 =
    let byte = z80.fetch()
    z80.reg_write(Reg8.A, byte)
    return 7

# CCF
proc ccf_3f(z80: var Z80): uint8 =
    z80.flag_clear(Flag.N)
    z80.flag_clear(Flag.H)
    let cf = z80.flag(Flag.C)
    z80.flag_write(Flag.C, not cf)
    return 4

# LD B, B
proc ld_40(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.reg_write(Reg8.B, byte)
    return 4

# LD B, C
proc ld_41(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.reg_write(Reg8.B, byte)
    return 4

# LD B, D
proc ld_42(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.reg_write(Reg8.B, byte)
    return 4

# LD B, E
proc ld_43(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.reg_write(Reg8.B, byte)
    return 4

# LD B, H
proc ld_44(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.reg_write(Reg8.B, byte)
    return 4

# LD B, L
proc ld_45(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.reg_write(Reg8.B, byte)
    return 4

# LD B, (HL)
proc ld_46(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.HL, Reg8.B)
    return 7

# LD B, A
proc ld_47(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.reg_write(Reg8.B, byte)
    return 4

# LD C, B
proc ld_48(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.reg_write(Reg8.C, byte)
    return 4

# LD C, C
proc ld_49(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.reg_write(Reg8.C, byte)
    return 4

# LD C, D
proc ld_4a(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.reg_write(Reg8.C, byte)
    return 4

# LD C, E
proc ld_4b(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.reg_write(Reg8.C, byte)
    return 4

# LD C, H
proc ld_4c(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.reg_write(Reg8.C, byte)
    return 4

# LD C, L
proc ld_4d(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.reg_write(Reg8.C, byte)
    return 4

# LD C, (HL)
proc ld_4e(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.HL, Reg8.C)
    return 7

# LD C, A
proc ld_4f(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.reg_write(Reg8.C, byte)
    return 4

# LD D, B
proc ld_50(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.reg_write(Reg8.D, byte)
    return 4

# LD D, C
proc ld_51(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.reg_write(Reg8.D, byte)
    return 4

# LD D, D
proc ld_52(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.reg_write(Reg8.D, byte)
    return 4

# LD D, E
proc ld_53(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.reg_write(Reg8.D, byte)
    return 4

# LD D, H
proc ld_54(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.reg_write(Reg8.D, byte)
    return 4

# LD D, L
proc ld_55(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.reg_write(Reg8.D, byte)
    return 4

# LD D, (HL)
proc ld_56(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.HL, Reg8.D)
    return 7

# LD D, A
proc ld_57(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.reg_write(Reg8.D, byte)
    return 4

# LD E, B
proc ld_58(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.reg_write(Reg8.E, byte)
    return 4

# LD E, C
proc ld_59(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.reg_write(Reg8.E, byte)
    return 4

# LD E, D
proc ld_5a(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.reg_write(Reg8.E, byte)
    return 4

# LD E, E
proc ld_5b(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.reg_write(Reg8.E, byte)
    return 4

# LD E, H
proc ld_5c(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.reg_write(Reg8.E, byte)
    return 4

# LD E, L
proc ld_5d(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.reg_write(Reg8.E, byte)
    return 4

# LD E, (HL)
proc ld_5e(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.HL, Reg8.E)
    return 7

# LD E, A
proc ld_5f(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.reg_write(Reg8.E, byte)
    return 4

# LD H, B
proc ld_60(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.reg_write(Reg8.H, byte)
    return 4

# LD H, C
proc ld_61(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.reg_write(Reg8.H, byte)
    return 4

# LD H, D
proc ld_62(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.reg_write(Reg8.H, byte)
    return 4

# LD H, E
proc ld_63(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.reg_write(Reg8.H, byte)
    return 4

# LD H, H
proc ld_64(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.reg_write(Reg8.H, byte)
    return 4

# LD H, L
proc ld_65(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.reg_write(Reg8.H, byte)
    return 4

# LD H, (HL)
proc ld_66(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.HL, Reg8.H)
    return 7

# LD H, A
proc ld_67(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.reg_write(Reg8.H, byte)
    return 4

# LD L, B
proc ld_68(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.reg_write(Reg8.L, byte)
    return 4

# LD L, C
proc ld_69(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.reg_write(Reg8.L, byte)
    return 4

# LD L, D
proc ld_6a(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.reg_write(Reg8.L, byte)
    return 4

# LD L, E
proc ld_6b(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.reg_write(Reg8.L, byte)
    return 4

# LD L, H
proc ld_6c(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.reg_write(Reg8.L, byte)
    return 4

# LD L, L
proc ld_6d(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.reg_write(Reg8.L, byte)
    return 4

# LD L, (HL)
proc ld_6e(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.HL, Reg8.L)
    return 7

# LD L, A
proc ld_6f(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.reg_write(Reg8.E, byte)
    return 4

# LD (HL), B
proc ld_70(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.B, Reg16.HL)
    return 7

# LD (HL), C
proc ld_71(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.C, Reg16.HL)
    return 7

# LD (HL), D
proc ld_72(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.D, Reg16.HL)
    return 7

# LD (HL), E
proc ld_73(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.E, Reg16.HL)
    return 7

# LD (HL), H
proc ld_74(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.H, Reg16.HL)
    return 7

# LD (HL), L
proc ld_75(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.L, Reg16.HL)
    return 7

# HALT
proc halt_76(z80: var Z80): uint8 =
    z80.halted = true
    return 4

# LD (HL), A
proc ld_77(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.A, Reg16.HL)
    return 7

# LD A, B
proc ld_78(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.B)
    z80.reg_write(Reg8.A, byte)
    return 4

# LD A, C
proc ld_79(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.C)
    z80.reg_write(Reg8.A, byte)
    return 4

# LD A, D
proc ld_7a(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.D)
    z80.reg_write(Reg8.A, byte)
    return 4

# LD A, E
proc ld_7b(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.E)
    z80.reg_write(Reg8.A, byte)
    return 4

# LD A, H
proc ld_7c(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.H)
    z80.reg_write(Reg8.A, byte)
    return 4

# LD A, L
proc ld_7d(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.L)
    z80.reg_write(Reg8.A, byte)
    return 4

# LD A, (HL)
proc ld_7e(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.HL, Reg8.A)
    return 7

# LD A, A
proc ld_7f(z80: var Z80): uint8 =
    let byte = z80.reg(Reg8.A)
    z80.reg_write(Reg8.A, byte)
    return 4

# ADD A, B
proc add_80(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.add_a(val, false)
    return 4

# ADD A, C
proc add_81(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.add_a(val, false)
    return 4

# ADD A, D
proc add_82(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.add_a(val, false)
    return 4

# ADD A, E
proc add_83(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.add_a(val, false)
    return 4

# ADD A, H
proc add_84(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.add_a(val, false)
    return 4

# ADD A, L
proc add_85(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.add_a(val, false)
    return 4

# ADD A, (HL)
proc add_86(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.add_a(val, false)
    return 7

# ADD A, A
proc add_87(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.add_a(val, true)
    return 4

# ADC A, B
proc adc_88(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.add_a(val, true)
    return 4

# ADC A, C
proc adc_89(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.add_a(val, true)
    return 4

# ADC A, D
proc adc_8a(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.add_a(val, true)
    return 4

# ADC A, E
proc adc_8b(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.add_a(val, true)
    return 4

# ADC A, H
proc adc_8c(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.add_a(val, true)
    return 4

# ADC A, L
proc adc_8d(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.add_a(val, true)
    return 4

# ADC A, (HL)
proc adc_8e(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.add_a(val, true)
    return 7

# ADC A, A
proc adc_8f(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.add_a(val, true)
    return 4

# SUB B
proc sub_90(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.sub_a(val, false)
    return 4

# SUB C
proc sub_91(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.sub_a(val, false)
    return 4

# SUB D
proc sub_92(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.sub_a(val, false)
    return 4

# SUB E
proc sub_93(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.sub_a(val, false)
    return 4

# SUB H
proc sub_94(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.sub_a(val, false)
    return 4

# SUB L
proc sub_95(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.sub_a(val, false)
    return 4

# SUB (HL)
proc sub_96(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.sub_a(val, false)
    return 7

# SUB A
proc sub_97(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.sub_a(val, false)
    return 4

# SBC B
proc sbc_98(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.sub_a(val, true)
    return 4

# SBC C
proc sbc_99(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.sub_a(val, true)
    return 4

# SBC D
proc sbc_9a(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.sub_a(val, true)
    return 4

# SBC E
proc sbc_9b(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.sub_a(val, true)
    return 4

# SBC H
proc sbc_9c(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.sub_a(val, true)
    return 4

# SBC L
proc sbc_9d(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.sub_a(val, true)
    return 4

# SBC (HL)
proc sbc_9e(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.sub_a(val, true)
    return 7

# SBC A
proc sbc_9f(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.sub_a(val, true)
    return 4

# AND B
proc and_a0(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.and_a(val)
    return 4

# AND C
proc and_a1(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.and_a(val)
    return 4

# AND D
proc and_a2(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.and_a(val)
    return 4

# AND E
proc and_a3(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.and_a(val)
    return 4

# AND H
proc and_a4(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.and_a(val)
    return 4

# AND L
proc and_a5(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.and_a(val)
    return 4

# AND (HL)
proc and_a6(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.and_a(val)
    return 7

# AND A
proc and_a7(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.and_a(val)
    return 4

# XOR B
proc xor_a8(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.xor_a(val)
    return 4

# XOR C
proc xor_a9(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.xor_a(val)
    return 4

# XOR D
proc xor_aa(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.xor_a(val)
    return 4

# XOR E
proc xor_ab(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.xor_a(val)
    return 4

# XOR H
proc xor_ac(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.xor_a(val)
    return 4

# XOR L
proc xor_ad(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.xor_a(val)
    return 4

# XOR (HL)
proc xor_ae(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.xor_a(val)
    return 7

# XOR A
proc xor_af(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.xor_a(val)
    return 4

# OR B
proc or_b0(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.or_a(val)
    return 4

# OR C
proc or_b1(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.or_a(val)
    return 4

# OR D
proc or_b2(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.or_a(val)
    return 4

# OR E
proc or_b3(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.or_a(val)
    return 4

# OR H
proc or_b4(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.or_a(val)
    return 4

# OR L
proc or_b5(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.or_a(val)
    return 4

# OR (HL)
proc or_b6(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.or_a(val)
    return 7

# OR A
proc or_b7(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.or_a(val)
    return 4

# CP B
proc cp_b8(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.B)
    z80.cp_a(val)
    return 4

# CP C
proc cp_b9(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.C)
    z80.cp_a(val)
    return 4

# CP D
proc cp_ba(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.D)
    z80.cp_a(val)
    return 4

# CP E
proc cp_bb(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.E)
    z80.cp_a(val)
    return 4

# CP H
proc cp_bc(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.H)
    z80.cp_a(val)
    return 4

# CP L
proc cp_bd(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.L)
    z80.cp_a(val)
    return 4

# CP (HL)
proc cp_be(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    let val = z80.ram_read(hl)
    z80.cp_a(val)
    return 7

# CP A
proc cp_bf(z80: var Z80): uint8 =
    let val = z80.reg(Reg8.A)
    z80.cp_a(val)
    return 4

# RET NZ
proc ret_c0(z80: var Z80): uint8 =
    if not z80.flag(Flag.Z):
        let address = z80.pop()
        z80.pc = address
        return 15
    else:
        return 11

# POP BC
proc pop_c1(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.reg_write(Reg16.BC, val)
    return 10

# JP NZ, nn
proc jp_c2(z80: var Z80): uint8 =
    let offset = z80.fetch16()
    if not z80.flag(Flag.Z):
        z80.pc = offset
    return 10

# JP nn
proc jp_c3(z80: var Z80): uint8 =
    let offset = z80.fetch16()
    z80.pc = offset
    return 10

# CALL NZ, nn
proc call_c4(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if not z80.flag(Flag.Z):
        z80.push(z80.pc)
        z80.pc = address
        return 17
    else:
        return 10

# PUSH BC
proc push_c5(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    z80.push(bc)
    return 10

# ADD A, n
proc add_c6(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.add_a(val, false)
    return 7

# RST 00
proc rst_c7(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0000
    return 11

# RET Z
proc ret_c8(z80: var Z80): uint8 =
    if z80.flag(Flag.Z):
        let address = z80.pop()
        z80.pc = address
        return 15
    else:
        return 11

# RET
proc ret_c9(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.pc = val
    return 10

# JP Z, nn
proc jp_ca(z80: var Z80): uint8 =
    let offset = z80.fetch16()
    if z80.flag(Flag.Z):
        z80.pc = offset
    return 10

# PREFIX CB
proc prefix_cb(z80: var Z80): uint8 =
    return z80.execute_cb_op()

# CALL Z, nn
proc call_cc(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if z80.flag(Flag.Z):
        z80.push(z80.pc)
        z80.pc = address
        return 17
    else:
        return 10

# CALL nn
proc call_cd(z80: var Z80): uint8 =
    let address = z80.fetch16()
    z80.push(z80.pc)
    z80.pc = address
    return 17

# ADC A, n
proc adc_ce(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.add_a(val, true)
    return 7

# RST 08
proc rst_cf(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0008
    return 11

# RET NC
proc ret_d0(z80: var Z80): uint8 =
    if not z80.flag(Flag.C):
        let val = z80.pop()
        z80.pc = val
        return 15
    else:
        return 11

# POP DE
proc pop_d1(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.reg_write(Reg16.DE, val)
    return 10

# JP NC, nn
proc jp_d2(z80: var Z80): uint8 =
    let offset = z80.fetch16()
    if not z80.flag(Flag.C):
        z80.pc = offset
    return 10

# OUT (n), A
proc out_d3(z80: var Z80): uint8 =
    let port = z80.fetch()
    let a = z80.reg(Reg8.A)
    z80.port_write(port, a)
    return 11

# CALL NC, nn
proc call_d4(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if not z80.flag(Flag.C):
        z80.push(z80.pc)
        z80.pc = address
        return 17
    else:
        return 10

# PUSH DE
proc push_d5(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    z80.push(de)
    return 10

# SUB n
proc sub_d6(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.sub_a(val, false)
    return 7

# RST 10
proc rst_d7(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0010
    return 11

# RET C
proc ret_d8(z80: var Z80): uint8 =
    if z80.flag(Flag.C):
        let val = z80.pop()
        z80.pc = val
        return 15
    else:
        return 11

# EXX
proc exx_d9(z80: var Z80): uint8 =
    z80.exchange(Reg16.BC)
    z80.exchange(Reg16.DE)
    z80.exchange(Reg16.HL)
    return 4

# JP C, nn
proc jp_da(z80: var Z80): uint8 =
    let offset = z80.fetch16()
    if z80.flag(Flag.C):
        z80.pc = offset
    return 10

# IN A, (n)
proc in_db(z80: var Z80): uint8 =
    let port = z80.fetch()
    let data = z80.port_read(port)
    z80.reg_write(Reg8.A, data)
    return 11

# CALL C, nn
proc call_dc(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if z80.flag(Flag.C):
        z80.push(z80.pc)
        z80.pc = address
        return 17
    else:
        return 10

# PREFIX DD
proc prefix_dd(z80: var Z80): uint8 =
    return z80.execute_dd_op()

# SBC A, n
proc sbc_de(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.sub_a(val, true)
    return 7

# RST 18
proc rst_df(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0018
    return 11

# RET NP
proc ret_e0(z80: var Z80): uint8 =
    if not z80.flag(Flag.PV):
        let val = z80.pop()
        z80.pc = val
        return 15
    else:
        return 11

# POP HL
proc pop_e1(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.reg_write(Reg16.HL, val)
    return 10

# JP NP, nn
proc ld_e2(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if not z80.flag(Flag.PV):
        z80.pc = address
    return 10

# EX (SP), HL
proc ex_e3(z80: var Z80): uint8 =
    let data = z80.pop()
    let hl = z80.reg(Reg16.HL)
    z80.push(hl)
    z80.reg_write(Reg16.HL, data)
    return 19

# CALL NP, nn
proc call_e4(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if not z80.flag(Flag.PV):
        z80.push(z80.pc)
        z80.pc = address
        return 17
    else:
        return 10

# PUSH HL
proc push_e5(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    z80.push(hl)
    return 10

# AND n
proc and_e6(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.and_a(val)
    return 7

# RST 20
proc rst_e7(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0020
    return 11

# RET P
proc ret_e8(z80: var Z80): uint8 =
    if z80.flag(Flag.PV):
        let val = z80.pop()
        z80.pc = val
        return 15
    else:
        return 11

# JP HL
proc jp_e9(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    z80.pc = hl
    return 4

# JP P, nn
proc jp_ea(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if z80.flag(Flag.PV):
        z80.pc = address
    return 10

# EX DE, HL
proc ex_eb(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    let hl = z80.reg(Reg16.HL)
    z80.reg_write(Reg16.DE, hl)
    z80.reg_write(Reg16.HL, de)
    return 4

# CALL P, nn
proc call_ec(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if z80.flag(Flag.PV):
        z80.push(z80.pc)
        z80.pc = address
        return 17
    else:
        return 10

# PREFIX ED
proc prefix_ed(z80: var Z80): uint8 =
    return z80.execute_ed_op()

# XOR n
proc xor_ee(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.xor_a(val)
    return 7

# RST 28
proc rst_ef(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0028
    return 11

# RET NS
proc ret_f0(z80: var Z80): uint8 =
    if not z80.flag(Flag.S):
        let val = z80.pop()
        z80.pc = val
        return 15
    else:
        return 11

# POP AF
proc pop_f1(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.reg_write(Reg16.AF, val)
    return 10

# JP S, nn
proc jp_f2(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if not z80.flag(Flag.S):
        z80.pc = address
    return 10

# DI
proc di_f3(z80: var Z80): uint8 =
    z80.irq_enabled = false
    return 4

# CALL S, nn
proc call_f4(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if not z80.flag(Flag.S):
        z80.push(z80.pc)
        z80.pc = address
        return 17
    else:
        return 10

# PUSH AF
proc push_f5(z80: var Z80): uint8 =
    let af = z80.reg(Reg16.AF)
    z80.push(af)
    return 10

# OR n
proc or_f6(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.or_a(val)
    return 7

# RST 30
proc rst_f7(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0030
    return 11

# RET S
proc ret_f8(z80: var Z80): uint8 =
    if z80.flag(Flag.S):
        let val = z80.pop()
        z80.pc = val
        return 15
    else:
        return 11

# LD SP, HL
proc ld_f9(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    z80.sp = hl
    return 10

# JP S, nn
proc jp_fa(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if z80.flag(Flag.S):
        z80.pc = address
    return 10

# EI
proc ei_fb(z80: var Z80): uint8 =
    z80.irq_enabled = true
    return 4

# CALL S, nn
proc call_fc(z80: var Z80): uint8 =
    let address = z80.fetch16()
    if z80.flag(Flag.S):
        z80.push(z80.pc)
        z80.pc = address
        return 17
    else:
        return 10

# PREFIX FD
proc prefix_fd(z80: var Z80): uint8 =
    raise newException(UnimplementedError, "Prefix FD")

# CP n
proc cp_fe(z80: var Z80): uint8 =
    let val = z80.fetch()
    z80.cp_a(val)
    return 7

# RST 38
proc rst_ff(z80: var Z80): uint8 =
    z80.push(z80.pc)
    z80.pc = 0x0038
    return 11

# ADD IX, BC
proc add_dd09(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    z80.add(Reg16.IX, bc)
    return 15

# ADD IX, DE
proc add_dd19(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    z80.add(Reg16.IX, de)
    return 15

# LD IX, nn
proc ld_dd21(z80: var Z80): uint8 =
    let nn = z80.fetch16()
    z80.reg_write(Reg16.IX, nn)
    return 14

# LD (nn), IX
proc ld_dd22(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let ix = z80.reg(Reg16.IX)
    let data = z80.ram_read(ix)
    z80.ram_write(address, data)
    return 20

# INC IX
proc inc_dd23(z80: var Z80): uint8 =
    z80.inc(Reg16.IX)
    return 10

# ADD IX, IX
proc add_dd29(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    z80.add(Reg16.IX, ix)
    return 15

# LD IX, (nn)
proc ld_dd2a(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let data = z80.ram_read(address)
    z80.reg_write(Reg16.IX, data)
    return 20

# DEC IX
proc dec_dd2b(z80: var Z80): uint8 =
    z80.dec(Reg16.IX)
    return 10

# INC (IX+d)
proc inc_dd34(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.ram_read(address)
    let new_val = val + 1
    z80.ram_write(address, new_val)

    z80.flag_write(Flag.H, check_h_add(val, 1))
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.Z, new_val == 0)
    z80.flag_write(Flag.S, check_s(new_val))
    z80.flag_write(Flag.PV, check_v_add(val, 1))
    return 23

# DEC (IX+d)
proc dec_dd35(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.ram_read(address)
    let new_val = val - 1
    z80.ram_write(address, new_val)

    z80.flag_write(Flag.H, check_h_sub(val, 1))
    z80.flag_clear(Flag.N)
    z80.flag_write(Flag.Z, new_val == 0)
    z80.flag_write(Flag.S, check_s(new_val))
    z80.flag_write(Flag.PV, check_v_sub(val, 1))
    return 23

# LD (IX+d), n
proc ld_dd36(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.fetch()
    z80.ram_write(address, val)
    return 19

# ADD IX, SP
proc add_dd39(z80: var Z80): uint8 =
    let sp = z80.sp()
    z80.add(Reg16.IX, sp)
    return 15

# LD B, (IX+d)
proc ld_dd46(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.IX, Reg8.B)
    return 19

# LD C, (IX+d)
proc ld_dd4e(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.IX, Reg8.C)
    return 19

# LD D, (IX+d)
proc ld_dd56(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.IX, Reg8.D)
    return 19

# LD E, (IX+d)
proc ld_dd5e(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.IX, Reg8.E)
    return 19

# LD H, (IX+d)
proc ld_dd66(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.IX, Reg8.H)
    return 19

# LD L, (IX+d)
proc ld_dd6e(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.IX, Reg8.L)
    return 19

# LD (IX+d), B
proc ld_dd70(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.B, Reg16.IX)
    return 19

# LD (IX+d), C
proc ld_dd71(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.C, Reg16.IX)
    return 19

# LD (IX+d), D
proc ld_dd72(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.D, Reg16.IX)
    return 19

# LD (IX+d), E
proc ld_dd73(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.E, Reg16.IX)
    return 19

# LD (IX+d), H
proc ld_dd74(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.H, Reg16.IX)
    return 19

# LD (IX+d), L
proc ld_dd75(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.L, Reg16.IX)
    return 19

# LD (IX+d), A
proc ld_dd77(z80: var Z80): uint8 =
    z80.ld_into_ptr(Reg8.A, Reg16.IX)
    return 19

# LD A, (IX+d)
proc ld_dd7e(z80: var Z80): uint8 =
    z80.ld_outof_ptr(Reg16.IX, Reg8.A)
    return 19

# ADD A, (IX+d)
proc add_dd86(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.ram_read(address)
    z80.add_a(val, false)
    return 19

# ADC A, (IX+d)
proc adc_dd8e(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.ram_read(address)
    z80.add_a(val, true)
    return 19

# SUB A, (IX+d)
proc sub_dd96(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.ram_read(address)
    z80.sub_a(val, false)
    return 19

# SBC A, (IX+d)
proc sbc_dd9e(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.ram_read(address)
    z80.sub_a(val, true)
    return 19

# AND A, (IX+d)
proc and_dda6(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.ram_read(address)
    z80.and_a(val)
    return 19

# XOR A, (IX+d)
proc xor_ddae(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.ram_read(address)
    z80.xor_a(val)
    return 19

# OR A, (IX+d)
proc or_ddb6(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.ram_read(address)
    z80.or_a(val)
    return 19

# CP A, (IX+d)
proc cp_ddbe(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let offset = cast[int8](z80.fetch())
    let address = ix + uint16(offset)
    let val = z80.ram_read(address)
    z80.cp_a(val)
    return 19

# PREFIX DDCB
proc prefix_ddcb(z80: var Z80): uint8 =
    raise newException(UnimplementedError, "Prefix DDCB")

# POP IX
proc pop_dde1(z80: var Z80): uint8 =
    let val = z80.pop()
    z80.reg_write(Reg16.IX, val)
    return 14

# EX (SP), IX
proc ex_dde3(z80: var Z80): uint8 =
    let data = z80.pop()
    let ix = z80.reg(Reg16.IX)
    z80.push(ix)
    z80.reg_write(Reg16.IX, data)
    return 23

# PUSH IX
proc push_dde5(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    z80.push(ix)
    return 15

# JP (IX)
proc jp_dde9(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    let val = z80.ram_read(ix)
    z80.pc = val
    return 8

# LD SP, IX
proc ld_ddf9(z80: var Z80): uint8 =
    let ix = z80.reg(Reg16.IX)
    z80.sp = ix
    return 10

# IN B, (C)
proc in_ed40(z80: var Z80): uint8 =
    z80.in_port(Reg8.B)
    return 12

# OUT (C), B
proc out_ed41(z80: var Z80): uint8 =
    z80.out_port(Reg8.B)
    return 12

# SBC HL, BC
proc sbc_ed42(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    z80.sbc_hl(bc)
    return 15

# LD (nn), BC
proc ld_ed43(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let bc = z80.reg(Reg16.BC)
    z80.ram_write(address, bc.hi())
    z80.ram_write(address + 1, bc.lo())
    return 20

# NEG
proc neg_ed44(z80: var Z80): uint8 =
    let a = z80.reg(Reg8.A)
    let neg = 0 - a

    z80.flag_write(Flag.C, check_c_sub(0u8, a))
    z80.flag_set(Flag.N)
    z80.flag_write(Flag.PV, check_v_sub(0, a))
    z80.flag_write(Flag.Z, neg == 0)
    z80.flag_write(Flag.S, check_s(neg))
    z80.flag_write(Flag.H, check_h_sub(0, a))
    z80.reg_write(Reg8.A, neg)
    return 8

# RETN
proc retn_ed45(z80: var Z80): uint8 =
    z80.pc = z80.pop()
    return 14

# IM 0
proc im_ed46(z80: var Z80): uint8 =
    z80.irq_mode(IrqModes.Mode0)
    return 8

# LD I, A
proc ld_ed47(z80: var Z80): uint8 =
    let a = z80.reg(Reg8.A)
    z80.i = a
    return 9

# IN C, (C)
proc in_ed48(z80: var Z80): uint8 =
    z80.in_port(Reg8.C)
    return 12

# OUT (C), C
proc out_ed49(z80: var Z80): uint8 =
    z80.out_port(Reg8.C)
    return 12

# ADC HL, BC
proc adc_ed4a(z80: var Z80): uint8 =
    let bc = z80.reg(Reg16.BC)
    z80.adc_hl(bc)
    return 15

# LD BC, (nn)
proc ld_ed4b(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let data = z80.ram_read(address)
    z80.reg_write(Reg16.BC, data)
    return 20

# RETI
proc reti_ed4d(z80: var Z80): uint8 =
    z80.pc = z80.pop()
    return 14

# LD R, A
proc ld_ed4f(z80: var Z80): uint8 =
    let a = z80.reg(Reg8.A)
    z80.r = a
    return 9

# IN D, (C)
proc in_ed50(z80: var Z80): uint8 =
    z80.in_port(Reg8.D)
    return 12

# OUT (C), D
proc out_ed51(z80: var Z80): uint8 =
    z80.out_port(Reg8.D)
    return 12

# SBC HL, DE
proc sbc_ed52(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    z80.sbc_hl(de)
    return 15

# LD (nn), DE
proc ld_ed53(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let de = z80.reg(Reg16.DE)
    z80.ram_write(address, de.hi())
    z80.ram_write(address + 1, de.lo())
    return 20

# IM 1
proc im_ed56(z80: var Z80): uint8 =
    z80.irq_mode(IrqModes.Mode1)
    return 8

# LD A, I
proc ld_ed57(z80: var Z80): uint8 =
    let i = z80.i()
    z80.reg_write(Reg8.A, i)
    return 9

# IN E, (C)
proc in_ed58(z80: var Z80): uint8 =
    z80.in_port(Reg8.E)
    return 12

# OUT (C), E
proc out_ed59(z80: var Z80): uint8 =
    z80.out_port(Reg8.E)
    return 12

# ADC HL, DE
proc adc_ed5a(z80: var Z80): uint8 =
    let de = z80.reg(Reg16.DE)
    z80.adc_hl(de)
    return 15

# LD DE, (nn)
proc ld_ed5b(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let data = z80.ram_read(address)
    z80.reg_write(Reg16.DE, data)
    return 20

# IM 2
proc im_ed5e(z80: var Z80): uint8 =
    z80.irq_mode(IrqModes.Mode2)
    return 8

# LD A, R
proc ld_ed5f(z80: var Z80): uint8 =
    let r = z80.r()
    z80.reg_write(Reg8.A, r)
    return 9

# IN H, (C)
proc in_ed60(z80: var Z80): uint8 =
    z80.in_port(Reg8.H)
    return 12

# OUT (C), H
proc out_ed61(z80: var Z80): uint8 =
    z80.out_port(Reg8.H)
    return 12

# SBC HL, HL
proc sbc_ed62(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    z80.sbc_hl(hl)
    return 15

# RRD
proc rrd_ed67(z80: var Z80): uint8 =
    # TODO: Figure out flags
    let a = z80.reg(Reg8.A)
    let hl = z80.reg(Reg16.HL)
    let data = z80.ram_read(hl)
    let a_lo = a and 0xF
    let data_lo = data and 0xF
    let data_hi = (data and 0xF0) shr 4

    let new_a = (a and 0xF0) or data_lo
    let new_data = (a_lo shl 4) or data_hi
    z80.reg_write(Reg8.A, new_a)
    z80.ram_write(hl, new_data)
    return 18

# IN L, (C)
proc in_ed68(z80: var Z80): uint8 =
    z80.in_port(Reg8.L)
    return 12

# OUT (C), L
proc out_ed69(z80: var Z80): uint8 =
    z80.out_port(Reg8.L)
    return 12

# ADC HL, HL
proc adc_ed6a(z80: var Z80): uint8 =
    let hl = z80.reg(Reg16.HL)
    z80.adc_hl(hl)
    return 15

# RLD
proc rld_ed6f(z80: var Z80): uint8 =
    # TODO: Figure out flags
    let a = z80.reg(Reg8.A)
    let hl = z80.reg(Reg16.HL)
    let data = z80.ram_read(hl)
    let a_lo = a and 0xF
    let data_lo = data and 0xF
    let data_hi = (data and 0xF0) shr 4

    let new_a = (a and 0xF0) or data_hi
    let new_data = (data_lo shl 4) or a_lo
    z80.reg_write(Reg8.A, new_a)
    z80.ram_write(hl, new_data)
    return 18

# SBC HL, SP
proc sbc_ed72(z80: var Z80): uint8 =
    let sp = z80.sp()
    z80.sbc_hl(sp)
    return 15

# LD (nn), SP
proc ld_ed73(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let sp = z80.sp()
    z80.ram_write(address, sp.hi())
    z80.ram_write(address + 1, sp.lo())
    return 20

# IN A, (C)
proc in_ed78(z80: var Z80): uint8 =
    z80.in_port(Reg8.A)
    return 12

# OUT (C), A
proc out_ed79(z80: var Z80): uint8 =
    z80.out_port(Reg8.A)
    return 12

# ADC HL, SP
proc adc_ed7a(z80: var Z80): uint8 =
    let sp = z80.sp()
    z80.adc_hl(sp)
    return 15

# LD SP, (nn)
proc ld_ed7b(z80: var Z80): uint8 =
    let address = z80.fetch16()
    let data = z80.ram_read(address)
    z80.sp = data
    return 20

# LDI
proc ldi_eda0(z80: var Z80): uint8 =
    z80.ldi()
    let bc = z80.reg(Reg16.BC)
    z80.flag_write(Flag.PV, bc != 0)
    return 16

# CPI
proc cpi_eda1(z80: var Z80): uint8 =
    z80.cpi()
    let bc = z80.reg(Reg16.BC)
    z80.flag_write(Flag.PV, bc != 0)
    return 16

# INI
proc ini_eda2(z80: var Z80): uint8 =
    z80.ini()
    return 16

# OUTI
proc outi_eda3(z80: var Z80): uint8 =
    z80.outi()
    return 16

# LDD
proc ldd_eda8(z80: var Z80): uint8 =
    z80.ldd()
    let bc = z80.reg(Reg16.BC)
    z80.flag_write(Flag.PV, bc != 0)
    return 16

# CPD
proc cpd_eda9(z80: var Z80): uint8 =
    z80.cpd()
    let bc = z80.reg(Reg16.BC)
    z80.flag_write(Flag.PV, bc != 0)
    return 16

# IND
proc ind_edaa(z80: var Z80): uint8 =
    z80.ind()
    return 16

# OUTD
proc outd_edab(z80: var Z80): uint8 =
    z80.outd()
    return 16

# LDIR
proc ldir_edb0(z80: var Z80): uint8 =
    z80.ldi()
    let bc = z80.reg(Reg16.BC)
    if bc != 0:
        z80.ldi()
        return 21
    else:
        return 16

# CPIR
proc cpir_edb1(z80: var Z80): uint8 =
    z80.cpi()
    let bc = z80.reg(Reg16.BC)
    if bc != 0:
        z80.cpi()
        return 21
    else:
        return 16

# INIR
proc inir_edb2(z80: var Z80): uint8 =
    z80.ini()
    let b = z80.reg(Reg8.B)
    if b != 0:
        z80.ini()
        return 21
    else:
        return 16

# OTIR
proc otir_edb3(z80: var Z80): uint8 =
    z80.outi()
    let b = z80.reg(Reg8.B)
    if b != 0:
        z80.outi()
        return 21
    else:
        return 16

# LDDR
proc lddr_edb8(z80: var Z80): uint8 =
    z80.ldd()
    let bc = z80.reg(Reg16.BC)
    if bc != 0:
        z80.ldd()
        return 21
    else:
        return 16

# CPDR
proc cpdr_edb9(z80: var Z80): uint8 =
    z80.cpd()
    let bc = z80.reg(Reg16.BC)
    if bc != 0:
        z80.cpd()
        return 21
    else:
        return 16

# INDR
proc indr_edba(z80: var Z80): uint8 =
    z80.ind()
    let b = z80.reg(Reg8.B)
    if b != 0:
        z80.ind()
        return 21
    else:
        return 16

# OTDR
proc otdr_edbb(z80: var Z80): uint8 =
    z80.outd()
    let b = z80.reg(Reg8.B)
    if b != 0:
        z80.outd()
        return 21
    else:
        return 16

proc invalid(z80: var Z80): uint8 =
    raise newException(InvalidError, "Invalid opcode")

const OPCODES = [
#   $00,     $01,     $02,    $03,     $04,     $05,     $06,     $07,     $08,     $09,     $0A,    $0B,       $0C,     $0D,       $0E,     $0F
    nop_00,  ld_01,   ld_02,  inc_03,  inc_04,  dec_05,  ld_06,   rlca_07, ex_08,   add_09,  ld_0a,  dec_0b,    inc_0c,  dec_0d,    ld_0e,   rrca_0f, # $00
    djnz_10, ld_11,   ld_12,  inc_13,  inc_14,  dec_15,  ld_16,   rla_17,  jr_18,   add_19,  ld_1a,  dec_1b,    inc_1c,  dec_1d,    ld_1e,   rra_1f,  # $10
    jr_20,   ld_21,   ld_22,  inc_23,  inc_24,  dec_25,  ld_26,   daa_27,  jr_28,   add_29,  ld_2a,  dec_2b,    inc_2c,  dec_2d,    ld_2e,   cpl_2f,  # $20
    jr_30,   ld_31,   ld_32,  inc_33,  inc_34,  dec_35,  ld_36,   scf_37,  jr_38,   add_39,  ld_3a,  dec_3b,    inc_3c,  dec_3d,    ld_3e,   ccf_3f,  # $30
    ld_40,   ld_41,   ld_42,  ld_43,   ld_44,   ld_45,   ld_46,   ld_47,   ld_48,   ld_49,   ld_4a,  ld_4b,     ld_4c,   ld_4d,     ld_4e,   ld_4f,   # $40
    ld_50,   ld_51,   ld_52,  ld_53,   ld_54,   ld_55,   ld_56,   ld_57,   ld_58,   ld_59,   ld_5a,  ld_5b,     ld_5c,   ld_5d,     ld_5e,   ld_5f,   # $50
    ld_60,   ld_61,   ld_62,  ld_63,   ld_64,   ld_65,   ld_66,   ld_67,   ld_68,   ld_69,   ld_6a,  ld_6b,     ld_6c,   ld_6d,     ld_6e,   ld_6f,   # $60
    ld_70,   ld_71,   ld_72,  ld_73,   ld_74,   ld_75,   halt_76, ld_77,   ld_78,   ld_79,   ld_7a,  ld_7b,     ld_7c,   ld_7d,     ld_7e,   ld_7f,   # $70
    add_80,  add_81,  add_82, add_83,  add_84,  add_85,  add_86,  add_87,  adc_88,  adc_89,  adc_8a, adc_8b,    adc_8c,  adc_8d,    adc_8e,  adc_8f,  # $80
    sub_90,  sub_91,  sub_92, sub_93,  sub_94,  sub_95,  sub_96,  sub_97,  sbc_98,  sbc_99,  sbc_9a, sbc_9b,    sbc_9c,  sbc_9d,    sbc_9e,  sbc_9f,  # $90
    and_a0,  and_a1,  and_a2, and_a3,  and_a4,  and_a5,  and_a6,  and_a7,  xor_a8,  xor_a9,  xor_aa, xor_ab,    xor_ac,  xor_ad,    xor_ae,  xor_af,  # $A0
    or_b0,   or_b1,   or_b2,  or_b3,   or_b4,   or_b5,   or_b6,   or_b7,   cp_b8,   cp_b9,   cp_ba,  cp_bb,     cp_bc,   cp_bd,     cp_be,   cp_bf,   # $B0
    ret_c0,  pop_c1,  jp_c2,  jp_c3,   call_c4, push_c5, add_c6,  rst_c7,  ret_c8,  ret_c9,  jp_ca,  prefix_cb, call_cc, call_cd,   adc_ce,  rst_cf,  # $C0
    ret_d0,  pop_d1,  jp_d2,  out_d3,  call_d4, push_d5, sub_d6,  rst_d7,  ret_d8,  exx_d9,  jp_da,  in_db,     call_dc, prefix_dd, sbc_de,  rst_df,  # $D0
    ret_e0,  pop_e1,  ld_e2,  ex_e3,   call_e4, push_e5, and_e6,  rst_e7,  ret_e8,  jp_e9,   jp_ea,  ex_eb,     call_ec, prefix_ed, xor_ee,  rst_ef,  # $E0
    ret_f0,  pop_f1,  jp_f2,  di_f3,   call_f4, push_f5, or_f6,   rst_f7,  ret_f8,  ld_f9,   jp_fa,  ei_fb,     call_fc, prefix_fd, cp_fe,   rst_ff,  # $F0
]

const DD_OPCODES = [
#   $00,     $01,      $02,     $03,      $04,      $05,       $06,     $07,      $08,     $09,      $0A,      $0B,         $0C,     $0D,     $0E,      $0F
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   invalid, invalid,  invalid, add_dd09, invalid,  invalid,     invalid, invalid, invalid,  invalid, # $00
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   invalid, invalid,  invalid, add_dd19, invalid,  invalid,     invalid, invalid, invalid,  invalid, # $10
    invalid, ld_dd21,  ld_dd22, inc_dd23, invalid,  invalid,   invalid, invalid,  invalid, add_dd29, ld_dd2a,  dec_dd2b,    invalid, invalid, invalid,  invalid, # $20
    invalid, invalid,  invalid, invalid,  inc_dd34, dec_dd35,  ld_dd36, invalid,  invalid, add_dd39, invalid,  invalid,     invalid, invalid, invalid,  invalid, # $30
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   ld_dd46, invalid,  invalid, invalid,  invalid,  invalid,     invalid, invalid, ld_dd4e,  invalid, # $40
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   ld_dd56, invalid,  invalid, invalid,  invalid,  invalid,     invalid, invalid, ld_dd5e,  invalid, # $50
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   ld_dd66, invalid,  invalid, invalid,  invalid,  invalid,     invalid, invalid, ld_dd6e,  invalid, # $60
    ld_dd70, ld_dd71,  ld_dd72, ld_dd73,  ld_dd74,  ld_dd75,   invalid, ld_dd77,  invalid, invalid,  invalid,  invalid,     invalid, invalid, ld_dd7e,  invalid, # $70
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   invalid, add_dd86, invalid, invalid,  invalid,  invalid,     invalid, invalid, adc_dd8e, invalid, # $80
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   invalid, sub_dd96, invalid, invalid,  invalid,  invalid,     invalid, invalid, sbc_dd9e, invalid, # $90
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   invalid, and_dda6, invalid, invalid,  invalid,  invalid,     invalid, invalid, xor_ddae, invalid, # $A0
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   invalid, or_ddb6,  invalid, invalid,  invalid,  invalid,     invalid, invalid, cp_ddbe,  invalid, # $B0
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   invalid, invalid,  invalid, invalid,  invalid,  prefix_ddcb, invalid, invalid, invalid,  invalid, # $C0
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   invalid, invalid,  invalid, invalid,  invalid,  invalid,     invalid, invalid, invalid,  invalid, # $D0
    invalid, pop_dde1, invalid, ex_dde3,  invalid,  push_dde5, invalid, invalid,  invalid, jp_dde9,  invalid,  invalid,     invalid, invalid, invalid,  invalid, # $E0
    invalid, invalid,  invalid, invalid,  invalid,  invalid,   invalid, invalid,  invalid, ld_ddf9,  invalid,  invalid,     invalid, invalid, invalid,  invalid, # $F0
]

const ED_OPCODES = [
#   $00,       $01,       $02,       $03,       $04,      $05,       $06,     $07,      $08,       $09,       $0A,       $0B,       $0C,     $0D,       $0E,     $0F
    invalid,   invalid,   invalid,   invalid,   invalid,  invalid,   invalid, invalid,  invalid,   invalid,   invalid,   invalid,   invalid, invalid,   invalid, invalid, # $00
    invalid,   invalid,   invalid,   invalid,   invalid,  invalid,   invalid, invalid,  invalid,   invalid,   invalid,   invalid,   invalid, invalid,   invalid, invalid, # $10
    invalid,   invalid,   invalid,   invalid,   invalid,  invalid,   invalid, invalid,  invalid,   invalid,   invalid,   invalid,   invalid, invalid,   invalid, invalid, # $20
    invalid,   invalid,   invalid,   invalid,   invalid,  invalid,   invalid, invalid,  invalid,   invalid,   invalid,   invalid,   invalid, invalid,   invalid, invalid, # $30
    in_ed40,   out_ed41,  sbc_ed42,  ld_ed43,   neg_ed44, retn_ed45, im_ed46, ld_ed47,  in_ed48,   out_ed49,  adc_ed4a,  ld_ed4b,   invalid, reti_ed4d, invalid, ld_ed4f, # $40
    in_ed50,   out_ed51,  sbc_ed52,  ld_ed53,   invalid,  invalid,   im_ed56, ld_ed57,  in_ed58,   out_ed59,  adc_ed5a,  ld_ed5b,   invalid, invalid,   im_ed5e, ld_ed5f, # $50
    in_ed60,   out_ed61,  sbc_ed62,  invalid,   invalid,  invalid,   invalid, rrd_ed67, in_ed68,   out_ed69,  adc_ed6a,  invalid,   invalid, invalid,   invalid, rld_ed6f, # $60
    invalid,   invalid,   sbc_ed72,  ld_ed73,   invalid,  invalid,   invalid, invalid,  in_ed78,   out_ed79,  adc_ed7a,  ld_ed7b,   invalid, invalid,   invalid, invalid, # $70
    invalid,   invalid,   invalid,   invalid,   invalid,  invalid,   invalid, invalid,  invalid,   invalid,   invalid,   invalid,   invalid, invalid,   invalid, invalid, # $80
    invalid,   invalid,   invalid,   invalid,   invalid,  invalid,   invalid, invalid,  invalid,   invalid,   invalid,   invalid,   invalid, invalid,   invalid, invalid, # $90
    ldi_eda0,  cpi_eda1,  ini_eda2,  outi_eda3, invalid,  invalid,   invalid, invalid,  ldd_eda8,  cpd_eda9,  ind_edaa,  outd_edab, invalid, invalid,   invalid, invalid, # $A0
    ldir_edb0, cpir_edb1, inir_edb2, otir_edb3, invalid,  invalid,   invalid, invalid,  lddr_edb8, cpdr_edb9, indr_edba, otdr_edbb, invalid, invalid,   invalid, invalid, # $B0
    invalid,   invalid,   invalid,   invalid,   invalid,  invalid,   invalid, invalid,  invalid,   invalid,   invalid,   invalid,   invalid, invalid,   invalid, invalid, # $C0
    invalid,   invalid,   invalid,   invalid,   invalid,  invalid,   invalid, invalid,  invalid,   invalid,   invalid,   invalid,   invalid, invalid,   invalid, invalid, # $D0
    invalid,   invalid,   invalid,   invalid,   invalid,  invalid,   invalid, invalid,  invalid,   invalid,   invalid,   invalid,   invalid, invalid,   invalid, invalid, # $E0
    invalid,   invalid,   invalid,   invalid,   invalid,  invalid,   invalid, invalid,  invalid,   invalid,   invalid,   invalid,   invalid, invalid,   invalid, invalid, # $F0
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
        else: raise newException(UnreachableError, "Unreachable")

proc execute_cb_op(z80: var Z80): uint8 =
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
    let op = z80.fetch()
    case op:
        of 0x00..0x05, 0x07:
            let reg = decode_cb_reg(op)
            z80.rot_left_reg(reg, false)
            return 8
        of 0x06:
            let hl = z80.reg(Reg16.HL)
            let byte = z80.ram_read(hl)
            let rot = z80.rot_left(byte, false)
            z80.ram_write(hl, rot)
            return 15
        of 0x08..0x0D, 0x0F:
            let reg = decode_cb_reg(op)
            z80.rot_right_reg(reg, false)
            return 8
        of 0x0E:
            let hl = z80.reg(Reg16.HL)
            let byte = z80.ram_read(hl)
            let rot = z80.rot_right(byte, false)
            z80.ram_write(hl, rot)
            return 15
        of 0x10..0x15, 0x17:
            let reg = decode_cb_reg(op)
            z80.rot_left_reg(reg, true)
            return 8
        of 0x16:
            let hl = z80.reg(Reg16.HL)
            let byte = z80.ram_read(hl)
            let rot = z80.rot_left(byte, true)
            z80.ram_write(hl, rot)
            return 15
        of 0x18..0x1D, 0x1F:
            let reg = decode_cb_reg(op)
            z80.rot_right_reg(reg, true)
            return 8
        of 0x1E:
            let hl = z80.reg(Reg16.HL)
            let byte = z80.ram_read(hl)
            let rot = z80.rot_right(byte, true)
            z80.ram_write(hl, rot)
            return 15
        of 0x20..0x25, 0x27:
            let reg = decode_cb_reg(op)
            z80.shift_left_reg(reg)
            return 8
        of 0x26:
            let address = z80.reg(Reg16.HL)
            let byte = z80.ram_read(address)
            let shifted = z80.shift_left(byte)
            z80.ram_write(address, shifted)
            return 15
        of 0x28..0x2D, 0x2F:
            let reg = decode_cb_reg(op)
            z80.shift_right_reg(reg, true)
            return 8
        of 0x2E:
            let hl = z80.reg(Reg16.HL)
            let val = z80.ram_read(hl)
            let shifted = z80.shift_right(val, true)
            z80.ram_write(hl, shifted)
            return 15
        of 0x30..0x35, 0x37:
            let reg = decode_cb_reg(op)
            z80.swap_bits_reg(reg)
            return 8
        of 0x36:
            let hl = z80.reg(Reg16.HL)
            let val = z80.ram_read(hl)
            let swapped = z80.swap_bits(val)
            z80.ram_write(hl, swapped)
            return 15
        of 0x38..0x3D, 0x3F:
            let reg = decode_cb_reg(op)
            z80.shift_right_reg(reg, false)
            return 8
        of 0x3E:
            let hl = z80.reg(Reg16.HL)
            let val = z80.ram_read(hl)
            let shifted = z80.shift_right(val, false)
            z80.ram_write(hl, shifted)
            return 15
        of 0x40..0x7F:
            let rel_offset = op - 0x40
            let digit = rel_offset div 0x08

            case op and 0x0F:
                of 0x06, 0x0E:
                    let hl = z80.reg(Reg16.HL)
                    let val = z80.ram_read(hl)
                    z80.check_bit(val, digit)
                    return 12
                else:
                    let reg = decode_cb_reg(op)
                    z80.check_bit_reg(reg, digit)
                    return 8
        of 0x80..0xBF:
            let rel_offset = op - 0x80
            let digit = rel_offset div 0x08

            case op and 0x0F:
                of 0x06, 0x0E:
                    let hl = z80.reg(Reg16.HL)
                    z80.write_bit_ram(hl, digit, false)
                    return 15
                else:
                    let reg = decode_cb_reg(op)
                    z80.write_bit_n(reg, digit, false)
                    return 8
        of 0xC0..0xFF:
            let rel_offset = op - 0xC0
            let digit = rel_offset div 0x08

            case op and 0x0F:
                of 0x06, 0x0E:
                    let hl = z80.reg(Reg16.HL)
                    z80.write_bit_ram(hl, digit, true)
                    return 15
                else:
                    let reg = decode_cb_reg(op)
                    z80.write_bit_n(reg, digit, true)
                    return 8

proc execute_dd_op(z80: var Z80): uint8 =
    let opcode = z80.fetch()
    let op_fn = DD_OPCODES[opcode]
    return z80.op_fn()

proc execute_ed_op(z80: var Z80): uint8 =
    let opcode = z80.fetch()
    let op_fn = ED_OPCODES[opcode]
    return z80.op_fn()

proc execute*(z80: var Z80): uint8 =
    if z80.halted:
        return 1
    let opcode = z80.fetch()
    echo(&"{opcode:#2x}")
    let op_fn = OPCODES[opcode]
    return z80.op_fn()
