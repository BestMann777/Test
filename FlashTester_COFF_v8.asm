format MS COFF

include 'win32a.inc'

public WinMainCRTStartup

extrn '_CreateFileA@28' as CreateFileA:dword
extrn '_CloseHandle@4' as CloseHandle:dword
extrn '_ReadFile@20' as ReadFile:dword
extrn '_WriteFile@20' as WriteFile:dword
extrn '_SetFilePointerEx@20' as SetFilePointerEx:dword
extrn '_FlushFileBuffers@4' as FlushFileBuffers:dword
extrn '_DeviceIoControl@32' as DeviceIoControl:dword
extrn '_GetLogicalDrives@0' as GetLogicalDrives:dword
extrn '_GetDriveTypeA@4' as GetDriveTypeA:dword
extrn '_VirtualAlloc@16' as VirtualAlloc:dword
extrn '_VirtualFree@12' as VirtualFree:dword
extrn '_GetLastError@0' as GetLastError:dword
extrn '_GetStdHandle@4' as GetStdHandle:dword
extrn '_ReadConsoleA@20' as ReadConsoleA:dword
extrn '_SetConsoleOutputCP@4' as SetConsoleOutputCP:dword
extrn '_SetConsoleCP@4' as SetConsoleCP:dword
extrn '_QueryPerformanceCounter@4' as QueryPerformanceCounter:dword
extrn '_QueryPerformanceFrequency@4' as QueryPerformanceFrequency:dword
extrn '_ExitProcess@4' as ExitProcess:dword
extrn '_IsUserAnAdmin@0' as IsUserAnAdmin:dword
extrn '_SystemFunction036@8' as SystemFunction036:dword

; ============================================================================
; КОНСТАНТЫ ТЕСТА И WINDOWS API
; ============================================================================
BLOCK_SIZE                      = 4096
SECTOR_SIZE                     = 512

PROBE_SIZE                      = 64 * 1024               ; 64 КиБ
PROBE_BLOCKS                    = PROBE_SIZE / BLOCK_SIZE ; 16 блоков по 4 КиБ

IO_SIZE                         = 8 * 1024 * 1024         ; 8 МиБ
IO_BLOCKS                       = IO_SIZE / BLOCK_SIZE    ; 2048 блоков по 4 КиБ

CHUNK_SIZE                      = 128 * 1024 * 1024       ; 128 МиБ (базовый шаг)
CHUNK_BLOCKS                    = CHUNK_SIZE / BLOCK_SIZE ; 32768 блоков по 4 КиБ

GIB_BLOCKS                      = (1024 * 1024 * 1024) / BLOCK_SIZE ; 262144 блока = 1 ГиБ
MBR_OFFSET_MIB                  = 1
SLOW_SPEED_PCT                  = 60                      ; 60% от базовой скорости
TAIL_CHUNKS                     = 10

MAX_DRIVES                      = 32
MAX_STABLE_ANCHORS              = 64
MAX_RECENT_ANCHORS              = 16
MAX_EXP_POINTS                  = 32
MAX_CHUNKS                      = 16384                   ; До 2 ТиБ (при чанках 128 МиБ)
FMT_BUFFER_SIZE                 = 2048                    ; Размер всех текущих буферов форматирования
MBR_MAX_BLOCKS                  = 536870912               ; 2 ТиБ в блоках по 4 КиБ

MODE_ALL                        = 1
MODE_EDGES                      = 2

STD_INPUT_HANDLE                = -10
STD_OUTPUT_HANDLE               = -11
INVALID_HANDLE_VALUE            = -1
GENERIC_READ                    = 0x80000000
GENERIC_WRITE                   = 0x40000000
FILE_SHARE_READ                 = 0x00000001
FILE_SHARE_WRITE                = 0x00000002
OPEN_EXISTING                   = 3
FILE_BEGIN                      = 0

FILE_FLAG_NO_BUFFERING          = 0x20000000
FILE_FLAG_WRITE_THROUGH         = 0x80000000
FILE_FLAG_BACKUP_SEMANTICS      = 0x02000000
WIN_ERROR_INVALID_FUNCTION      = 1
WIN_ERROR_NOT_SUPPORTED         = 50

MEM_COMMIT                      = 0x00001000
MEM_RESERVE                     = 0x00002000
MEM_RELEASE                     = 0x00008000
PAGE_READWRITE                  = 0x04

DRIVE_REMOVABLE                 = 2
DRIVE_FIXED                     = 3

IOCTL_DISK_GET_LENGTH_INFO      = 0x0007405C
IOCTL_DISK_GET_DRIVE_GEOMETRY_EX= 0x000700A0
IOCTL_DISK_DELETE_DRIVE_LAYOUT  = 0x0007C100
IOCTL_DISK_UPDATE_PROPERTIES    = 0x00070140
IOCTL_STORAGE_QUERY_PROPERTY    = 0x002D1400
IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x002D1080
FSCTL_LOCK_VOLUME               = 0x00090018
FSCTL_DISMOUNT_VOLUME           = 0x00090020

; ============================================================================
; СТРУКТУРЫ ДАННЫХ
; ============================================================================
struct DRIVE_INFO
    phys_index      dd ?        ; Номер PhysicalDrive (0..31)
    size_low        dd ?        ; Заявленный размер в байтах (младшие 32 бита)
    size_high       dd ?        ; Заявленный размер в байтах (старшие 32 бита)
    usable_blocks   dd ?        ; Число полных 4-КиБ блоков
    bus_type        dd ?        ; 7 = USB, 12 = SD, 13 = MMC
    is_removable    dd ?        ; 0 или 1
    letters_mask    dd ?        ; Битовая маска букв томов (бит 0 = A: ...)
    letters_str     rb 104      ; До 26 букв: 102 символа + завершающий NUL
    model           rb 128      ; Строка модели устройства
ends

struct ANCHOR_ITEM
    block_idx       dd ?        ; Смещение в 4-КиБ блоках
    block_len       dd ?        ; Длина пробы в 4-КиБ блоках (16 или 1)
ends

struct CHUNK_METRIC
    chunk_index     dd ?        ; Номер участкп (0..N-1)
    start_block     dd ?        ; Начальный 4-КиБ блок
    length_blocks   dd ?        ; Длина участка в 4-КиБ блоках
    w_speed_x10     dd ?        ; Скорость записи в 0.1 МиБ/с (145 = 14.5 МиБ/с)
    r_speed_x10     dd ?        ; Скорость чтения в 0.1 МиБ/с
    passed          dd ?        ; 1 = OK, 0 = СБОЙ
ends

; ============================================================================
; СЕКЦИЯ КОДА
; ============================================================================
section '.text' code readable executable

WinMainCRTStartup:
    xor     ebx, ebx                 ; код завершения по умолчанию — успех
    invoke  GetStdHandle, STD_OUTPUT_HANDLE
    mov     [g_StdOut], eax
    invoke  GetStdHandle, STD_INPUT_HANDLE
    mov     [g_StdIn], eax

    ; Включаем UTF-8 в консоли Windows
    invoke  SetConsoleOutputCP, 65001
    invoke  SetConsoleCP, 65001

    invoke  IsUserAnAdmin
    test    eax, eax
    jnz     .admin_ok
    stdcall UI_PrintSz, szErrNotAdmin
    mov     ebx, 1
    jmp     .wait_and_exit

.admin_ok:
    invoke  QueryPerformanceFrequency, g_QpcFreq
    test    eax, eax
    jnz     .qpc_ready
    stdcall UI_PrintSz, szErrQpc
    mov     ebx, 1
    jmp     .wait_and_exit

.qpc_ready:
    ; Сканируем подключенные USB-накопители
    stdcall Engine_ScanUsbDrives
    test    eax, eax
    jnz     .scan_result_nonzero
    stdcall UI_PrintSz, szErrNoDrives
    mov     ebx, 1
    jmp     .wait_and_exit

.scan_result_nonzero:
    cmp     eax, -1
    je      .scan_error
    jmp     .drives_found

.scan_error:
    mov     ebx, 1
    jmp     .wait_and_exit

.drives_found:
    stdcall Console_ChooseDrive
    cmp     eax, -1
    jne     .drive_selected
    stdcall UI_PrintSz, szCancelled
    xor     ebx, ebx
    jmp     .wait_and_exit

.drive_selected:
    mov     [g_SelectedIdx], eax
    imul    esi, eax, sizeof.DRIVE_INFO
    add     esi, g_Drives

    ; Блокируем тома, сбрасываем разметку и открываем PhysicalDrive
    stdcall Engine_OpenDrive, esi
    test    eax, eax
    jnz     .drive_opened
    mov     ebx, 1
    jmp     .wait_and_exit

.drive_opened:
    ; --- ЭТАП 1 ---
    stdcall Engine_RenewMarker
    ccall   UI_LogFmt, szNewMarker1, [g_MagicHigh], [g_MagicLow]

    stdcall Engine_RunStage1, esi
    mov     [g_RealLimitBlocks], eax
    test    eax, eax
    jnz     .stage1_ok
    mov     ebx, 1
    jmp     .cleanup

.stage1_ok:
    ; --- ВЫБОР РЕЖИМА ЭТАПА 2 ---
    stdcall Console_ChooseStage2Mode
    test    eax, eax
    jz      .skip_stage2

    mov     ebx, eax
    stdcall Engine_RenewMarker
    ccall   UI_LogFmt, szNewMarker2, [g_MagicHigh], [g_MagicLow]
    stdcall Engine_RunStage2, esi, [g_RealLimitBlocks], ebx
    test    eax, eax
    jz      .stage2_failed
    xor     ebx, ebx
    jmp     .cleanup
.stage2_failed:
    mov     ebx, 1
    jmp     .cleanup

.skip_stage2:
    xor     ebx, ebx
    stdcall UI_PrintSz, szStage2Skipped

.cleanup:
    stdcall Engine_CloseDrive
    stdcall UI_PrintSz, szFinalNote

.wait_and_exit:
    stdcall UI_PrintSz, szPressEnter
    stdcall Console_ReadLine
    invoke  ExitProcess, ebx


; ============================================================================
; СОБСТВЕННЫЙ ФОРМАТЕР И ВЫВОД ЧЕРЕЗ WINAPI (БЕЗ MSVCRT.DLL)
; ============================================================================

proc UI_Log, buf_ptr, buf_len
    cmp     [buf_len], 0
    jle     .done
    invoke  WriteFile, [g_StdOut], [buf_ptr], [buf_len], g_DummyWritten, 0
.done:
    ret
endp

proc UI_PrintSz uses edi, str_ptr
    mov     edi, [str_ptr]
    test    edi, edi
    jz      .done
    mov     edx, edi
.len_loop:
    cmp     byte [edi], 0
    lea     edi, [edi+1]
    jne     .len_loop
    dec     edi
    sub     edi, edx
    jz      .done
    stdcall UI_Log, edx, edi
.done:
    ret
endp

proc AsmFormatV uses ebx esi edi, dst_ptr, dst_cap, fmt_ptr, args_ptr
    locals
        pad_char    dd ?
        width       dd ?
        dst_end     dd ?
        num_buf     rb 32
    endl

    mov     edi, [dst_ptr]
    mov     ecx, [dst_cap]
    test    ecx, ecx
    jnz     .cap_nonzero
    mov     ecx, 1
.cap_nonzero:
    lea     eax, [edi + ecx - 1]
    mov     [dst_end], eax
    mov     ebx, [fmt_ptr]
    mov     esi, [args_ptr]

.fmt_loop:
    cmp     edi, [dst_end]
    jae     .fmt_done
    movzx   eax, byte [ebx]
    test    eax, eax
    jz      .fmt_done
    inc     ebx
    cmp     al, '%'
    jne     .store_char

    movzx   eax, byte [ebx]
    test    eax, eax
    jz      .fmt_done
    cmp     al, '%'
    jne     .parse_flags
    inc     ebx
.store_char:
    stosb
    jmp     .fmt_loop

.parse_flags:
    mov     [pad_char], ' '
    mov     [width], 0
    cmp     byte [ebx], '0'
    jne     .parse_width
    mov     [pad_char], '0'
    inc     ebx

.parse_width:
    xor     ecx, ecx
.width_loop:
    movzx   eax, byte [ebx]
    cmp     al, '0'
    jb      .check_spec
    cmp     al, '9'
    ja      .check_spec
    sub     al, '0'
    imul    ecx, 10
    add     ecx, eax
    inc     ebx
    jmp     .width_loop

.check_spec:
    mov     [width], ecx
    movzx   eax, byte [ebx]
    test    eax, eax
    jz      .fmt_done
    inc     ebx

    cmp     al, 'c'
    je      .spec_c
    cmp     al, 's'
    je      .spec_s
    cmp     al, 'u'
    je      .spec_u32
    cmp     al, 'U'
    je      .spec_u64
    cmp     al, 'X'
    je      .spec_x32
    cmp     al, 'I'
    je      .spec_x64
    jmp     .store_char

.spec_c:
    lodsd
    stosb
    jmp     .fmt_loop

.spec_s:
    lodsd
    mov     edx, eax
    test    edx, edx
    jz      .fmt_loop
.copy_s:
    cmp     edi, [dst_end]
    jae     .fmt_done
    mov     al, [edx]
    test    al, al
    jz      .fmt_loop
    stosb
    inc     edx
    jmp     .copy_s

.spec_u32:
    lodsd
    xor     edx, edx
    jmp     .format_dec

.spec_u64:
    lodsd
    mov     edx, eax
    lodsd
    xchg    eax, edx

.format_dec:
    push    ebx
    lea     ecx, [num_buf]
.dec_loop:
    push    ecx
    mov     ecx, 10
    test    edx, edx
    jz      .div32
    push    eax
    mov     eax, edx
    xor     edx, edx
    div     ecx
    mov     ebx, eax
    pop     eax
    div     ecx
    jmp     .div_store
.div32:
    xor     edx, edx
    div     ecx
    xor     ebx, ebx
.div_store:
    pop     ecx
    add     dl, '0'
    mov     [ecx], dl
    inc     ecx
    mov     edx, ebx
    mov     ebx, eax
    or      ebx, edx
    jnz     .dec_loop
    jmp     .emit_num

.spec_x32:
    lodsd
    xor     edx, edx
    jmp     .format_hex

.spec_x64:
    lodsd
    mov     edx, eax
    lodsd
    xchg    eax, edx

.format_hex:
    push    ebx
    lea     ecx, [num_buf]
    mov     ebx, eax
.hex_loop:
    mov     al, bl
    and     al, 0x0F
    cmp     al, 10
    sbb     al, 0x69
    das
    mov     [ecx], al
    inc     ecx
    shrd    ebx, edx, 4
    shr     edx, 4
    mov     eax, ebx
    or      eax, edx
    jnz     .hex_loop

.emit_num:
    lea     edx, [num_buf]
    mov     eax, ecx
    sub     eax, edx
    mov     ebx, [width]
    sub     ebx, eax
    jle     .emit_digits
    mov     al, byte [pad_char]
.pad_loop:
    cmp     edi, [dst_end]
    jae     .num_truncated
    stosb
    dec     ebx
    jnz     .pad_loop

.emit_digits:
    cmp     edi, [dst_end]
    jae     .num_truncated
    dec     ecx
    mov     al, [ecx]
    stosb
    cmp     ecx, edx
    ja      .emit_digits

    pop     ebx
    jmp     .fmt_loop

.num_truncated:
    pop     ebx
    jmp     .fmt_done

.fmt_done:
    mov     byte [edi], 0
    mov     eax, edi
    sub     eax, [dst_ptr]
    ret
endp

UI_LogFmt:
    mov     edx, [esp+4]
    lea     ecx, [esp+8]
    stdcall AsmFormatV, g_LogBuf, FMT_BUFFER_SIZE, edx, ecx
    stdcall UI_Log, g_LogBuf, eax
    ret

StrFormat:
    mov     eax, [esp+4]
    mov     edx, [esp+8]
    lea     ecx, [esp+12]
    stdcall AsmFormatV, eax, FMT_BUFFER_SIZE, edx, ecx
    ret


; ============================================================================
; КОНСОЛЬНЫЙ ВВОД И ДИАЛОГИ ВЫБОРА
; ============================================================================

proc Console_ReadLine uses esi edi
    mov     [g_DummyRead], 0
    invoke  ReadConsoleA, [g_StdIn], g_InputBuf, 63, g_DummyRead, 0
    test    eax, eax
    jnz     .read_ok
    mov     byte [g_InputBuf], 0
    ret
.read_ok:
    mov     ecx, [g_DummyRead]
    cmp     ecx, 63
    jbe     .set_null
    mov     ecx, 63
.set_null:
    mov     byte [g_InputBuf + ecx], 0

    mov     esi, g_InputBuf
.skip_leading:
    mov     al, [esi]
    cmp     al, ' '
    je      .skip_one_leading
    cmp     al, 9
    jne     .copy_to_start
.skip_one_leading:
    inc     esi
    jmp     .skip_leading

.copy_to_start:
    mov     edi, g_InputBuf
.copy_loop:
    mov     al, [esi]
    mov     [edi], al
    inc     esi
    inc     edi
    test    al, al
    jnz     .copy_loop

    cmp     edi, g_InputBuf + 1
    jbe     .done
    sub     edi, 2
.trim_trailing:
    cmp     edi, g_InputBuf
    jb      .done
    mov     al, [edi]
    cmp     al, 13
    je      .terminate
    cmp     al, 10
    je      .terminate
    cmp     al, ' '
    je      .terminate
    cmp     al, 9
    je      .terminate
    jmp     .done
.terminate:
    mov     byte [edi], 0
    cmp     edi, g_InputBuf
    je      .done
    dec     edi
    jmp     .trim_trailing
.done:
    ret
endp

proc Console_ChooseDrive uses ebx esi edi
    locals
        idx         dd ?
        gib_int     dd ?
        gib_frac    dd ?
    endl

    stdcall UI_PrintSz, szWarnBanner

    mov     [idx], 0
    mov     esi, g_Drives
.list_loop:
    mov     eax, [idx]
    cmp     eax, [g_DriveCount]
    jae     .ask_input

    stdcall BlockToGib3, [esi + DRIVE_INFO.usable_blocks]
    mov     [gib_int], eax
    mov     eax, edx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    mov     [gib_frac], eax

    mov     eax, [esi + DRIVE_INFO.usable_blocks]
    mov     edx, eax
    shl     eax, 3
    shr     edx, 29

    lea     ecx, [esi + DRIVE_INFO.letters_str]
    lea     edi, [esi + DRIVE_INFO.model]
    mov     ebx, [idx]
    inc     ebx

    ccall   UI_LogFmt, szDriveItem, ebx, [esi + DRIVE_INFO.phys_index], \
            edi, [gib_int], [gib_frac], \
            [esi + DRIVE_INFO.size_low], [esi + DRIVE_INFO.size_high], \
            eax, edx, ecx

    add     esi, sizeof.DRIVE_INFO
    inc     [idx]
    jmp     .list_loop

.ask_input:
    ccall   UI_LogFmt, szPromptDrive, [g_DriveCount]
    stdcall Console_ReadLine

    cmp     byte [g_InputBuf], 0
    je      .cancel

    xor     eax, eax
    xor     edx, edx
    mov     esi, g_InputBuf
.parse_loop:
    movzx   ecx, byte [esi]
    test    ecx, ecx
    jz      .check_range
    cmp     cl, '0'
    jb      .invalid
    cmp     cl, '9'
    ja      .invalid
    sub     cl, '0'
    cmp     edx, 2
    jae     .invalid
    imul    eax, 10
    add     eax, ecx
    inc     edx
    inc     esi
    jmp     .parse_loop

.check_range:
    cmp     eax, 1
    jb      .invalid
    cmp     eax, [g_DriveCount]
    ja      .invalid
    dec     eax
    ret

.invalid:
    stdcall UI_PrintSz, szInvalidDrive
.cancel:
    mov     eax, -1
    ret
endp

proc Console_ChooseStage2Mode
    ccall   UI_LogFmt, szPromptMode, TAIL_CHUNKS
    stdcall Console_ReadLine
    cmp     word [g_InputBuf], 0x0031
    je      .mode_all
    cmp     word [g_InputBuf], 0x0032
    je      .mode_edges
    xor     eax, eax
    ret
.mode_all:
    mov     eax, MODE_ALL
    ret
.mode_edges:
    mov     eax, MODE_EDGES
    ret
endp


; ============================================================================
; ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ПЕРЕВОДА ВЕЛИЧИН И БУФЕРОВ
; ============================================================================

proc Engine_RenewMarker
    invoke  SystemFunction036, g_MagicLow, 8
    test    eax, eax
    jnz     .done
    rdtsc
    xor     [g_MagicLow], eax
    xor     [g_MagicHigh], edx
.done:
    ret
endp

proc BlockToByte64, blocks
    mov     eax, [blocks]
    mov     edx, eax
    shl     eax, 12
    shr     edx, 20
    ret
endp

proc BlockToGib3, blocks
    mov     eax, [blocks]
    mov     edx, eax
    shr     eax, 18
    and     edx, 0x3FFFF
    imul    edx, edx, 125
    shr     edx, 15
    ret
endp

proc BlockToGib6, blocks
    mov     eax, [blocks]
    mov     edx, eax
    shr     eax, 18
    and     edx, 0x3FFFF
    imul    edx, edx, 15625
    shr     edx, 12
    ret
endp

BlocksToMbrPartMib:
    cmp     eax, MBR_MAX_BLOCKS
    jbe     .limit_ok
    mov     eax, MBR_MAX_BLOCKS
.limit_ok:
    shr     eax, 8
    sub     eax, MBR_OFFSET_MIB
    jns     .done
    xor     eax, eax
.done:
    ret

proc InitWriteTemplate uses edi, buf_ptr, size_bytes
    mov     edi, [buf_ptr]
    mov     ecx, [size_bytes]
    shr     ecx, 3
    xor     edx, edx
    mov     eax, 0xA55AA55A
.loop:
    xor     eax, edx
    stosd
    xor     eax, edx
    stosd
    inc     edx
    loop    .loop
    ret
endp

proc StampOffsets uses esi edi, buf_ptr, base_block, num_blocks
    mov     edi, [buf_ptr]
    mov     esi, [base_block]
    mov     ecx, [num_blocks]
    test    ecx, ecx
    jz      .done
.loop:
    mov     eax, [g_MagicLow]
    mov     edx, [g_MagicHigh]
    mov     [edi], eax
    mov     [edi+4], edx

    mov     eax, esi
    mov     edx, esi
    shl     eax, 12
    shr     edx, 20
    mov     [edi+8], eax
    mov     [edi+12], edx

    add     edi, BLOCK_SIZE
    inc     esi
    dec     ecx
    jnz     .loop
.done:
    ret
endp

proc VerifyBufferMarkers uses ebx esi edi, buf_ptr, base_block, num_blocks
    mov     edi, [buf_ptr]
    mov     esi, [base_block]
    mov     ecx, [num_blocks]
    test    ecx, ecx
    jz      .ok

.loop:
    mov     eax, [g_MagicLow]
    cmp     [edi], eax
    jne     .mismatch
    mov     edx, [g_MagicHigh]
    cmp     [edi+4], edx
    jne     .mismatch

    mov     eax, esi
    mov     edx, esi
    shl     eax, 12
    shr     edx, 20
    cmp     [edi+8], eax
    jne     .mismatch
    cmp     [edi+12], edx
    jne     .mismatch

    add     edi, BLOCK_SIZE
    inc     esi
    dec     ecx
    jnz     .loop

.ok:
    mov     eax, 1
    ret

.mismatch:
    mov     [g_BadBlock], esi
    stdcall ExplainMismatch, edi
    xor     eax, eax
    ret
endp

proc ExplainMismatch uses ebx esi edi, buf16
    mov     esi, [buf16]

    xor     eax, eax
    or      eax, [esi]
    or      eax, [esi+4]
    or      eax, [esi+8]
    or      eax, [esi+12]
    jnz     .check_ff
    ccall   StrFormat, g_MismatchStr, szMismatchZero
    ret

.check_ff:
    mov     eax, 0xFFFFFFFF
    and     eax, [esi]
    and     eax, [esi+4]
    and     eax, [esi+8]
    and     eax, [esi+12]
    inc     eax
    jz      .is_ff
    jmp     .check_loopback
.is_ff:
    ccall   StrFormat, g_MismatchStr, szMismatchFF
    ret

.check_loopback:
    mov     eax, [g_MagicLow]
    cmp     [esi], eax
    jne     .foreign
    mov     edx, [g_MagicHigh]
    cmp     [esi+4], edx
    jne     .foreign

    mov     eax, [esi+8]
    mov     edx, [esi+12]
    mov     ebx, eax
    mov     ecx, edx
    shrd    ebx, ecx, 12
    stdcall BlockToGib3, ebx
    ccall   StrFormat, g_MismatchStr, szMismatchLoop, [esi+8], [esi+12], eax, edx
    ret

.foreign:
    mov     ecx, 8
    lea     ebx, [esi+7]
.dump_loop:
    movzx   eax, byte [ebx]
    push    eax
    dec     ebx
    loop    .dump_loop
    push    szMismatchForeign
    push    g_MismatchStr
    call    StrFormat
    add     esp, 40
    ret
endp


; ============================================================================
; НИЗКОУРОВНЕВОЕ ЧТЕНИЕ / ЗАПИСЬ ДИСКА
; ============================================================================

proc RawWrite, start_block, buf_ptr, num_blocks
    mov     eax, [WriteFile]
    jmp     RawIoCommon
endp

proc RawRead, start_block, buf_ptr, num_blocks
    mov     eax, [ReadFile]
RawIoCommon:
    push    ebx esi
    mov     esi, eax
    mov     ebx, [num_blocks]
    shl     ebx, 12

    stdcall BlockToByte64, [start_block]
    invoke  SetFilePointerEx, [g_DiskHandle], eax, edx, g_NewFilePos, FILE_BEGIN
    test    eax, eax
    jz      .io_err

    stdcall esi, [g_DiskHandle], [buf_ptr], ebx, g_BytesTransferred, 0
    test    eax, eax
    jz      .io_err

    cmp     [g_BytesTransferred], ebx
    jne     .io_err

    mov     eax, 1
    jmp     .done
.io_err:
    xor     eax, eax
.done:
    pop     esi ebx
    ret
endp

proc FlushDevice
    invoke  FlushFileBuffers, [g_DiskHandle]
    test    eax, eax
    jnz     .ok
    invoke  GetLastError
    mov     [g_LastError], eax
    cmp     eax, WIN_ERROR_INVALID_FUNCTION
    je      .ok
    cmp     eax, WIN_ERROR_NOT_SUPPORTED
    je      .ok
    xor     eax, eax
    ret
.ok:
    mov     eax, 1
    ret
endp


; ============================================================================
; ПОИСК И ОТКРЫТИЕ USB-НАКОПИТЕЛЕЙ (ENGINE)
; ============================================================================

proc SetPhysDrivePath, idx
    mov     eax, [idx]
    cmp     eax, 10
    jb      .single_digit
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     al, '0'
    add     dl, '0'
    mov     byte [g_PhysPath + 17], al
    mov     byte [g_PhysPath + 18], dl
    mov     byte [g_PhysPath + 19], 0
    ret
.single_digit:
    add     al, '0'
    mov     byte [g_PhysPath + 17], al
    mov     byte [g_PhysPath + 18], 0
    ret
endp

proc ExtractDescString uses esi edi, base_ptr, offset_val, dst_ptr, max_len
    locals
        remaining   dd ?
    endl
    mov     edi, [dst_ptr]
    cmp     [max_len], 0
    je      .done
    mov     byte [edi], 0
    mov     eax, [offset_val]
    test    eax, eax
    jz      .done
    mov     ecx, dword [g_DescBuf + 4]
    cmp     ecx, [g_BytesReturned]
    jbe     .desc_bound_ready
    mov     ecx, [g_BytesReturned]
.desc_bound_ready:
    cmp     ecx, 1024
    jbe     .bound_ready
    mov     ecx, 1024
.bound_ready:
    cmp     eax, ecx
    jae     .done
    sub     ecx, eax
    mov     [remaining], ecx

    mov     esi, [base_ptr]
    add     esi, eax
.skip_lead:
    cmp     [remaining], 0
    je      .done
    mov     al, [esi]
    cmp     al, ' '
    jne     .copy
    inc     esi
    dec     [remaining]
    jmp     .skip_lead

.copy:
    mov     ecx, [max_len]
    dec     ecx
    xor     edx, edx
.copy_loop:
    test    ecx, ecx
    jz      .finish
    cmp     [remaining], 0
    je      .finish
    mov     al, [esi]
    test    al, al
    jz      .finish
    mov     [edi], al
    cmp     al, ' '
    je      .next_ch
    lea     edx, [edi + 1]
.next_ch:
    inc     esi
    inc     edi
    dec     ecx
    dec     [remaining]
    jmp     .copy_loop

.finish:
    mov     byte [edi], 0
    test    edx, edx
    jz      .trim_all
    mov     byte [edx], 0
    jmp     .done
.trim_all:
    mov     edi, [dst_ptr]
    mov     byte [edi], 0
.done:
    ret
endp

proc AppendModelPart uses esi edi, dst_ptr, part_ptr, max_len
    mov     esi, [part_ptr]
    cmp     byte [esi], 0
    je      .done

    mov     edi, [dst_ptr]
    mov     edx, [max_len]
    test    edx, edx
    jz      .done
    dec     edx
    add     edx, edi
.find_end:
    cmp     edi, edx
    jae     .done
    cmp     byte [edi], 0
    je      .at_end
    inc     edi
    jmp     .find_end
.at_end:
    cmp     edi, [dst_ptr]
    je      .copy_part
    cmp     edi, edx
    jae     .done
    mov     byte [edi], ' '
    inc     edi
.copy_part:
.copy_loop:
    cmp     edi, edx
    jae     .terminate
    mov     al, [esi]
    test    al, al
    jz      .terminate
    mov     [edi], al
    inc     esi
    inc     edi
    jmp     .copy_loop
.terminate:
    mov     byte [edi], 0
.done:
    ret
endp

proc Engine_ScanUsbDrives uses ebx esi edi
    locals
        bitmask     dd ?
        hVol        dd ?
        hDisk       dd ?
        drive_type  dd ?
    endl

    mov     [g_UnmappedVolumeFlag], 0
    mov     byte [g_UnmappedVolumeLetter], 0
    mov     edi, g_DiskLetterMask
    xor     eax, eax
    mov     ecx, 32
    rep     stosd
    mov     edi, g_DiskRemovableMap
    mov     ecx, 32
    rep     stosd
    mov     [g_DriveCount], 0

    invoke  GetLogicalDrives
    mov     [bitmask], eax

    xor     ebx, ebx
.letter_loop:
    cmp     ebx, 26
    jae     .scan_phys

    mov     eax, 1
    mov     ecx, ebx
    shl     eax, cl
    test    [bitmask], eax
    jz      .next_letter

    lea     eax, [ebx + 'A']
    mov     byte [g_RootPath], al
    mov     byte [g_VolPath + 4], al

    invoke  GetDriveTypeA, g_RootPath
    mov     [drive_type], eax
    xor     esi, esi
    cmp     eax, DRIVE_REMOVABLE
    jne     .open_vol
    inc     esi

.open_vol:
    invoke  CreateFileA, g_VolPath, 0, FILE_SHARE_READ or FILE_SHARE_WRITE, \
            0, OPEN_EXISTING, 0, 0
    cmp     eax, INVALID_HANDLE_VALUE
    jne     .volume_opened

    invoke  CreateFileA, g_VolPath, 0, FILE_SHARE_READ or FILE_SHARE_WRITE, \
            0, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0
    cmp     eax, INVALID_HANDLE_VALUE
    je      .check_unmapped_volume
    invoke  CloseHandle, eax
    jmp     .next_letter

.check_unmapped_volume:
    cmp     [drive_type], DRIVE_REMOVABLE
    je      .unmapped_volume
    cmp     [drive_type], DRIVE_FIXED
    jne     .next_letter
.unmapped_volume:
    cmp     [g_UnmappedVolumeFlag], 0
    jne     .next_letter
    mov     [g_UnmappedVolumeFlag], 1
    lea     eax, [ebx + 'A']
    mov     [g_UnmappedVolumeLetter], al
    jmp     .next_letter
.volume_opened:
    mov     [hVol], eax

    invoke  DeviceIoControl, [hVol], IOCTL_STORAGE_GET_DEVICE_NUMBER, 0, 0, \
            g_SdnBuf, 12, g_BytesReturned, 0
    test    eax, eax
    jz      .close_vol

    mov     edx, [g_SdnDeviceNumber]
    cmp     edx, 32
    jae     .close_vol

    mov     eax, 1
    mov     ecx, ebx
    shl     eax, cl
    or      [g_DiskLetterMask + edx*4], eax
    test    esi, esi
    jz      .close_vol
    mov     dword [g_DiskRemovableMap + edx*4], 1

.close_vol:
    invoke  CloseHandle, [hVol]
.next_letter:
    inc     ebx
    jmp     .letter_loop

.scan_phys:
    cmp     [g_UnmappedVolumeFlag], 0
    je      .scan_phys_continue
    movzx   eax, byte [g_UnmappedVolumeLetter]
    ccall   UI_LogFmt, szErrUnmappedVol, eax
    mov     eax, -1
    ret

.scan_phys_continue:
    xor     ebx, ebx
.phys_loop:
    cmp     ebx, 32
    jae     .scan_done

    stdcall SetPhysDrivePath, ebx
    invoke  CreateFileA, g_PhysPath, GENERIC_READ, \
            FILE_SHARE_READ or FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0
    cmp     eax, INVALID_HANDLE_VALUE
    jne     .got_phys_handle
    invoke  CreateFileA, g_PhysPath, 0, \
            FILE_SHARE_READ or FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0
    cmp     eax, INVALID_HANDLE_VALUE
    je      .next_phys

.got_phys_handle:
    mov     [hDisk], eax
    mov     [g_DiskSizeLow], 0
    mov     [g_DiskSizeHigh], 0

    invoke  DeviceIoControl, [hDisk], IOCTL_DISK_GET_LENGTH_INFO, 0, 0, \
            g_DiskSizeLow, 8, g_BytesReturned, 0
    test    eax, eax
    jnz     .check_size

    invoke  DeviceIoControl, [hDisk], IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, 0, 0, \
            g_GeomBuf, 256, g_BytesReturned, 0
    test    eax, eax
    jz      .close_phys
    mov     eax, dword [g_GeomBuf + 24]
    mov     edx, dword [g_GeomBuf + 28]
    mov     [g_DiskSizeLow], eax
    mov     [g_DiskSizeHigh], edx

.check_size:
    mov     eax, [g_DiskSizeLow]
    or      eax, [g_DiskSizeHigh]
    jz      .close_phys

    mov     eax, [g_DiskSizeLow]
    mov     edx, [g_DiskSizeHigh]
    shrd    eax, edx, 12
    cmp     eax, PROBE_BLOCKS
    jb      .close_phys

    cmp     dword [g_DiskSizeHigh], 0x1000
    jae     .address_limit

    mov     [g_SpqBuf + 0], 0
    mov     [g_SpqBuf + 4], 0
    mov     [g_SpqBuf + 8], 0
    mov     edi, g_DescBuf
    xor     eax, eax
    mov     ecx, 1024 / 4
    rep     stosd
    invoke  DeviceIoControl, [hDisk], IOCTL_STORAGE_QUERY_PROPERTY, \
            g_SpqBuf, 12, g_DescBuf, 1024, g_BytesReturned, 0
    test    eax, eax
    jz      .close_phys
    cmp     [g_BytesReturned], 36
    jb      .close_phys
    cmp     dword [g_DescBuf + 4], 36
    jb      .close_phys

    mov     ecx, dword [g_DescBuf + 28]
    movzx   edx, byte [g_DescBuf + 10]
    or      edx, [g_DiskRemovableMap + ebx*4]

    cmp     ecx, 7
    je      .is_usb
    cmp     ecx, 12
    je      .is_usb
    cmp     ecx, 13
    je      .is_usb
    test    edx, edx
    jz      .close_phys

.is_usb:
    mov     edi, [g_DriveCount]
    imul    edi, sizeof.DRIVE_INFO
    add     edi, g_Drives

    mov     [edi + DRIVE_INFO.phys_index], ebx
    mov     eax, [g_DiskSizeLow]
    mov     edx, [g_DiskSizeHigh]
    mov     [edi + DRIVE_INFO.size_low], eax
    mov     [edi + DRIVE_INFO.size_high], edx
    shrd    eax, edx, 12
    mov     [edi + DRIVE_INFO.usable_blocks], eax

    mov     eax, dword [g_DescBuf + 28]
    mov     [edi + DRIVE_INFO.bus_type], eax
    movzx   eax, byte [g_DescBuf + 10]
    or      eax, [g_DiskRemovableMap + ebx*4]
    mov     [edi + DRIVE_INFO.is_removable], eax

    mov     eax, [g_DiskLetterMask + ebx*4]
    mov     [edi + DRIVE_INFO.letters_mask], eax

    stdcall ExtractDescString, g_DescBuf, dword [g_DescBuf + 12], g_VendorStr, 64
    stdcall ExtractDescString, g_DescBuf, dword [g_DescBuf + 16], g_ProductStr, 64
    stdcall ExtractDescString, g_DescBuf, dword [g_DescBuf + 20], g_RevStr, 32

    lea     esi, [edi + DRIVE_INFO.model]
    mov     byte [esi], 0
    stdcall AppendModelPart, esi, g_VendorStr, 128
    stdcall AppendModelPart, esi, g_ProductStr, 128
    stdcall AppendModelPart, esi, g_RevStr, 128
    cmp     byte [esi], 0
    jne     .build_letters
    stdcall AppendModelPart, esi, szDefaultModel, 128

.build_letters:
    mov     eax, [edi + DRIVE_INFO.letters_mask]
    test    eax, eax
    jnz     .format_letters
    lea     esi, [edi + DRIVE_INFO.letters_str]
    mov     byte [esi], 0
    stdcall AppendModelPart, esi, szNoVolumes, 104
    jmp     .inc_drive

.format_letters:
    lea     esi, [edi + DRIVE_INFO.letters_str]
    xor     ecx, ecx
.fmt_let_loop:
    cmp     ecx, 26
    jae     .fmt_let_done
    mov     eax, 1
    shl     eax, cl
    test    [edi + DRIVE_INFO.letters_mask], eax
    jz      .fmt_let_next

    lea     eax, [edi + DRIVE_INFO.letters_str]
    cmp     esi, eax
    je      .put_let
    mov     byte [esi], ','
    mov     byte [esi+1], ' '
    add     esi, 2
.put_let:
    mov     al, cl
    add     al, 'A'
    mov     byte [esi], al
    mov     byte [esi+1], ':'
    add     esi, 2

.fmt_let_next:
    inc     ecx
    jmp     .fmt_let_loop

.fmt_let_done:
    mov     byte [esi], 0

.inc_drive:
    inc     [g_DriveCount]

.close_phys:
    invoke  CloseHandle, [hDisk]
    jmp     .next_phys

.address_limit:
    ccall   UI_LogFmt, szErrAddressLimit, ebx
    jmp     .close_phys

.next_phys:
    inc     ebx
    jmp     .phys_loop

.scan_done:
    mov     eax, [g_DriveCount]
    ret
endp

proc Engine_OpenDrive uses ebx esi edi, drive_ptr
    mov     esi, [drive_ptr]
    mov     [g_LockedVolCount], 0
    mov     [g_DiskHandle], INVALID_HANDLE_VALUE

    xor     ebx, ebx
.vol_loop:
    cmp     ebx, 26
    jae     .open_phys
    mov     eax, 1
    mov     ecx, ebx
    shl     eax, cl
    test    [esi + DRIVE_INFO.letters_mask], eax
    jz      .next_vol

    lea     eax, [ebx + 'A']
    mov     byte [g_VolPath + 4], al
    invoke  CreateFileA, g_VolPath, GENERIC_READ or GENERIC_WRITE, \
            FILE_SHARE_READ or FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0
    cmp     eax, INVALID_HANDLE_VALUE
    jne     .vol_opened
    invoke  GetLastError
    lea     ecx, [ebx + 'A']
    ccall   UI_LogFmt, szErrOpenVol, ecx, eax
    jmp     .fail
.vol_opened:
    mov     edi, eax

    invoke  DeviceIoControl, edi, FSCTL_LOCK_VOLUME, 0, 0, 0, 0, g_BytesReturned, 0
    test    eax, eax
    jnz     .lock_ok
    invoke  CloseHandle, edi
    lea     eax, [ebx + 'A']
    ccall   UI_LogFmt, szErrLockVol, eax
    jmp     .fail

.lock_ok:
    mov     ecx, [g_LockedVolCount]
    mov     [g_LockedVolHandles + ecx*4], edi
    inc     [g_LockedVolCount]

    invoke  DeviceIoControl, edi, FSCTL_DISMOUNT_VOLUME, 0, 0, 0, 0, g_BytesReturned, 0
    test    eax, eax
    jnz     .next_vol
    lea     eax, [ebx + 'A']
    ccall   UI_LogFmt, szErrDismountVol, eax
    jmp     .fail

.next_vol:
    inc     ebx
    jmp     .vol_loop

.open_phys:
    stdcall SetPhysDrivePath, [esi + DRIVE_INFO.phys_index]
    invoke  CreateFileA, g_PhysPath, GENERIC_READ or GENERIC_WRITE, \
            FILE_SHARE_READ or FILE_SHARE_WRITE, 0, OPEN_EXISTING, \
            FILE_FLAG_NO_BUFFERING or FILE_FLAG_WRITE_THROUGH, 0
    cmp     eax, INVALID_HANDLE_VALUE
    jne     .phys_ok
    invoke  GetLastError
    ccall   UI_LogFmt, szErrOpenPhys, g_PhysPath, eax
    jmp     .fail

.phys_ok:
    mov     [g_DiskHandle], eax

    invoke  DeviceIoControl, [g_DiskHandle], IOCTL_DISK_DELETE_DRIVE_LAYOUT, \
            0, 0, 0, 0, g_BytesReturned, 0
    invoke  DeviceIoControl, [g_DiskHandle], IOCTL_DISK_UPDATE_PROPERTIES, \
            0, 0, 0, 0, g_BytesReturned, 0

    mov     eax, 1
    ret

.fail:
    stdcall Engine_CloseDrive
    xor     eax, eax
    ret
endp

proc Engine_CloseDrive uses ebx
    cmp     [g_DiskHandle], INVALID_HANDLE_VALUE
    je      .close_vols
    cmp     [g_DiskHandle], 0
    je      .close_vols
    invoke  CloseHandle, [g_DiskHandle]
    mov     [g_DiskHandle], INVALID_HANDLE_VALUE

.close_vols:
    xor     ebx, ebx
.loop:
    cmp     ebx, [g_LockedVolCount]
    jae     .done
    invoke  CloseHandle, [g_LockedVolHandles + ebx*4]
    inc     ebx
    jmp     .loop
.done:
    mov     [g_LockedVolCount], 0
    ret
endp


; ============================================================================
; ЭТАП 1: ЭКСПОНЕНЦИАЛЬНЫЙ ПОИСК + БИНАРНОЕ И ТОЧНОЕ УТОЧНЕНИЕ
; ============================================================================

proc RememberAnchor uses esi edi, block_idx, block_len, is_stable
    mov     eax, [block_idx]
    mov     edx, [block_len]

    cmp     [is_stable], 0
    je      .recent

    mov     esi, g_StableAnchors
    mov     ecx, [g_StableAnchorCount]
    mov     edi, MAX_STABLE_ANCHORS
    jmp     .search
.recent:
    mov     esi, g_RecentAnchors
    mov     ecx, [g_RecentAnchorCount]
    mov     edi, MAX_RECENT_ANCHORS
.search:
    push    ecx
    test    ecx, ecx
    jz      .add_new
.chk_loop:
    cmp     [esi + ANCHOR_ITEM.block_idx], eax
    jne     .next_item
    cmp     [esi + ANCHOR_ITEM.block_len], edx
    je      .found
.next_item:
    add     esi, sizeof.ANCHOR_ITEM
    loop    .chk_loop
.add_new:
    pop     ecx
    cmp     ecx, edi
    jae     .shift_or_skip
    mov     [esi + ANCHOR_ITEM.block_idx], eax
    mov     [esi + ANCHOR_ITEM.block_len], edx
    cmp     [is_stable], 0
    je      .inc_recent
    inc     [g_StableAnchorCount]
    ret
.inc_recent:
    inc     [g_RecentAnchorCount]
    ret
.shift_or_skip:
    cmp     [is_stable], 0
    jne     .done
    push    eax edx
    mov     esi, g_RecentAnchors + sizeof.ANCHOR_ITEM
    mov     edi, g_RecentAnchors
    mov     ecx, (MAX_RECENT_ANCHORS - 1) * 2
    rep     movsd
    pop     edx eax
    mov     [edi + ANCHOR_ITEM.block_idx], eax
    mov     [edi + ANCHOR_ITEM.block_len], edx
.done:
    ret
.found:
    pop     ecx
    ret
endp

proc WriteAndVerifyProbe uses ebx esi edi, offset_blk, probe_blocks
    locals
        corrupted_flag  dd ?
        first_corr_blk  dd ?
    endl

    mov     [corrupted_flag], 0

    stdcall StampOffsets, [g_WriteProbeBuf], [offset_blk], [probe_blocks]
    stdcall RawWrite, [offset_blk], [g_WriteProbeBuf], [probe_blocks]
    test    eax, eax
    jnz     .write_ok
    stdcall BlockToByte64, [offset_blk]
    ccall   StrFormat, g_ProbeReason, szErrIoWrite, eax, edx
    xor     eax, eax
    ret

.write_ok:
    stdcall FlushDevice
    test    eax, eax
    jnz     .flush_ok
    ccall   StrFormat, g_ProbeReason, szErrFlush, [g_LastError]
    xor     eax, eax
    ret

.flush_ok:
    stdcall RawRead, [offset_blk], [g_ReadProbeBuf], [probe_blocks]
    test    eax, eax
    jnz     .read_ok
    stdcall BlockToByte64, [offset_blk]
    ccall   StrFormat, g_ProbeReason, szErrIoRead, eax, edx
    xor     eax, eax
    ret

.read_ok:
    stdcall VerifyBufferMarkers, [g_ReadProbeBuf], [offset_blk], [probe_blocks]
    test    eax, eax
    jnz     .check_anchors

    stdcall BlockToByte64, [g_BadBlock]
    ccall   StrFormat, g_ProbeReason, szReasonSelfBad, eax, edx, g_MismatchStr
    xor     eax, eax
    ret

.check_anchors:
    mov     eax, [g_StableAnchorCount]
    add     eax, [g_RecentAnchorCount]
    mov     ebx, eax
    xor     edi, edi

.anchor_loop:
    cmp     edi, ebx
    jae     .anchors_done

    cmp     edi, [g_StableAnchorCount]
    jb      .get_stable
    mov     eax, edi
    sub     eax, [g_StableAnchorCount]
    imul    esi, eax, sizeof.ANCHOR_ITEM
    add     esi, g_RecentAnchors
    jmp     .got_anchor
.get_stable:
    imul    esi, edi, sizeof.ANCHOR_ITEM
    add     esi, g_StableAnchors

.got_anchor:
    mov     eax, [esi + ANCHOR_ITEM.block_idx]
    mov     edx, [esi + ANCHOR_ITEM.block_len]
    cmp     eax, [offset_blk]
    jne     .read_anchor
    cmp     edx, [probe_blocks]
    je      .next_anchor

.read_anchor:
    stdcall RawRead, [esi + ANCHOR_ITEM.block_idx], [g_ReadProbeBuf], [esi + ANCHOR_ITEM.block_len]
    test    eax, eax
    jnz     .anchor_read_ok
    ccall   StrFormat, g_MismatchStr, szErrHwRead
    jmp     .anchor_corrupted

.anchor_read_ok:
    stdcall VerifyBufferMarkers, [g_ReadProbeBuf], [esi + ANCHOR_ITEM.block_idx], [esi + ANCHOR_ITEM.block_len]
    test    eax, eax
    jnz     .next_anchor

.anchor_corrupted:
    cmp     [corrupted_flag], 0
    jne     .restore_anchor
    mov     [corrupted_flag], 1
    mov     eax, [esi + ANCHOR_ITEM.block_idx]
    mov     [first_corr_blk], eax
    ccall   StrFormat, g_FirstAnchorMismatch, szFmtStr, g_MismatchStr

.restore_anchor:
    stdcall StampOffsets, [g_WriteProbeBuf], [esi + ANCHOR_ITEM.block_idx], [esi + ANCHOR_ITEM.block_len]
    stdcall RawWrite, [esi + ANCHOR_ITEM.block_idx], [g_WriteProbeBuf], [esi + ANCHOR_ITEM.block_len]
    test    eax, eax
    jnz     .next_anchor
    ccall   StrFormat, g_ProbeReason, szErrAnchorRestore
    xor     eax, eax
    ret

.next_anchor:
    inc     edi
    jmp     .anchor_loop

.anchors_done:
    cmp     [corrupted_flag], 0
    je      .all_ok

    stdcall FlushDevice
    test    eax, eax
    jnz     .anchor_flush_ok
    ccall   StrFormat, g_ProbeReason, szErrFlush, [g_LastError]
    xor     eax, eax
    ret
.anchor_flush_ok:
    stdcall BlockToGib3, [first_corr_blk]
    mov     ebx, eax
    mov     edi, edx

    stdcall BlockToByte64, [first_corr_blk]
    push    edx eax

    stdcall BlockToByte64, [offset_blk]
    pop     ecx esi

    ccall   StrFormat, g_ProbeReason, szReasonAnchorBad, \
            eax, edx, ecx, esi, ebx, edi, g_FirstAnchorMismatch
    xor     eax, eax
    ret

.all_ok:
    mov     eax, 1
    ret
endp

proc PrintCapacitySummary uses ebx esi edi, title_ptr, disk_num, limit_blocks
    locals
        mib         dd ?
        part_mib    dd ?
        part_sect   dd ?
    endl

    mov     eax, [limit_blocks]
    shr     eax, 8
    mov     [mib], eax

    mov     eax, [limit_blocks]
    call    BlocksToMbrPartMib
    mov     [part_mib], eax
    shl     eax, 11
    mov     [part_sect], eax

    ccall   UI_LogFmt, szSummaryHeader, [title_ptr]

    stdcall BlockToGib3, [limit_blocks]
    mov     ebx, eax
    mov     edi, edx
    stdcall BlockToByte64, [limit_blocks]
    ccall   UI_LogFmt, szSummaryLine1, ebx, edi, [mib], eax, edx, eax, edx

    mov     eax, [limit_blocks]
    mov     edx, eax
    shl     eax, 3
    shr     edx, 29
    mov     ebx, eax
    mov     edi, edx
    sub     ebx, 1
    sbb     edi, 0
    ccall   UI_LogFmt, szSummaryLine2, eax, edx, ebx, edi, [limit_blocks]

    ccall   UI_LogFmt, szSummaryDiskpart, [part_mib], [part_sect], [disk_num], [part_mib]
    ret
endp

proc Engine_RunStage1 uses ebx esi edi, drive_ptr
    locals
        usable_blocks   dd ?
        disk_num        dd ?
        exp_count       dd ?
        last_good       dd ?
        first_bad       dd ?
        low_blk         dd ?
        high_blk        dd ?
        mid_blk         dd ?
        confirmed       dd ?
        candidate       dd ?
        scan_limit      dd ?
    endl

    mov     esi, [drive_ptr]
    mov     eax, [esi + DRIVE_INFO.usable_blocks]
    mov     [usable_blocks], eax
    mov     eax, [esi + DRIVE_INFO.phys_index]
    mov     [disk_num], eax

    stdcall UI_PrintSz, szStage1Start

    mov     [g_WriteProbeBuf], 0
    mov     [g_ReadProbeBuf], 0
    invoke  VirtualAlloc, 0, PROBE_SIZE, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE
    test    eax, eax
    jz      .alloc_fail
    mov     [g_WriteProbeBuf], eax
    invoke  VirtualAlloc, 0, PROBE_SIZE, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE
    test    eax, eax
    jz      .alloc_fail
    mov     [g_ReadProbeBuf], eax

    stdcall InitWriteTemplate, [g_WriteProbeBuf], PROBE_SIZE

    mov     [g_StableAnchorCount], 0
    mov     [g_RecentAnchorCount], 0

    stdcall WriteAndVerifyProbe, 0, PROBE_BLOCKS
    test    eax, eax
    jnz     .lba0_ok
    ccall   UI_LogFmt, szErrLba0, g_ProbeReason
    xor     eax, eax
    jmp     .cleanup

.lba0_ok:
    stdcall RememberAnchor, 0, PROBE_BLOCKS, 1
    mov     [last_good], 0
    mov     [first_bad], -1

    mov     [exp_count], 0
    mov     ebx, GIB_BLOCKS
.build_exp:
    cmp     ebx, [usable_blocks]
    ja      .add_endpoint
    mov     eax, ebx
    sub     eax, PROBE_BLOCKS
    mov     ecx, [exp_count]
    mov     [g_ExpSchedule + ecx*4], eax
    inc     [exp_count]
    shl     ebx, 1
    jnc     .build_exp

.add_endpoint:
    mov     eax, [usable_blocks]
    cmp     eax, PROBE_BLOCKS
    jb      .run_exp
    sub     eax, PROBE_BLOCKS
    and     eax, not (PROBE_BLOCKS - 1)
    mov     ecx, [exp_count]
    test    ecx, ecx
    jz      .store_end
    cmp     eax, [g_ExpSchedule + ecx*4 - 4]
    je      .run_exp
.store_end:
    mov     [g_ExpSchedule + ecx*4], eax
    inc     [exp_count]

.run_exp:
    xor     ebx, ebx
.exp_loop:
    cmp     ebx, [exp_count]
    jae     .exp_done
    mov     esi, [g_ExpSchedule + ebx*4]

    stdcall WriteAndVerifyProbe, esi, PROBE_BLOCKS
    test    eax, eax
    jz      .exp_fail

    lea     eax, [esi + PROBE_BLOCKS]
    stdcall BlockToGib3, eax
    mov     edi, eax
    mov     ecx, edx
    stdcall BlockToByte64, esi
    ccall   UI_LogFmt, szExpOk, eax, edx, edi, ecx

    mov     [last_good], esi
    stdcall RememberAnchor, esi, PROBE_BLOCKS, 1
    inc     ebx
    jmp     .exp_loop

.exp_fail:
    lea     eax, [esi + PROBE_BLOCKS]
    stdcall BlockToGib3, eax
    mov     edi, eax
    mov     ecx, edx
    stdcall BlockToByte64, esi
    ccall   UI_LogFmt, szExpFail, eax, edx, edi, ecx, g_ProbeReason
    mov     [first_bad], esi

.exp_done:
    cmp     [first_bad], -1
    jne     .binary_search

    mov     eax, [last_good]
    add     eax, PROBE_BLOCKS
    cmp     eax, [usable_blocks]
    jbe     .all_exp_ok
    mov     eax, [usable_blocks]
.all_exp_ok:
    mov     [confirmed], eax
    stdcall UI_PrintSz, szAllExpPassed
    stdcall PrintCapacitySummary, szTitleStage1, [disk_num], [confirmed]
    mov     eax, [confirmed]
    jmp     .cleanup

.binary_search:
    mov     eax, [last_good]
    mov     [low_blk], eax
    mov     eax, [first_bad]
    mov     [high_blk], eax

    stdcall BlockToGib6, [high_blk]
    push    edx eax
    stdcall BlockToGib6, [low_blk]
    pop     ecx esi
    ccall   UI_LogFmt, szBinSearchHdr, eax, edx, ecx, esi, PROBE_SIZE / 1024

.bin_loop:
    mov     eax, [high_blk]
    sub     eax, [low_blk]
    cmp     eax, PROBE_BLOCKS
    jbe     .fine_search

    shr     eax, 1
    and     eax, not (PROBE_BLOCKS - 1)
    test    eax, eax
    jz      .fine_search
    add     eax, [low_blk]
    mov     [mid_blk], eax

    stdcall WriteAndVerifyProbe, [mid_blk], PROBE_BLOCKS
    test    eax, eax
    jz      .bin_fail

    stdcall BlockToGib6, [mid_blk]
    mov     edi, eax
    mov     ebx, edx
    stdcall BlockToByte64, [mid_blk]
    ccall   UI_LogFmt, szBinOk, eax, edx, edi, ebx

    mov     eax, [mid_blk]
    mov     [low_blk], eax
    mov     [last_good], eax
    stdcall RememberAnchor, eax, PROBE_BLOCKS, 0
    jmp     .bin_loop

.bin_fail:
    stdcall BlockToGib6, [mid_blk]
    mov     edi, eax
    mov     ebx, edx
    stdcall BlockToByte64, [mid_blk]
    ccall   UI_LogFmt, szBinFail, eax, edx, edi, ebx, g_ProbeReason

    mov     eax, [mid_blk]
    mov     [high_blk], eax
    jmp     .bin_loop

.fine_search:
    mov     eax, [low_blk]
    add     eax, PROBE_BLOCKS
    cmp     eax, [usable_blocks]
    jbe     .set_cand
    mov     eax, [usable_blocks]
.set_cand:
    mov     [confirmed], eax
    mov     [candidate], eax

    mov     eax, [high_blk]
    add     eax, PROBE_BLOCKS
    cmp     eax, [usable_blocks]
    jbe     .set_limit
    mov     eax, [usable_blocks]
.set_limit:
    mov     [scan_limit], eax

    stdcall BlockToGib6, [scan_limit]
    push    edx eax
    stdcall BlockToGib6, [candidate]
    pop     ecx esi
    ccall   UI_LogFmt, szFineSearchHdr, eax, edx, ecx, esi, BLOCK_SIZE / 1024

.fine_loop:
    mov     eax, [candidate]
    cmp     eax, [scan_limit]
    jae     .fine_done

    stdcall WriteAndVerifyProbe, [candidate], 1
    test    eax, eax
    jz      .fine_fail

    stdcall RememberAnchor, [candidate], 1, 0
    inc     [candidate]
    mov     eax, [candidate]
    mov     [confirmed], eax
    jmp     .fine_loop

.fine_fail:
    stdcall BlockToGib6, [candidate]
    mov     edi, eax
    mov     ebx, edx
    stdcall BlockToByte64, [candidate]
    ccall   UI_LogFmt, szBinFail, eax, edx, edi, ebx, g_ProbeReason

.fine_done:
    ccall   UI_LogFmt, szStage1Stopped, BLOCK_SIZE
    stdcall PrintCapacitySummary, szTitleStage1, [disk_num], [confirmed]
    mov     eax, [confirmed]
    jmp     .cleanup

.alloc_fail:
    stdcall UI_PrintSz, szErrMemory
    xor     eax, eax
    jmp     .cleanup

.cleanup:
    push    eax
    cmp     [g_WriteProbeBuf], 0
    je      .free_read_probe
    invoke  VirtualFree, [g_WriteProbeBuf], 0, MEM_RELEASE
    mov     [g_WriteProbeBuf], 0
.free_read_probe:
    cmp     [g_ReadProbeBuf], 0
    je      .stage1_free_done
    invoke  VirtualFree, [g_ReadProbeBuf], 0, MEM_RELEASE
    mov     [g_ReadProbeBuf], 0
.stage1_free_done:
    pop     eax
    ret
endp


; ============================================================================
; ЭТАП 2: ПОТОКОВАЯ ПРОВЕРКА И АНАЛИЗ СКОРОСТИ
; ============================================================================

proc CalcSpeedX10 uses ebx, num_blocks, ticks_low, ticks_high
    mov     eax, [num_blocks]
    imul    eax, 10
    mov     ecx, dword [g_QpcFreq]
    mul     ecx
    shrd    eax, edx, 8
    shr     edx, 8

    mov     ecx, [ticks_low]
    mov     ebx, [ticks_high]
.norm_ticks:
    test    ebx, ebx
    jz      .do_div
    shr     ebx, 1
    rcr     ecx, 1
    shr     edx, 1
    rcr     eax, 1
    jmp     .norm_ticks

.do_div:
    test    ecx, ecx
    jnz     .safe_div
    inc     ecx
.safe_div:
    cmp     edx, ecx
    jb      .div_ok
    mov     eax, 99999
    ret
.div_ok:
    div     ecx
    ret
endp

proc AnalyzeSlowTail uses ebx esi edi
    locals
        good_count  dd ?
        expected    dd ?
        sort_arr    rd 5
    endl

    mov     [g_BaselineSpeed], 0
    mov     [g_ThresholdSpeed], 0
    mov     [g_SlowTailBlock], -1

    xor     ecx, ecx
    xor     edx, edx
    mov     esi, g_ChunkMetrics
.cnt_loop:
    cmp     ecx, [g_MetricCount]
    jae     .cnt_done
    cmp     [esi + CHUNK_METRIC.passed], 0
    je      .cnt_next
    cmp     edx, 5
    jae     .inc_good
    mov     eax, [esi + CHUNK_METRIC.w_speed_x10]
    mov     [sort_arr + edx*4], eax
.inc_good:
    inc     edx
.cnt_next:
    add     esi, sizeof.CHUNK_METRIC
    inc     ecx
    jmp     .cnt_loop

.cnt_done:
    mov     [good_count], edx
    cmp     edx, 5
    jb      .done

    mov     ecx, 4
.outer:
    lea     esi, [sort_arr]
    mov     ebx, ecx
.inner:
    lodsd
    mov     edx, [esi]
    cmp     eax, edx
    jbe     .no_swap
    xchg    eax, [esi]
    mov     [esi-4], eax
.no_swap:
    dec     ebx
    jnz     .inner
    loop    .outer

    mov     eax, [sort_arr + 2*4]
    mov     [g_BaselineSpeed], eax
    imul    eax, SLOW_SPEED_PCT
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    mov     [g_ThresholdSpeed], eax

    mov     ecx, [g_MetricCount]
    dec     ecx
    imul    esi, ecx, sizeof.CHUNK_METRIC
    add     esi, g_ChunkMetrics
.find_last_good:
    cmp     ecx, 0
    jl      .done
    cmp     [esi + CHUNK_METRIC.passed], 0
    jne     .start_tail_scan
    sub     esi, sizeof.CHUNK_METRIC
    dec     ecx
    jmp     .find_last_good

.start_tail_scan:
    mov     eax, [esi + CHUNK_METRIC.chunk_index]
    mov     [expected], eax

.tail_loop:
    cmp     ecx, 0
    jl      .done
    cmp     [esi + CHUNK_METRIC.passed], 0
    je      .next_tail_item

    mov     eax, [esi + CHUNK_METRIC.chunk_index]
    cmp     eax, [expected]
    jne     .done

    mov     eax, [esi + CHUNK_METRIC.w_speed_x10]
    cmp     eax, [g_ThresholdSpeed]
    jae     .done

    mov     eax, [esi + CHUNK_METRIC.start_block]
    mov     [g_SlowTailBlock], eax
    dec     [expected]

.next_tail_item:
    sub     esi, sizeof.CHUNK_METRIC
    dec     ecx
    jmp     .tail_loop

.done:
    ret
endp

proc PrintPartitionOptions uses ebx esi edi, disk_num, verified_blocks, slow_tail_block, mode
    locals
        full_mib    dd ?
        full_sect   dd ?
        fast_mib    dd ?
        fast_sect   dd ?
    endl

    mov     eax, [verified_blocks]
    call    BlocksToMbrPartMib
    mov     [full_mib], eax
    shl     eax, 11
    mov     [full_sect], eax

    mov     eax, [verified_blocks]
    cmp     [slow_tail_block], -1
    je      .set_fast
    cmp     [slow_tail_block], eax
    jae     .set_fast
    mov     eax, [slow_tail_block]
.set_fast:
    call    BlocksToMbrPartMib
    mov     [fast_mib], eax
    shl     eax, 11
    mov     [fast_sect], eax

    stdcall UI_PrintSz, szOptHeader
    cmp     [mode], MODE_ALL
    je      .not_sampled
    stdcall UI_PrintSz, szOptSampledWarn
    jmp     .print_v1_info
.not_sampled:
    stdcall UI_PrintSz, szOptFullInfo

.print_v1_info:
    ccall   UI_LogFmt, szOptVar1Info, [full_mib], [full_sect]

    cmp     [slow_tail_block], -1
    je      .no_tail_opt
    mov     eax, [fast_mib]
    cmp     eax, [full_mib]
    jae     .no_tail_opt

    stdcall BlockToGib3, [slow_tail_block]
    mov     ebx, eax
    mov     edi, edx
    stdcall BlockToByte64, [slow_tail_block]
    ccall   UI_LogFmt, szOptVar2SlowInfo, [fast_mib], [fast_sect], eax, edx, ebx, edi
    jmp     .print_commands

.no_tail_opt:
    stdcall UI_PrintSz, szOptVar2NoSlow

.print_commands:
    stdcall UI_PrintSz, szOptCommandsHeader
    ccall   UI_LogFmt, szOptCommandsDisk, [disk_num]
    stdcall UI_PrintSz, szOptCommandsBeforeSize
    ccall   UI_LogFmt, szOptCommandSize, [full_mib]

    mov     eax, [fast_mib]
    cmp     eax, [full_mib]
    je      .one_size_only
    stdcall UI_PrintSz, szOptCommandsOr
    ccall   UI_LogFmt, szOptCommandSize, [fast_mib]

.one_size_only:
    stdcall UI_PrintSz, szOptCommandsAfterSize
    stdcall UI_PrintSz, szOptFooter
    ret
endp

proc Engine_RunStage2 uses ebx esi edi, drive_ptr, test_limit_blocks, mode
    locals
        disk_num        dd ?
        total_chunks    dd ?
        chunk_idx       dd ?
        start_block     dd ?
        length_blocks   dd ?
        completed       dd ?
        amount          dd ?
        cur_block       dd ?
        w_speed_x10     dd ?
        r_speed_x10     dd ?
        w_int           dd ?
        w_frac          dd ?
        r_int           dd ?
        r_frac          dd ?
        chunk_err_flag  dd ?
        first_fail_blk  dd ?
        audit_fail_blk  dd ?
        verified_end    dd ?
        stage2_ok       dd ?
    endl

    mov     esi, [drive_ptr]
    mov     eax, [esi + DRIVE_INFO.phys_index]
    mov     [disk_num], eax

    stdcall BlockToGib3, [test_limit_blocks]
    mov     ebx, eax
    mov     edi, edx
    mov     ecx, szModeAllTitle
    cmp     [mode], MODE_ALL
    je      .print_hdr
    mov     ecx, szModeEdgesTitle
.print_hdr:
    ccall   UI_LogFmt, szStage2Start, ecx, ebx, edi

    mov     [stage2_ok], 1
    mov     [g_StreamWriteBuf], 0
    mov     [g_StreamReadBuf], 0
    mov     [g_AuditSectorBuf], 0
    invoke  VirtualAlloc, 0, IO_SIZE, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE
    test    eax, eax
    jz      .stage2_alloc_fail
    mov     [g_StreamWriteBuf], eax
    invoke  VirtualAlloc, 0, IO_SIZE, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE
    test    eax, eax
    jz      .stage2_alloc_fail
    mov     [g_StreamReadBuf], eax
    invoke  VirtualAlloc, 0, BLOCK_SIZE, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE
    test    eax, eax
    jz      .stage2_alloc_fail
    mov     [g_AuditSectorBuf], eax

    stdcall InitWriteTemplate, [g_StreamWriteBuf], IO_SIZE

    ; Автоподбор шага (по умолчанию 128 МиБ = 15 сдвиг)
    mov     cl, 15
.calc_chunks:
    mov     eax, [test_limit_blocks]
    dec     eax
    shr     eax, cl
    inc     eax
    cmp     eax, 16      ; HEAD_CHUNKS(5) + TAIL_CHUNKS(10) + 1
    jae     .chunks_ok
    dec     cl
    jmp     .calc_chunks
.chunks_ok:
    mov     byte [g_ChunkShift], cl
    mov     [total_chunks], eax

    cmp     [mode], MODE_ALL
    jne     .chunks_capacity_ok
    cmp     eax, MAX_CHUNKS
    ja      .too_many_chunks
.chunks_capacity_ok:

    cmp     [mode], MODE_ALL
    je      .init_stream
    ccall   UI_LogFmt, szEdgesNotice, TAIL_CHUNKS, TAIL_CHUNKS

.init_stream:
    mov     [g_MetricCount], 0
    mov     [first_fail_blk], -1
    mov     [chunk_idx], 0

.chunk_loop:
    mov     eax, [chunk_idx]
    cmp     eax, [total_chunks]
    jae     .stream_done

    mov     cl, byte [g_ChunkShift]
    mov     eax, [chunk_idx]
    shl     eax, cl
    mov     [start_block], eax

    mov     edx, 1
    shl     edx, cl
    mov     eax, [test_limit_blocks]
    sub     eax, [start_block]
    cmp     eax, edx
    jbe     .set_len
    mov     eax, edx
.set_len:
    mov     [length_blocks], eax
    test    eax, eax
    jz      .next_chunk

    ; --- ЗАПИСЬ ЧАНКА ---
    invoke  QueryPerformanceCounter, g_QpcT0Low
    mov     [completed], 0
    mov     [chunk_err_flag], 0

.write_io_loop:
    mov     eax, [completed]
    cmp     eax, [length_blocks]
    jae     .write_io_done

    mov     edx, [length_blocks]
    sub     edx, eax
    cmp     edx, IO_BLOCKS
    jbe     .set_w_amt
    mov     edx, IO_BLOCKS
.set_w_amt:
    mov     [amount], edx
    add     eax, [start_block]
    mov     [cur_block], eax

    stdcall StampOffsets, [g_StreamWriteBuf], [cur_block], [amount]
    stdcall RawWrite, [cur_block], [g_StreamWriteBuf], [amount]
    test    eax, eax
    jz      .write_hw_err

    mov     eax, [amount]
    add     [completed], eax
    jmp     .write_io_loop

.write_hw_err:
    mov     eax, [cur_block]
    mov     [g_BadBlock], eax
    ccall   StrFormat, g_MismatchStr, szErrHwWrite
    mov     [chunk_err_flag], 1

.write_io_done:
    stdcall FlushDevice
    test    eax, eax
    jnz     .flush_stage2_ok
    cmp     [chunk_err_flag], 0
    jne     .flush_error_already_set
    mov     eax, [start_block]
    mov     [g_BadBlock], eax
    ccall   StrFormat, g_MismatchStr, szErrFlush, [g_LastError]
    mov     [chunk_err_flag], 1
.flush_error_already_set:
.flush_stage2_ok:
    invoke  QueryPerformanceCounter, g_QpcT1Low
    mov     eax, [g_QpcT1Low]
    mov     edx, [g_QpcT1High]
    sub     eax, [g_QpcT0Low]
    sbb     edx, [g_QpcT0High]
    stdcall CalcSpeedX10, [completed], eax, edx
    mov     [w_speed_x10], eax

    ; --- ЧТЕНИЕ И ВЕРИФИКАЦИЯ ЧАНКА ---
    invoke  QueryPerformanceCounter, g_QpcT0Low
    mov     [completed], 0

    cmp     [chunk_err_flag], 0
    jne     .read_io_done

.read_io_loop:
    mov     eax, [completed]
    cmp     eax, [length_blocks]
    jae     .read_io_done

    mov     edx, [length_blocks]
    sub     edx, eax
    cmp     edx, IO_BLOCKS
    jbe     .set_r_amt
    mov     edx, IO_BLOCKS
.set_r_amt:
    mov     [amount], edx
    add     eax, [start_block]
    mov     [cur_block], eax

    stdcall RawRead, [cur_block], [g_StreamReadBuf], [amount]
    test    eax, eax
    jz      .read_hw_err

    mov     eax, [amount]
    add     [completed], eax

    stdcall VerifyBufferMarkers, [g_StreamReadBuf], [cur_block], [amount]
    test    eax, eax
    jz      .read_verify_err
    jmp     .read_io_loop

.read_hw_err:
    mov     eax, [cur_block]
    mov     [g_BadBlock], eax
    ccall   StrFormat, g_MismatchStr, szErrHwRead
    mov     [chunk_err_flag], 1
    jmp     .read_io_done

.read_verify_err:
    mov     [chunk_err_flag], 1

.read_io_done:
    cmp     [completed], 0
    je      .read_speed_zero
    invoke  QueryPerformanceCounter, g_QpcT1Low
    mov     eax, [g_QpcT1Low]
    mov     edx, [g_QpcT1High]
    sub     eax, [g_QpcT0Low]
    sbb     edx, [g_QpcT0High]
    stdcall CalcSpeedX10, [completed], eax, edx
    mov     [r_speed_x10], eax
    jmp     .read_speed_ready
.read_speed_zero:
    mov     [r_speed_x10], 0
.read_speed_ready:
    mov     eax, [w_speed_x10]
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    mov     [w_int], eax
    mov     [w_frac], edx

    mov     eax, [r_speed_x10]
    xor     edx, edx
    div     ecx
    mov     [r_int], eax
    mov     [r_frac], edx

    stdcall BlockToGib3, [start_block]
    mov     ebx, eax
    mov     eax, edx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    mov     edi, eax

    stdcall BlockToByte64, [start_block]
    mov     ecx, [chunk_idx]
    inc     ecx

    ccall   UI_LogFmt, szChunkProgress, ecx, [total_chunks], eax, edx, ebx, edi, \
            [w_int], [w_frac], [r_int], [r_frac]

    cmp     [chunk_err_flag], 0
    je      .audit_checkpoints

    stdcall RecordChunkMetric, [chunk_idx], [start_block], [length_blocks], \
            [w_speed_x10], [r_speed_x10], 0
    stdcall BlockToByte64, [g_BadBlock]
    ccall   UI_LogFmt, szChunkFail, eax, edx, g_MismatchStr
    mov     eax, [g_BadBlock]
    mov     [first_fail_blk], eax
    jmp     .stream_done

    ; --- АУДИТ КОНТРОЛЬНЫХ ТОЧЕК ВСЕХ ПРЕДЫДУЩИХ ЧАНКОВ ---
.audit_checkpoints:
    mov     [audit_fail_blk], -1
    xor     ebx, ebx
    mov     esi, g_ChunkMetrics
.audit_loop:
    cmp     ebx, [g_MetricCount]
    jae     .audit_passed

    mov     edi, [esi + CHUNK_METRIC.start_block]
    stdcall RawRead, edi, [g_AuditSectorBuf], 1
    test    eax, eax
    jz      .audit_bad
    stdcall VerifyBufferMarkers, [g_AuditSectorBuf], edi, 1
    test    eax, eax
    jz      .audit_bad

    mov     edi, [esi + CHUNK_METRIC.start_block]
    add     edi, [esi + CHUNK_METRIC.length_blocks]
    dec     edi
    stdcall RawRead, edi, [g_AuditSectorBuf], 1
    test    eax, eax
    jz      .audit_bad
    stdcall VerifyBufferMarkers, [g_AuditSectorBuf], edi, 1
    test    eax, eax
    jz      .audit_bad

    add     esi, sizeof.CHUNK_METRIC
    inc     ebx
    jmp     .audit_loop

.audit_bad:
    mov     [audit_fail_blk], edi
    stdcall RecordChunkMetric, [chunk_idx], [start_block], [length_blocks], \
            [w_speed_x10], [r_speed_x10], 0
    stdcall BlockToByte64, [audit_fail_blk]
    ccall   UI_LogFmt, szChunkAuditFail, eax, edx
    mov     eax, [start_block]
    mov     [first_fail_blk], eax
    jmp     .stream_done

.audit_passed:
    stdcall RecordChunkMetric, [chunk_idx], [start_block], [length_blocks], \
            [w_speed_x10], [r_speed_x10], 1
    stdcall UI_PrintSz, szChunkOk

.next_chunk:
    inc     [chunk_idx]
    cmp     [mode], MODE_EDGES
    jne     .chunk_loop
    cmp     [chunk_idx], 5
    jb      .chunk_loop
    mov     eax, [total_chunks]
    sub     eax, TAIL_CHUNKS
    cmp     [chunk_idx], eax
    jae     .chunk_loop
    mov     [chunk_idx], eax
    jmp     .chunk_loop

    ; --- ИТОГИ ЭТАПА 2 ---
.stream_done:
    stdcall AnalyzeSlowTail
    cmp     [g_BaselineSpeed], 0
    je      .check_tail_msg

    mov     eax, [g_BaselineSpeed]
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    mov     [w_int], eax
    mov     [w_frac], edx

    mov     eax, [g_ThresholdSpeed]
    xor     edx, edx
    div     ecx
    mov     [r_int], eax
    mov     [r_frac], edx

    ccall   UI_LogFmt, szBaselineInfo, [w_int], [w_frac], [r_int], [r_frac]

.check_tail_msg:
    cmp     [g_SlowTailBlock], -1
    je      .no_slow_tail
    stdcall BlockToGib3, [g_SlowTailBlock]
    mov     ebx, eax
    mov     edi, edx
    stdcall BlockToByte64, [g_SlowTailBlock]
    ccall   UI_LogFmt, szSlowTailFound, eax, edx, ebx, edi
    jmp     .diag_summary

.no_slow_tail:
    stdcall UI_PrintSz, szSlowTailNone

.diag_summary:
    xor     ebx, ebx
    xor     ecx, ecx
    mov     esi, g_ChunkMetrics
.cnt_pass:
    cmp     ecx, [g_MetricCount]
    jae     .cnt_pass_done
    cmp     [esi + CHUNK_METRIC.passed], 0
    je      .cnt_pass_next
    inc     ebx
.cnt_pass_next:
    add     esi, sizeof.CHUNK_METRIC
    inc     ecx
    jmp     .cnt_pass

.cnt_pass_done:
    mov     edi, szModeNameFull
    cmp     [mode], MODE_ALL
    je      .mode_named
    mov     edi, szModeNameSampled
.mode_named:
    cmp     [first_fail_blk], -1
    je      .no_failures

    mov     eax, [first_fail_blk]
    mov     [verified_end], eax
    stdcall BlockToGib6, eax
    push    edx eax
    stdcall BlockToByte64, [first_fail_blk]
    pop     ecx esi
    ccall   UI_LogFmt, szDiagFailSummary, edi, ebx, eax, edx, ecx, esi
    jmp     .print_end_addr

.no_failures:
    mov     eax, [test_limit_blocks]
    mov     [verified_end], eax
    ccall   UI_LogFmt, szDiagOkSummary, edi, ebx, [g_MetricCount]
    cmp     [mode], MODE_ALL
    jne     .ok_sampled_msg
    stdcall UI_PrintSz, szDiagOkFullMsg
    jmp     .print_end_addr
.ok_sampled_msg:
    stdcall UI_PrintSz, szDiagOkSampledMsg

.print_end_addr:
    stdcall BlockToGib6, [verified_end]
    mov     ebx, eax
    mov     edi, edx
    stdcall BlockToByte64, [verified_end]
    ccall   UI_LogFmt, szDiagEndOffset, ebx, edi, eax, edx

    stdcall PrintPartitionOptions, [disk_num], [verified_end], [g_SlowTailBlock], [mode]

    cmp     [first_fail_blk], -1
    je      .stage2_result_ok
    mov     [stage2_ok], 0
.stage2_result_ok:
    jmp     .stage2_cleanup

.stage2_alloc_fail:
    stdcall UI_PrintSz, szErrMemory
    mov     [stage2_ok], 0
    jmp     .stage2_cleanup

.too_many_chunks:
    stdcall UI_PrintSz, szErrTooManyChunks
    mov     [stage2_ok], 0

.stage2_cleanup:
    cmp     [g_StreamWriteBuf], 0
    je      .free_stream_read
    invoke  VirtualFree, [g_StreamWriteBuf], 0, MEM_RELEASE
    mov     [g_StreamWriteBuf], 0
.free_stream_read:
    cmp     [g_StreamReadBuf], 0
    je      .free_audit_buf
    invoke  VirtualFree, [g_StreamReadBuf], 0, MEM_RELEASE
    mov     [g_StreamReadBuf], 0
.free_audit_buf:
    cmp     [g_AuditSectorBuf], 0
    je      .stage2_return
    invoke  VirtualFree, [g_AuditSectorBuf], 0, MEM_RELEASE
    mov     [g_AuditSectorBuf], 0
.stage2_return:
    mov     eax, [stage2_ok]
    ret
endp

proc RecordChunkMetric uses esi edi, c_idx, s_blk, len_blk, w_spd, r_spd, pass_flag
    mov     eax, [g_MetricCount]
    cmp     eax, MAX_CHUNKS
    jae     .done
    imul    edi, eax, sizeof.CHUNK_METRIC
    add     edi, g_ChunkMetrics
    lea     esi, [c_idx]
    mov     ecx, 6
    rep     movsd
    inc     [g_MetricCount]
.done:
    ret
endp


; ============================================================================
; СЕКЦИЯ ДАННЫХ (СТРОКИ И ШАБЛОНЫ ПУТЕЙ UTF-8)
; ============================================================================
section '.data' data readable writeable

g_RootPath          db 'A:\', 0
g_VolPath           db '\\.\A:', 0
g_PhysPath          db '\\.\PhysicalDrive0', 0, 0, 0

szDefaultModel      db 'Disk Drive', 0
szNoVolumes         db 'Нет разделов / Не распределен', 0
szFmtStr            db '%s', 0

szErrQpc             db 'ОШИБКА: QueryPerformanceFrequency не сработал.', 13, 10, 0
szErrMemory          db 'ОШИБКА: Не удалось выделить память для буферов теста.', 13, 10, 0
szErrAddressLimit    db 'ОШИБКА: PhysicalDrive%u превышает адресный предел 32-битного движка (16 ТиБ), пропуск.', 13, 10, 0
szErrTooManyChunks   db 'ОШИБКА: Объём теста превышает предел массива участков.', 13, 10, 0
szErrOpenVol         db 'ОШИБКА: Не удалось открыть том %c: перед raw-записью (код %u).', 13, 10, 0
szErrFlush           db 'ошибка FlushFileBuffers (код %u)', 0
szErrAnchorRestore   db 'ошибка записи при восстановлении контрольной точки', 0
szErrNotAdmin       db 'ОШИБКА: Программа должна быть запущена от имени Администратора!', 13, 10, 0
szErrNoDrives       db 'USB-накопители не обнаружены. Проверьте подключение устройства.', 13, 10, 0
szCancelled         db 'Отменено пользователем.', 13, 10, 0
szInvalidDrive      db 'Неверный номер устройства. Завершение работы.', 13, 10, 0

szWarnBanner        db '========================================================================', 13, 10
                    db 'ВНИМАНИЕ! ВСЕ ДАННЫЕ И РАЗДЕЛЫ НА ВЫБРАННОМ УСТРОЙСТВЕ БУДУТ УНИЧТОЖЕНЫ!', 13, 10
                    db 'Выбор номера накопителя из списка ниже немедленно запускает запись.', 13, 10
                    db '========================================================================', 13, 10
                    db 13, 10, 'Доступные USB-устройства:', 13, 10, 0

szDriveItem         db '  [%u] PhysicalDrive%u | %s (Съёмный USB)', 13, 10
                    db '      Заявлено: %u.%02u ГиБ (%U байт / %U секторов) | Тома: [%s]', 13, 10, 0

szPromptDrive       db 13, 10, 'Введите номер устройства [1..%u] для старта (или Enter для отмены): ', 0
szPromptMode        db 13, 10, 'Выберите режим потоковой проверки:', 13, 10
                    db '  [1] Полная проверка — все блоки от начала до конца, остановка на первом сбое', 13, 10
                    db '  [2] Быстрая проверка — первые 5 и последние %u блоков, остановка на первом сбое', 13, 10
                    db 'Ваш выбор [1/2, Enter — пропустить этап 2]: ', 0

szStage2Skipped     db 'Потоковый этап пропущен.', 13, 10, 0
szFinalNote         db 13, 10, 'Примечание: после теста физического диска (PhysicalDrive) таблица разделов очищена.', 13, 10
                    db 'Создайте новый раздел через Diskpart (команды указаны в сводке выше).', 13, 10, 0

szErrLockVol        db 'ОШИБКА: Не удалось заблокировать том %c:. Закройте Проводник и программы.', 13, 10, 0
szErrDismountVol    db 'ОШИБКА: Не удалось размонтировать том %c:.', 13, 10, 0
szErrUnmappedVol    db 'ОШИБКА: Не удалось открыть том %c: при сканировании. Проверка отменена, чтобы не выполнять raw-запись по смонтированному тому.', 13, 10, 0
szErrOpenPhys       db 'ОШИБКА: Не удалось открыть %s (код %u).', 13, 10, 0

szNewMarker1        db 13, 10, 'Новый контрольный маркер этапа 1: %08X%08X', 13, 10, 0
szNewMarker2        db 'Новый контрольный маркер этапа 2: %08X%08X', 13, 10, 0

szStage1Start       db 13, 10, '--- ЭТАП 1: Поиск рабочей области (64 КиБ контрольные блоки) ---', 13, 10, 0
szErrLba0           db 'ОШИБКА: Нулевой сектор LBA 0 не проходит запись: %s', 13, 10, 0
szExpOk             db '  [OK]   0x%010I (блок до %4u.%03u ГиБ)', 13, 10, 0
szExpFail           db '  [СБОЙ] 0x%010I (блок до %4u.%03u ГиБ) -> %s', 13, 10, 0
szAllExpPassed      db 'Все экспоненциальные контрольные точки прошли.', 13, 10
                    db 'Это экспресс-оценка по контрольным точкам, а не сплошная проверка каждого байта.', 13, 10, 0

szBinSearchHdr      db 13, 10, 'Бинарное уточнение диапазона %u.%06u .. %u.%06u ГиБ до интервала %u КиБ:', 13, 10, 0
szBinOk             db '  [OK]   0x%010I (%u.%06u ГиБ)', 13, 10, 0
szBinFail           db '  [СБОЙ] 0x%010I (%u.%06u ГиБ) -> %s', 13, 10, 0
szFineSearchHdr     db 13, 10, 'Точное уточнение диапазона %u.%06u .. %u.%06u ГиБ блоками по %u КиБ:', 13, 10, 0
szStage1Stopped     db 13, 10, 'Этап 1 остановлен на первой неудачной контрольной пачке.', 13, 10
                    db 'Последняя непрерывно проверенная граница уточнена с точностью до %u байт.', 13, 10, 0

szTitleStage1       db 'ПРЕДВАРИТЕЛЬНАЯ ОЦЕНКА ПО КОНТРОЛЬНЫМ ПРОБАМ ЭТАПА 1', 0

szSummaryHeader     db 13, 10, '========================================================================', 13, 10
                    db '%s', 13, 10
                    db '========================================================================', 13, 10, 0
szSummaryLine1      db 'Адрес начала первой нерабочей области: %u.%03u ГиБ (%u МиБ / %U байт)', 13, 10
                    db 'Адрес сразу за границей:               0x%I', 13, 10, 0
szSummaryLine2      db 'Секторов в расчётной области:          %U (LBA 0 .. %U)', 13, 10
                    db 'Блоков по 4096 Б в области:            %u', 13, 10
                    db '------------------------------------------------------------------------', 13, 10, 0
szSummaryDiskpart   db 'Размер раздела Diskpart (предел MBR 2 ТиБ): %u МиБ (%u секторов)', 13, 10
                    db '  (начало раздела — смещение 1 МиБ; 1 МиБ оставляется под MBR/выравнивание)', 13, 10
                    db 'Команды для Diskpart:                  select disk %u -> clean -> convert mbr', 13, 10
                    db '                                       create partition primary size=%u', 13, 10
                    db '========================================================================', 13, 10, 0

szMismatchZero      db 'прочитаны нули (0x00)', 0
szMismatchFF        db 'прочитана пустота NAND (0xFF)', 0
szMismatchLoop      db 'кольцевая перезапись (внутри метка от 0x%I / %u.%03u ГиБ)', 0
szMismatchForeign   db 'чужие данные (%02X %02X %02X %02X %02X %02X %02X %02X...)', 0

szErrIoWrite        db 'аппаратная ошибка записи по адресу 0x%I', 0
szErrIoRead         db 'аппаратная ошибка чтения по адресу 0x%I', 0
szReasonSelfBad     db 'не сохранился блок 0x%I: %s', 0
szReasonAnchorBad   db 'запись в 0x%I затёрла опорную точку 0x%I (%u.%03u ГиБ) -> %s', 0

szModeAllTitle      db 'все блоки', 0
szModeEdgesTitle    db 'первые 5 + последние 10 блоков', 0
szStage2Start       db 13, 10, '--- ЭТАП 2: Потоковая проверка (%s), предел проверки %u.%03u ГиБ ---', 13, 10, 0
szEdgesNotice       db '  Параметр TAIL_CHUNKS=%u: проверяются первые 5 и последние %u блоков.', 13, 10, 0

szChunkProgress     db '[%2u/%2u] 0x%010I (%2u.%02u ГиБ) | Запись: %3u.%u МиБ/с | Чтение: %3u.%u МиБ/с', 0
szChunkOk           db ' -> OK', 13, 10, 0
szChunkFail         db ' -> СБОЙ на 0x%I (%s)', 13, 10, 0
szChunkAuditFail    db ' -> СБОЙ АУДИТА: повреждён ранее записанный адрес 0x%I!', 13, 10, 0
szErrHwWrite        db 'ошибка записи WriteFile', 0
szErrHwRead         db 'ошибка чтения ReadFile', 0

szBaselineInfo      db 13, 10, 'Базовая скорость записи по первым блокам: %u.%u МиБ/с; порог медленного блока: %u.%u МиБ/с.', 13, 10, 0
szSlowTailFound     db 'Непрерывный медленный хвост начинается с 0x%I (%u.%03u ГиБ).', 13, 10
                    db 'Для одного раздела исключается именно медленный хвост; отдельные медленные участки в середине нельзя вырезать одним размером раздела.', 13, 10, 0
szSlowTailNone      db 'Непрерывный медленный хвост по выбранным блокам не обнаружен.', 13, 10, 0

szModeNameFull      db 'полный', 0
szModeNameSampled   db 'выборочный', 0
szDiagFailSummary   db 13, 10, 'ДИАГНОСТИЧЕСКИЙ ИТОГ', 13, 10
                    db '  Режим проверки:            %s', 13, 10
                    db '  Успешно проверено блоков:  %u', 13, 10
                    db '  Ошибка обнаружена по адресу: 0x%I (%u.%06u ГиБ)', 13, 10
                    db '  Проверка остановлена на первой ошибке; последующие блоки не тестировались.', 13, 10, 0
szDiagOkSummary     db 13, 10, 'ДИАГНОСТИЧЕСКИЙ ИТОГ', 13, 10
                    db '  Режим проверки:            %s', 13, 10
                    db '  Успешно проверено блоков:  %u из %u выбранных', 13, 10, 0
szDiagOkFullMsg     db '  Ошибок не обнаружено в сплошной проверенной области.', 13, 10, 0
szDiagOkSampledMsg  db '  Ошибок не обнаружено в выбранных блоках; промежуточные блоки не проверялись.', 13, 10, 0
szDiagEndOffset     db '  Конечный адрес проверенной области: %u.%06u ГиБ (0x%I)', 13, 10, 0

szOptHeader         db 13, 10, '========================================================================', 13, 10
                    db 'РЕКОМЕНДУЕМЫЕ ВАРИАНТЫ РАЗМЕТКИ DISKPART', 13, 10
                    db '========================================================================', 13, 10, 0
szOptSampledWarn    db 'ВНИМАНИЕ: быстрая проверка выборочная; промежуточные блоки не проверялись.', 13, 10
                    db 'Размер варианта 1 предварительный — по первой ошибке/границе выборки.', 13, 10, 0
szOptFullInfo       db 'Вариант 1 рассчитан по области, успешно прошедшей сплошную потоковую проверку.', 13, 10, 0
szOptVar1Info       db 'ВАРИАНТ 1 — вся рабочая область: раздел %u МиБ (%u секторов).', 13, 10, 0
szOptVar2SlowInfo   db 'ВАРИАНТ 2 — без медленного хвоста: раздел %u МиБ (%u секторов).', 13, 10
                    db '  Начало медленного хвоста: 0x%I (%u.%03u ГиБ).', 13, 10, 0
szOptVar2NoSlow     db 'ВАРИАНТ 2 совпадает с вариантом 1: отдельный непрерывный медленный хвост не выявлен.', 13, 10, 0
szOptCommandsHeader db 13, 10, 'ОБЩИЕ КОМАНДЫ DISKPART', 13, 10, 0
szOptCommandsDisk   db '  diskpart', 13, 10, '  select disk %u', 13, 10, 0
szOptCommandsBeforeSize db '  clean', 13, 10, '  convert mbr', 13, 10, 0
szOptCommandSize    db '  create partition primary size=%u', 13, 10, 0
szOptCommandsOr     db '  ИЛИ', 13, 10, 0
szOptCommandsAfterSize db '  format fs=exfat quick', 13, 10, '  assign', 13, 10, 0
szOptFooter         db 13, 10, 'Примечание: размер Diskpart меньше границы на 1 МиБ из-за смещения начала раздела.', 13, 10
                    db 'Для накопителей свыше 2 ТиБ используйте GPT; показанные размеры ограничены пределом MBR.', 13, 10
                    db '========================================================================', 13, 10, 0
szPressEnter        db 13, 10, 'Нажмите Enter для выхода...', 0

; ============================================================================
; НЕИНИЦИАЛИЗИРОВАННЫЕ ДАННЫЕ (СОСТОЯНИЕ ДВИЖКА)
; ============================================================================
section '.bss' readable writeable

g_StdOut                dd ?
g_StdIn                 dd ?
g_DummyWritten          dd ?
g_DummyRead             dd ?

g_QpcFreq               dq ?
g_QpcT0Low              dd ?
g_QpcT0High             dd ?
g_QpcT1Low              dd ?
g_QpcT1High             dd ?

g_MagicLow              dd ?
g_MagicHigh             dd ?

g_BytesReturned         dd ?
g_BytesTransferred      dd ?
g_LastError             dd ?
g_NewFilePos            dq ?

g_SdnBuf:
g_SdnDeviceType         dd ?
g_SdnDeviceNumber       dd ?
g_SdnPartitionNumber    dd ?

g_DiskSizeLow           dd ?
g_DiskSizeHigh          dd ?
g_SpqBuf                rd 3
g_GeomBuf               rb 256
g_DescBuf               rb 1024
g_VendorStr             rb 64
g_ProductStr            rb 64
g_RevStr                rb 32

g_DriveCount            dd ?
g_SelectedIdx           dd ?
g_Drives                rb sizeof.DRIVE_INFO * MAX_DRIVES

g_DiskLetterMask        rd 32
g_DiskRemovableMap      rd 32
g_UnmappedVolumeFlag    dd ?
g_UnmappedVolumeLetter  db ?
                        rb 3

g_DiskHandle            dd ?
g_LockedVolCount        dd ?
g_LockedVolHandles      rd 26

g_WriteProbeBuf         dd ?
g_ReadProbeBuf          dd ?
g_StreamWriteBuf        dd ?
g_StreamReadBuf         dd ?
g_AuditSectorBuf        dd ?

g_StableAnchorCount     dd ?
g_StableAnchors         rb sizeof.ANCHOR_ITEM * MAX_STABLE_ANCHORS
g_RecentAnchorCount     dd ?
g_RecentAnchors         rb sizeof.ANCHOR_ITEM * MAX_RECENT_ANCHORS

g_ExpSchedule           rd MAX_EXP_POINTS
g_RealLimitBlocks       dd ?

g_BadBlock              dd ?
g_MismatchStr           rb 2048
g_FirstAnchorMismatch   rb 2048
g_ProbeReason           rb 2048
g_LogBuf                rb 2048
g_InputBuf              rb 64

g_ChunkShift            dd ?
g_MetricCount           dd ?
g_ChunkMetrics          rb sizeof.CHUNK_METRIC * MAX_CHUNKS

g_BaselineSpeed         dd ?
g_ThresholdSpeed        dd ?
g_SlowTailBlock         dd ?
