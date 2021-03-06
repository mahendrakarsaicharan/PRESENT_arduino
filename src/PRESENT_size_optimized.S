#include <avr/io.h>
; Copyright (c) 2013 Aram Verstegen

; Permission is hereby granted, free of charge, to any person obtaining a copy
; of this software and associated documentation files (the "Software"), to deal
; in the Software without restriction, including without limitation the rights
; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
; copies of the Software, and to permit persons to whom the Software is
; furnished to do so, subject to the following conditions:

; The above copyright notice and this permission notice shall be included in
; all copies or substantial portions of the Software.

; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
; THE SOFTWARE.

; PRESENT cipher for AVR devices

; AUTHORS
; implemented by Aram Verstegen
; in collaboration with Kostas Papagiannopoulos
; based on work by:
;    Andrey Bogdanov et al (PRESENT authors)
;    Bo Zhu and Zheng Gong (efficient C version)
;    Thomas Eisenbarth     (existing AVR implementation)

; INSTITUTE
; developed at Radboud Universiteit Nijmegen
; for the Cryptography Engineering course, 2012-2013
; part of the Kerckhoffs Institute master's program

; SPECIFICATIONS
; Size optimized version 2 - May 2013
; Code size (total):           256 bytes + 16 bytes for both packed s-boxes
; RAM words:                    18
; Cycle count (encryption): 190045
; Cycle count (decryption): 253380

; USE
; Point X at 8 input bytes followed by 10/16 key bytes and call encrypt or
; decrypt. After having called encrypt or decrypt X will point to the same
; address, where the next 8 bytes constitute the output.

; CONFIGURATION
.global encrypt
;.global decrypt
.set ENCRYPTION, 1         ; (can save 26 bytes if omitted)
;.set DECRYPTION, 1        ; (can save 68 bytes if omitted)
;.set FAST_ROTATE, 1       ; Fast rotation (adds 4 bytes, 4x speedup)
;.set PRESENT_128, 1       ; Use 128-bit keys (adds 12 bytes if FAST_ROTATE set)
;.set ZERO_KEY, 1          ; Zeroise key in SRAM (adds 2 bytes)
.set RELOCATABLE_SBOXES, 1 ; This makes s-boxes relocatable in flash
                           ; otherwise they are mapped at 0x100 and 0x200
                           ; (adds 6 bytes)
; Must align this section to 256 bytes for this to work
;.ifdef DECRYPTION
;.set PACKED_SBOXES, 1     ; Use packed s-boxes (saves 2 bytes)
;.endif
; !!! ATtiny45 specific! Disable packed s-boxes elsewhere unless verified! !!!
;.ifdef PACKED_SBOXES
;.set QUANTIZE_TIMING, 1   ; Avoid timing attacks (adds 6 bytes)
;.endif

; Number of rounds
ROUNDS = 31

; Key registers (the first 8 of these hold the current round key)
#define KEY0 r0
#define KEY1 r1
#define KEY2 r2
#define KEY3 r3
#define KEY4 r4
#define KEY5 r5
#define KEY6 r6
#define KEY7 r7
#define KEY8 r8
#define KEY9 r9
#define KEY10 r10
#define KEY11 r11
#define KEY12 r12
#define KEY13 r13
#define KEY14 r14
#define KEY15 r15

; Output registers (these hold p-layer output)
#define OUTPUT0 r16
#define OUTPUT1 r17
#define OUTPUT2 r18
#define OUTPUT3 r19

#define ROUND_COUNTER r20
#define SBOX_OUTPUT r21
; Shared register:
#define KEY_BYTE r22
#define SBOX_INDEX r22
#define PLAYER_INDEX r22

#define SBOX_DISPLACEMENT r23
#define ITEMP r24
#define ROTATED_BITS r25

#define ZERO r29

; registers r26..r31 are X, Y and Z

; the Z register is used to point to these s-box tables
.ifdef PACKED_SBOXES
.ifndef RELOCATABLE_SBOXES
.org 256
.endif
SBOX:   .byte 0xc5,0x6b,0x90,0xad,0x3e,0xf8,0x47,0x12
.ifdef DECRYPTION
.ifndef RELOCATABLE_SBOXES
.org 512
.endif
INVSBOX:.byte 0x5e,0xf8,0xc1,0x2d,0xb4,0x63,0x07,0x9a
.endif
.else
.ifndef RELOCATABLE_SBOXES
.org 256
.endif
SBOX:   .byte 0xc,0x5,0x6,0xb,0x9,0x0,0xa,0xd,0x3,0xe,0xf,0x8,0x4,0x7,0x1,0x2
.ifdef DECRYPTION
.ifndef RELOCATABLE_SBOXES
.org 512
.endif
INVSBOX:.byte 0x5,0xe,0xf,0x8,0xc,0x1,0x2,0xd,0xb,0x4,0x6,0x3,0x0,0x7,0x9,0xa
.endif
.endif

; key scheduling
.macro schedule_key_macro
; increment round counter
inc ROUND_COUNTER
; 1: rotate key register left by 61 positions
ldi ITEMP, 6
rcall rotate_left_i
; 3: xor key bits with round counter
; (as the 2 bytes align while rotating the key register)
eor KEY4, ROUND_COUNTER
; continue rotation
ldi ITEMP, 55
rcall rotate_left_i
; 2: s-box high nibble of key
mov ITEMP, KEY0
.ifdef PRESENT_128
rcall sBoxByte
.else
rcall sBoxHighNibble
.endif
mov KEY0, ITEMP
; check if we are at ROUNDS for caller's loop
cpi ROUND_COUNTER, ROUNDS
.endm

; apply last computed round key to the full 8-byte state in SRAM
.macro addRoundKey_macro
clr YL
addRoundKey_byte:
; apply round key
ld ITEMP, X
ld KEY_BYTE, Y+
eor ITEMP, KEY_BYTE
st X+, ITEMP

; loop over 8 bytes
cpi YL, 8
brne addRoundKey_byte
; point at the start of the block
subi XL, 8
.endm

; rotate the 80 or 128-bit key register left by the number in ITEMP
rotate_left_i:
.ifdef FAST_ROTATE
; rotate a carry bit through every register
; but don't rotate the current carry bit into the register we will
; add the final carry bit to as the least significant bit
.ifdef PRESENT_128
lsl KEY15
rol KEY14
rol KEY13
rol KEY12
rol KEY11
rol KEY10
rol KEY9
.else
lsl KEY9
.endif
rol KEY8
rol KEY7
rol KEY6
rol KEY5
rol KEY4
rol KEY3
rol KEY2
rol KEY1
rol KEY0
.else
; point at last key byte
.ifdef PRESENT_128
ldi YL, 16
.else
ldi YL, 10
.endif
; clear carry bit
clc
rotate_left_i_bit:
; rotate carry bit through each key register using indirect addressing
ld ROTATED_BITS, -Y
rol ROTATED_BITS
st Y, ROTATED_BITS
; cpse doesn't affect the C (carry) flag
cpse YL, ZERO
; loop over all the key bytes
rjmp rotate_left_i_bit
.endif
; add the last carry bit to the lowest/rightmost key register as LSB
.ifdef PRESENT_128
adc KEY15, ZERO
.else
adc KEY9, ZERO
.endif
; loop over ITEMP bits
dec ITEMP
brne rotate_left_i
ret

; sBoxByte
; applying the s-box nibble-wise allows us to reuse the second half of the
; procedure as its own procedure when key scheduling
; reads from and writes to ITEMP
sBoxByte:
rcall sBoxLowNibbleAndSwap ; apply s-box to low nibble and swap nibbles
rjmp sBoxLowNibbleAndSwap  ; do it again and return
sBoxHighNibble:
swap ITEMP                 ; swap nibbles in IO register
sBoxLowNibbleAndSwap:
; input (low nibble)
mov ZL, ITEMP              ; load s-box input from IO register
cbr ZL, 0xf0               ; clear high nibble in s-box input
.ifdef RELOCATABLE_SBOXES
add ZL, SBOX_DISPLACEMENT  ; displacement for s-box pointer
.endif
.ifdef PACKED_SBOXES
asr ZL                     ; halve input, take carry
.endif

; output (low nibble)
lpm SBOX_OUTPUT, Z         ; get s-box output

.ifdef PACKED_SBOXES
brcs odd_unpack            ; 2 cycles if true, 1 if false
even_unpack:
swap SBOX_OUTPUT           ; 1 cycle
.ifdef QUANTIZE_TIMING
rjmp unpack                ; 2 cycles
.endif
odd_unpack:                ; avoid timing attacks
.ifdef QUANTIZE_TIMING
nop                        ; 1 cycle
nop
.endif
; 4 cycles total
unpack:
cbr SBOX_OUTPUT, 0xf0      ; clear high nibble in s-box output
.endif

cbr ITEMP, 0xf             ; clear low nibble in IO register
or ITEMP, SBOX_OUTPUT      ; save low nibble to IO register

swap ITEMP                 ; swap nibbles in IO register (back)
ret

; apply loaded s-box to the full 8-byte state in SRAM
.macro sBoxLayer_macro
ldi SBOX_INDEX, 8
sBoxLayer_byte:
; apply s-box
ld ITEMP, X
rcall sBoxByte
st X+, ITEMP
; loop over 8 bytes
dec SBOX_INDEX
brne sBoxLayer_byte

; point at the start of the block
subi XL, 8
.endm

; splice half a byte over 4 output bytes, which will then each hold 1 bit
; following a 4-bit period in the input
pLayerNibble:
ror ITEMP   ; move bit into carry
ror OUTPUT0 ; move bit into output register
ror ITEMP   ; etc
ror OUTPUT1
ror ITEMP
ror OUTPUT2
ror ITEMP
ror OUTPUT3
ret

; apply the p-layer to the full 8-byte state in SRAM in two steps

; repeated half p-layer block:
;   4 bytes are read from SRAM from back to front
;   the pLayerNibble procedure is applied twice to each byte
;   the resulting 4 bytes of output are pushed onto the stack
; the output is saved to SRAM where the two half blocks become interleaved

; uses T (transfer) flag to re-do this block twice
.macro pLayer_macro
set
; point at end of block
adiw XL, 8
continue_pLayerHalf:
; apply p-layer to 4 bytes at a time
ldi PLAYER_INDEX, 4
pLayerHalf_byte:
ld ITEMP, -X

rcall pLayerNibble
rcall pLayerNibble

; loop over 4 input bytes
dec PLAYER_INDEX
brne pLayerHalf_byte

; half p-layer output
push OUTPUT3
push OUTPUT2
push OUTPUT1
push OUTPUT0

; go to output after 8 pushed bytes
brtc pLayerOutput
; do the next 4 bytes before output
clt
rjmp continue_pLayerHalf

; interleave the two half blocks on the stack into SRAM from back to front
; uses T (transfer) flag to re-do this block twice
pLayerOutput:
; point at last odd state bytes
adiw XL, 7
continue_pLayerOutput:
ldi PLAYER_INDEX, 4
pLayerOutput_byte:
; load p-layer output from stack and store into SRAM
pop ITEMP
st -X, ITEMP
; interleave bytes
dec XL
; loop over 4 bytes
dec PLAYER_INDEX
brne pLayerOutput_byte
; 2x4 bytes have been interleaved from the stack to SRAM
brts pLayer_done
set
; point at last even state bytes
adiw XL, 9
rjmp continue_pLayerOutput
pLayer_done:
.endm

; prepare for encryption or decryption
.macro setup_macro
; clear round counter
clr ROUND_COUNTER
; initialize s-box
ldi ZH, hi8(pm(SBOX))
.ifdef RELOCATABLE_SBOXES
.ifdef PACKED_SBOXES
ldi SBOX_DISPLACEMENT, lo8(pm(SBOX))
lsl SBOX_DISPLACEMENT
lsl SBOX_DISPLACEMENT
.else
ldi SBOX_DISPLACEMENT, lo8(pm(SBOX))
lsl SBOX_DISPLACEMENT
.endif
.endif
; point at the key bytes
adiw XL, 8
; load key from SRAM
clr YH
clr YL
load_key:
.ifdef ZERO_KEY
ld ITEMP, X
st X+, ZERO
.else
ld ITEMP, X+
.endif
st Y+, ITEMP
.ifdef PRESENT_128
cpi YL, 16
.else
cpi YL, 10
.endif
brne load_key
; point at the start of the input
.ifdef PRESENT_128
subi XL, 24
.else
subi XL, 18
.endif
.endm

.ifdef ENCRYPTION 
.ifdef DECRYPTION
schedule_key:
schedule_key_macro
ret
sBoxLayer:
sBoxLayer_macro
ret
setup:
setup_macro
ret
.endif
.endif

.ifdef ENCRYPTION

; encryption function: point X at 8 plaintext input bytes followed by 10/16 key input bytes
encrypt:
.ifndef DECRYPTION
setup_macro
.else
rcall setup
.endif
encrypt_update:
; apply round key
rcall addRoundKey

; apply s-box layer
; apply p-layer
; schedule next key
.ifndef DECRYPTION
sBoxLayer_macro
pLayer_macro
schedule_key_macro
.else
rcall sBoxLayer
rcall pLayer
rcall schedule_key
.endif

; loop for ROUNDS
brne encrypt_update
; add final round key
addRoundKey:
addRoundKey_macro
ret
.endif

.ifdef DECRYPTION
pLayer:
pLayer_macro
ret

; decryption function: point X at 8 ciphertext input bytes followed by 10/16 key input bytes
decrypt:
.ifndef ENCRYPTION
setup_macro
.else
rcall setup
.endif

; schedule key for last round
schedule_last_key:
.ifndef ENCRYPTION
schedule_key_macro
.else
rcall schedule_key
.endif
brne schedule_last_key

; initialize inv s-box
ldi ZH, hi8(pm(INVSBOX))
.ifdef RELOCATABLE_SBOXES
.ifdef PACKED_SBOXES
ldi SBOX_DISPLACEMENT, lo8(pm(INVSBOX))
lsl SBOX_DISPLACEMENT
lsl SBOX_DISPLACEMENT
.else
ldi SBOX_DISPLACEMENT, lo8(pm(INVSBOX))
lsl SBOX_DISPLACEMENT
.endif
.endif

; start round
decrypt_update:
; apply round key
rcall addRoundKey

; invert p-layer
rcall pLayer
rcall pLayer

; apply inverse s-box layer
.ifndef ENCRYPTION
sBoxLayer_macro
.else
rcall sBoxLayer
.endif

; schedule previous key
inv_schedule_key:
; 2: inv s-box high nibble of key
mov ITEMP, KEY0
.ifdef PRESENT_128
rcall sBoxByte
.else
rcall sBoxHighNibble
.endif
mov KEY0, ITEMP

; 1: rotate key register left by 67 positions
; 3: xor key bits with round counter
; (as the 2 bytes align while rotating the key register)
; continue rotation
.ifdef PRESENT_128
ldi ITEMP, 1
rcall rotate_left_i
eor KEY13, ROUND_COUNTER
ldi ITEMP, 66
rcall rotate_left_i
.else
ldi ITEMP, 17
rcall rotate_left_i
eor KEY5, ROUND_COUNTER
ldi ITEMP, 2
rcall rotate_left_i
.endif

; decrement round counter
dec ROUND_COUNTER

; loop for ROUNDS
brne decrypt_update
; apply final round key
.ifndef ENCRYPTION
addRoundKey:
addRoundKey_macro
ret
.else
rjmp addRoundKey
.endif
.endif

