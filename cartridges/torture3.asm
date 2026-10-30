.title "TORTURE"
.entry start
.org 0
start:
    JMP L0


SUB0:
    SHRI R7, 0x21
    XORI R2, 0x76
    ADDI R4, 0xF2
    RTS

SUB1:
    LDR R6, [0x9A]
    LDR R2, [0xA7]
    AND R1, R1
    AND R6, R6
    RTS

SUB2:
    ADD R1, R1
    LDR R1, [0x45+X]
    ROL R3, R4
    XOR R2, R0
    RTS

SUB3:
    LDR R5, [0x5A]
    LDR R0, [0x43]
    RTS

L0:
    MOVI R1, 0x34
    LDR R5, [0x72]
    SUBI R1, -44
    STR R3, [0xE6]
    MOV R1, R0
    SHRI R2, 0x8E
    ADCI R5, -76
    AND R4, R7
    XORI R6, 0x12
L1:
    ADD R7, R6
    LDR R3, [0x10]
    STR R4, [0xAE]
    BRA L0
    BCS L0
    STR R0, [0x11+X]
    BPL L4
    BCC L4
    CMP R1, R2
    ADDI R6, 0x1B
    JMP L39
L2:
    SHLI R7, 0x1F
    SHLI R1, 0x57
    AND R2, R0
    XORI R0, 0x8A
    SHR R6, R0
    ADDI R0, -100
    ADC R0, R1
    ADCI R7, 0xA1
L3:
    MOVI R6, 0x9B
    ORI R6, 0x3F
    ADD R6, R1
    LDR R0, [0xBF]
    SHLI R6, 0x16
    LDR R6, [0x1B+X]
    ORI R6, 0xD6
    SHLI R4, 0x24
    STR R3, [0xDA+X]
L4:
    BCS L5
    JMP L35
    STR R4, [0x3E+X]
    MOVI R6, 0x37
    STR R1, [0x02]
    XORI R0, 0x2F
    LDR R6, [0x5B]
    STR R5, [0x3E+X]
    ADC R7, R4
L5:
    ADC R0, R3
    ROR R1, R0
    LDR R2, [0x27]
    SUB R3, R7
    LDR R6, [0x81]
    ORI R6, 0x2A
    XORI R2, 0xD4
    STR R7, [0x4F]
    LDR R2, [0x53+X]
    ROR R7, R7
    LDR R2, [0x45]
    SBC R2, R5
L6:
    BMI L5
    LDR R6, [0x88+X]
    BCS L1
    MOV R6, R3
    OR R3, R5
    XORI R7, -90
    LDR R7, [0x0E]
    XORI R0, -60
    BNE L11
L7:
    STR R1, [0x6F]
    BNE L5
    STR R2, [0x5F]
    LDR R0, [0x82+X]
    ADD R5, R2
    ADCI R1, -12
    AND R0, R5
    ORI R0, -4
    CMPI R1, 0x6B
    LDR R7, [0xC8+X]
    OR R1, R4
    XOR R1, R7
    BCS L3
L8:
    JMP L23
    LDR R5, [0xE6+X]
    ROL R4, R1
    STR R5, [0x3A]
    LDR R5, [0x1E+X]
    STR R2, [0x4C]
    ROL R7, R1
    SHL R2, R5
    LDR R6, [0x99+X]
    LDR R7, [0xF6+X]
    ADCI R1, 0x5C
    STR R6, [0xB7]
L9:
    XOR R0, R2
    SHL R4, R3
    STR R5, [0xAA]
    JMP L28
    ORI R7, -109
    NOP
    ADC R1, R1
    SBC R6, R6
L10:
    JSR SUB1
    LDR R2, [0xCB]
    STR R2, [0x5B+X]
    AND R5, R4
    MOV R7, R6
    JMP L24
    ANDI R7, -126
    MOVI R7, -4
    LDR R0, [0x37]
    STR R3, [0xFB]
    ROL R7, R3
    SHL R3, R0
    STR R7, [0x39+X]
    LDR R2, [0x45]
L11:
    STR R0, [0x0D+X]
    ADCI R7, 0x09
    BCS L11
    BPL L8
    SHR R0, R1
    STR R5, [0x69]
    JMP L12
    CMPI R5, -14
    STR R6, [0x27+X]
    BPL L8
    ADCI R6, 0x6A
L12:
    CMPI R6, 0xE0
    ADD R4, R5
    BCC L15
    ADDI R3, 0x84
    STR R2, [0xEB+X]
    ADDI R2, 0xCE
    SUBI R1, 0x56
    ADDI R6, 0xE5
    ADDI R3, 0xCE
    CMP R0, R3
    XOR R7, R3
    SHR R1, R5
    BMI L7
L13:
    STR R4, [0xEE]
    STR R4, [0xFA+X]
    AND R0, R5
    LDR R5, [0xA2+X]
    ROL R6, R1
    LDR R0, [0x35]
    ADC R0, R2
    SBCI R5, 0x66
    BRA L15
    ORI R0, 0xC3
    XORI R1, 0x96
    XOR R1, R6
    XORI R2, 0xC5
    BMI L13
L14:
    SBCI R7, 0xF6
    SHLI R6, -122
    ADDI R7, 0x2F
    STR R1, [0xA3]
    MOV R0, R0
    MOVI R5, -48
    SBC R6, R1
    CMPI R1, 0x6B
    ADD R2, R2
L15:
    WFI
    AND R3, R3
    BMI L16
    ORI R3, -60
    ADC R0, R1
    LDR R1, [0x66]
    JMP L16
    CMP R6, R3
    STR R1, [0xF8+X]
    STR R5, [0xCE]
    LDR R7, [0x38]
    SHR R7, R6
L16:
    ADD R7, R4
    STR R1, [0xAE]
    ADCI R5, 0xD8
    STR R1, [0x6D+X]
    ADD R5, R3
    SBCI R5, 0x54
    STR R3, [0x6F]
    BPL L20
    XORI R5, -122
L17:
    BCC L19
    BCC L19
    NOP
    ADD R2, R1
    SUB R4, R0
    LDR R0, [0x63+X]
    STR R4, [0xFB]
    SBCI R4, 0x49
    AND R6, R7
L18:
    CMP R4, R6
    JSR SUB2
    JMP L27
    SHLI R3, 0xB8
    JMP L18
    CMP R5, R5
    STR R4, [0x7C+X]
    JMP L33
L19:
    ROL R2, R0
    ADD R0, R3
    JSR SUB3
    ORI R0, -63
    ADD R4, R6
    BRA L14
    LDR R1, [0xE6]
    CMPI R6, 0x85
L20:
    XOR R0, R2
    BRA L24
    SUB R6, R5
    LDR R4, [0x08]
    ADD R7, R0
    BCC L22
    SHRI R6, -48
    SUBI R1, 0x47
    WFI
    ORI R7, 0xE8
L21:
    STR R7, [0x90+X]
    JMP L9
    LDR R2, [0x13]
    CMPI R4, -4
    ADCI R7, 0x40
    ROR R4, R1
    ADDI R7, 0xE5
    OR R2, R6
    JMP L25
    ADDI R5, 0xA2
L22:
    SUBI R6, 0x80
    CMPI R3, -123
    ADC R1, R1
    LDR R0, [0x90+X]
    JSR SUB0
    CMPI R4, -38
    SBCI R7, 0x56
    ROR R2, R7
    LDR R0, [0x48+X]
    MOVI R2, 0x9F
    SUB R2, R0
    SBCI R6, 0x36
L23:
    ANDI R1, -17
    AND R2, R6
    ADCI R3, -1
    JMP L9
    JSR SUB1
    SHL R7, R1
    STR R5, [0xF2]
    OR R7, R6
    CMPI R2, 0xE9
    BNE L27
    ROR R2, R4
L24:
    BNE L24
    SBC R2, R0
    LDR R0, [0xD1]
    LDR R2, [0x3A]
    LDR R2, [0x3E]
    STR R5, [0x8C+X]
    SHL R7, R5
    SHR R3, R5
    MOVI R5, 0xB7
    STR R5, [0xAE]
    AND R4, R2
    SHL R3, R5
    STR R3, [0x90]
    SUBI R7, 0xAB
L25:
    STR R2, [0xE2+X]
    WFI
    XOR R6, R4
    XOR R6, R3
    JSR SUB2
    CMPI R1, 0xDC
    STR R6, [0xB9]
    OR R5, R6
    MOVI R1, -75
    ADDI R5, 0x20
    LDR R2, [0x29]
    XOR R4, R3
L26:
    ROR R5, R7
    STR R3, [0xE1]
    SHLI R6, 0x73
    ANDI R3, -16
    STR R1, [0xDC+X]
    OR R6, R0
    CMPI R4, -18
    XORI R4, 0xDF
L27:
    ROR R1, R1
    ORI R1, -109
    CMP R6, R1
    STR R5, [0xD6+X]
    BNE L27
    XOR R1, R0
    LDR R0, [0x7A+X]
    LDR R1, [0x5C]
    CMP R6, R4
    SHLI R3, 0x67
L28:
    SHR R2, R5
    LDR R5, [0xA1]
    STR R3, [0xE4]
    XOR R4, R3
    SUBI R1, -121
    SHLI R6, -108
    SUB R0, R5
    MOVI R0, 0x79
    SUBI R4, 0x80
    ORI R1, 0x6A
    CMP R2, R2
    ROR R3, R3
L29:
    LDR R3, [0x59+X]
    LDR R6, [0xD9+X]
    LDR R4, [0xE2]
    SHLI R7, 0xFA
    SUB R4, R6
    LDR R3, [0xC7+X]
    STR R7, [0xB1+X]
    SUBI R1, 0xD6
    SHRI R5, -14
    ANDI R7, 0x4D
    BCC L29
    MOVI R3, 0x2F
    STR R4, [0x93]
    MOVI R4, -119
L30:
    ORI R6, 0xF5
    ANDI R3, 0xC5
    STR R5, [0x52]
    SUBI R6, -60
    XOR R5, R1
    STR R7, [0x67]
    ROL R2, R1
    SHL R1, R6
L31:
    LDR R5, [0xCB]
    CMP R4, R5
    AND R1, R3
    JMP L30
    ORI R2, 0x87
    LDR R3, [0x72]
    AND R5, R5
    BEQ L28
    STR R3, [0xEA]
    SUBI R2, 0x15
    LDR R4, [0x44+X]
    XORI R6, -126
    STR R4, [0x97+X]
    XORI R2, 0x17
L32:
    ROL R0, R3
    STR R2, [0x6A+X]
    BPL L37
    SHLI R5, 0x67
    SBC R1, R7
    ADCI R5, 0x52
    ADC R1, R2
    ROR R1, R6
L33:
    SHRI R7, -34
    ADD R1, R4
    LDR R6, [0x57+X]
    OR R5, R5
    MOV R3, R6
    SHL R7, R5
    LDR R7, [0xE7+X]
    ADD R5, R3
    XOR R6, R1
    ADCI R3, -38
    XOR R0, R5
    CMP R4, R6
    LDR R3, [0xDA+X]
L34:
    CMPI R1, 0x91
    BMI L38
    SHL R2, R4
    NOP
    SHL R4, R1
    ADC R7, R3
    STR R6, [0x0A]
    CMP R0, R0
    STR R7, [0x06]
    ROL R4, R4
    STR R7, [0x99+X]
    STR R2, [0x9E]
    LDR R1, [0xCF+X]
L35:
    ROL R3, R3
    ROR R6, R2
    LDR R1, [0x9A+X]
    ADDI R7, -9
    ADCI R6, 0xAA
    LDR R6, [0xDE]
    ADDI R5, 0x9C
    CMPI R4, 0x69
    CMPI R6, 0xF4
    STR R5, [0x1D]
    LDR R0, [0xCD+X]
    SUB R5, R1
    LDR R7, [0x82+X]
L36:
    BMI L36
    ORI R6, -47
    BCC L35
    SBCI R0, 0xD3
    STR R1, [0xCD]
    SHLI R6, 0x66
    SHLI R2, 0x0B
    ROL R1, R2
    ADCI R1, 0x35
    LDR R4, [0x41]
    BCC L33
L37:
    ROL R6, R7
    ADDI R4, 0x09
    LDR R5, [0xA2]
    LDR R3, [0x3E]
    ADC R3, R6
    SBC R5, R3
    STR R1, [0xAA]
    LDR R3, [0x6A]
    LDR R6, [0x00]
L38:
    LDR R3, [0x4A+X]
    STR R1, [0x80]
    ORI R3, 0x66
    BMI L39
    XOR R4, R0
    SHRI R4, 0x66
    ORI R1, 0x36
    ORI R3, -33
    STR R1, [0x0C]
    OR R5, R2
    ADD R1, R5
    LDR R1, [0xD0]
L39:
    LDR R0, [0xF9]
    SUBI R7, -1
    SUB R5, R7
    SHL R3, R7
    ORI R0, 0xA8
    CMPI R0, 0xF1
    AND R2, R3
    JSR SUB0
    LDR R2, [0x59+X]
    STR R4, [0xA0]
HALTX:
    HLT
L39X:
    JMP L0
    HLT
